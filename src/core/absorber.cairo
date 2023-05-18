#[contract]
mod Absorber {
    use array::{ArrayTrait, SpanTrait};
    use cmp::min;
    use integer::{BoundedInt, BoundedU256, u128_safe_divmod, U128TryIntoNonZero};
    use option::OptionTrait;
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use traits::{Into, TryInto};
    use zeroable::{Zeroable};

    use aura::core::roles::AbsorberRoles;

    use aura::interfaces::IAbsorber::{IBlesserDispatcher, IBlesserDispatcherTrait};
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::AccessControl;
    use aura::utils::serde;
    use aura::utils::storage_access_impls;
    use aura::utils::types::{AssetApportion, Provision, Request, Reward};
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, Wad};

    //
    // Constants
    // 

    // If the amount of yin Wad per share drops below this threshold, the epoch is incremented
    // to reset the yin per share ratio to 1 : 1 parity for accounting. Otherwise, there will
    // eventually be an overflow when converting yin to shares (and vice versa)
    // as yin per share approaches 0.
    const YIN_PER_SHARE_THRESHOLD: u128 = 1000000000000000; // 10**15 = 0.001 (Wad)

    // Shares to be minted without a provider to avoid first provider front-running
    const INITIAL_SHARES: u128 = 1000; // 10 ** 3 (Wad);

    // Lower bound of the Shrine's LTV to threshold that can be set for restricting removals
    const MIN_LIMIT: u128 = 500000000000000000000000000; // 50 * wadray::RAY_PERCENT = 0.5

    // Amount of time, in seconds, that needs to elapse after request is submitted before removal
    const REQUEST_BASE_TIMELOCK: u64 = 60;

    // Upper bound of time, in seconds, that needs to elapse after request is submitted before removal
    // 7 days * 24 hours per day * 60 minutes per hour * 60 seconds per minute
    const REQUEST_MAX_TIMELOCK: u64 = 604800; // 7 * 24 * 60 * 60

    // Multiplier for each request's timelock from the last value if a new request is submitted
    // before the cooldown of the previous request has elapsed
    const REQUEST_TIMELOCK_MULTIPLIER: u64 = 5;

    // Amount of time, in seconds, for which a request is valid, starting from expiry of the timelock
    // 60 minutes * 60 seconds per minute
    const REQUEST_VALIDITY_PERIOD: u64 = 3600; // 60 * 60

    // Amount of time that needs to elapse after a request is submitted before the timelock
    // for the next request is reset to the base value.
    // 7 days * 24 hours per day * 60 minutes per hour * 60 seconds per minute
    const REQUEST_COOLDOWN: u64 = 604800; // 7 * 24 * 60 * 60

    // Helper constant to set the starting index for iterating over the Rewards
    // in the order they were added
    const REWARDS_LOOP_START: u8 = 1;

    struct Storage {
        // mapping between a provider address and the sentinel contract address
        sentinel: ISentinelDispatcher,
        // mapping between a provider address and the shrine contract address
        shrine: IShrineDispatcher,
        // boolean flag indicating whether the absorber is live or not
        is_live: bool,
        // epoch starts from 0
        // both shares and absorptions are tied to an epoch
        // the epoch is incremented when the amount of yin per share drops below the threshold.
        // this includes when the absorber's yin balance is completely depleted.
        current_epoch: u32,
        // absorptions start from 1.
        absorptions_count: u32,
        // mapping from a provider to the last absorption ID accounted for
        provider_last_absorption: LegacyMap::<ContractAddress, u32>,
        // mapping of address to a packed struct of
        // 1. epoch in which the provider's shares are issued
        // 2. number of shares for the provider in the above epoch
        provisions: LegacyMap::<ContractAddress, Provision>,
        // mapping from an absorption to its epoch
        absorption_epoch: LegacyMap::<u32, u32>,
        // total number of shares for current epoch
        total_shares: Wad,
        // mapping of a tuple of absorption ID and asset to a packed struct of
        // 1. the amount of that asset in its decimal precision absorbed per share Wad for an absorption
        // 2. the rounding error from calculating (1) that is to be added to the next absorption
        asset_absorption: LegacyMap::<(ContractAddress, u32), AssetApportion>,
        // conversion rate of an epoch's shares to the next
        // if an update causes the yin per share to drop below the threshold,
        // the epoch is incremented and yin per share is reset to one Ray.
        // a provider with shares in that epoch will receive new shares in the next epoch
        // based on this conversion rate.
        // if the absorber's yin balance is wiped out, the conversion rate will be 0.
        epoch_share_conversion_rate: LegacyMap::<u32, Ray>,
        // total number of reward tokens, starting from 1
        // a reward token cannot be removed once added.
        rewards_count: u8,
        // mapping from a reward token address to its id for iteration
        reward_id: LegacyMap::<ContractAddress, u8>,
        // mapping from a reward token ID to its Reward struct:
        // 1. the ERC-20 token address
        // 2. the address of the vesting contract (blesser) implementing `IBlesser` for the ERC-20 token
        // 3. a boolean indicating if the blesser should be called
        rewards: LegacyMap::<u8, Reward>,
        // mapping from a reward token address and epoch to a packed struct of
        // 1. the cumulative amount of that reward asset in its decimal precision per share Wad in that epoch
        // 2. the rounding error from calculating (1) that is to be added to the next reward distribution
        reward_by_epoch: LegacyMap::<(ContractAddress, u32), AssetApportion>,
        // mapping from a provider and reward token address to its last cumulative amount of that reward
        // per share Wad in the epoch of the provider's Provision struct
        provider_last_reward_cumulative: LegacyMap::<(ContractAddress, ContractAddress), u128>,
        // Removals are temporarily suspended if the shrine's LTV to threshold exceeds this limit
        removal_limit: Ray,
        // Mapping from a provider to its latest request for removal
        provider_request: LegacyMap::<ContractAddress, Request>,
    }


    //
    // Events
    //

    #[event]
    fn RewardSet(asset: ContractAddress, blesser: ContractAddress, is_active: bool) {}

    #[event]
    fn EpochChanged(old_epoch: u32, new_epoch: u32) {}

    #[event]
    fn RemovalLimitUpdated(old_limit: Ray, new_limit: Ray) {}

    #[event]
    fn Provide(provider: ContractAddress, epoch: u32, yin: Wad) {}

    #[event]
    fn RequestSubmitted(provider: ContractAddress, timestamp: u64, timelock: u64) {}

    #[event]
    fn Remove(provider: ContractAddress, epoch: u32, yin: Wad) {}

    #[event]
    fn Reap(
        provider: ContractAddress,
        absorbed_assets: Span<ContractAddress>,
        absorbed_asset_amts: Span<u128>,
        reward_assets: Span<ContractAddress>,
        reward_amts: Span<u128>,
    ) {}

    #[event]
    fn Gain(
        assets: Span<ContractAddress>,
        asset_amts: Span<u128>,
        total_shares: Wad,
        epoch: u32,
        absorption_id: u32,
    ) {}

    #[event]
    fn Bestow(
        assets: Span<ContractAddress>, asset_amts: Span<u128>, total_shares: Wad, epoch: u32, 
    ) {}

    #[event]
    fn Killed() {}

    #[event]
    fn Compensate(
        recipient: ContractAddress, assets: Span<ContractAddress>, asset_amts: Span<u128>, 
    ) {}


    //
    // Constructor
    //
    #[constructor]
    fn constructor(
        admin: ContractAddress, shrine: ContractAddress, sentinel: ContractAddress, limit: Ray
    ) {
        AccessControl::initializer(admin);
        AccessControl::grant_role_internal(AbsorberRoles::default_admin_role(), admin);

        shrine::write(IShrineDispatcher { contract_address: shrine });
        sentinel::write(ISentinelDispatcher { contract_address: sentinel });
        is_live::write(true);
        set_removal_limit_internal(limit);
    }

    //
    // Getters
    //

    #[view]
    fn get_rewards_count() -> u8 {
        rewards_count::read()
    }

    #[view]
    fn get_rewards() -> Span<Reward> {
        let rewards_count: u8 = rewards_count::read();

        let mut reward_id: u8 = REWARDS_LOOP_START;
        let mut rewards: Array<Reward> = ArrayTrait::new();

        loop {
            if reward_id == REWARDS_LOOP_START + rewards_count {
                break rewards.span();
            }

            rewards.append(rewards::read(reward_id));
            reward_id += 1;
        }
    }

    #[view]
    fn get_current_epoch() -> u32 {
        current_epoch::read()
    }

    #[view]
    fn get_absorptions_count() -> u32 {
        absorptions_count::read()
    }

    #[view]
    fn get_absorption_epoch(absorption_id: u32) -> u32 {
        absorption_epoch::read(absorption_id)
    }

    #[view]
    fn get_total_shares_for_current_epoch() -> Wad {
        total_shares::read()
    }

    #[view]
    fn get_provider(provider: ContractAddress) -> Provision {
        provisions::read(provider)
    }

    #[view]
    fn get_provider_last_absorption(provider: ContractAddress) -> u32 {
        provider_last_absorption::read(provider)
    }

    #[view]
    fn get_provider_request(provider: ContractAddress) -> Request {
        provider_request::read(provider)
    }

    #[view]
    fn get_asset_absorption(asset: ContractAddress, absorption_id: u32) -> AssetApportion {
        asset_absorption::read((asset, absorption_id))
    }

    #[view]
    fn get_asset_reward(asset: ContractAddress, epoch: u32) -> AssetApportion {
        reward_by_epoch::read((asset, epoch))
    }

    #[view]
    fn get_provider_last_reward_cumulative(
        provider: ContractAddress, asset: ContractAddress
    ) -> u128 {
        provider_last_reward_cumulative::read((provider, asset))
    }

    #[view]
    fn get_removal_limit() -> Ray {
        removal_limit::read()
    }

    #[view]
    fn get_live() -> bool {
        is_live::read()
    }


    //
    // View
    //
    // Returns the maximum amount of yin removable by a provider.
    #[view]
    fn preview_remove(provider: ContractAddress) -> Wad {
        let provision: Provision = provisions::read(provider);
        let current_epoch: u32 = current_epoch::read();
        let current_provider_shares: Wad = convert_epoch_shares(
            provision.epoch, current_epoch, provision.shares
        );

        convert_to_yin(current_provider_shares)
    }

    #[view]
    fn preview_reap(
        provider: ContractAddress
    ) -> (Span<ContractAddress>, Span<u128>, Span<ContractAddress>, Span<u128>) {
        let provision: Provision = provisions::read(provider);
        let provider_last_absorption_id: u32 = provider_last_absorption::read(provider);
        let current_absorption_id: u32 = absorptions_count::read();

        let (absorbed_assets, absorbed_asset_amts) = get_absorbed_assets_for_provider_internal(
            provider, provision, provider_last_absorption_id, current_absorption_id
        );

        // Get accumulated rewards
        let rewards_count: u8 = rewards_count::read();
        let current_epoch: u32 = current_epoch::read();
        let (reward_assets, reward_amts) = get_provider_accumulated_rewards(
            provider, provision, current_epoch, rewards_count
        );

        // Add pending rewards
        let total_shares: Wad = total_shares::read();
        let current_provider_shares: Wad = convert_epoch_shares(
            provision.epoch, current_epoch, provision.shares
        );

        if total_shares.is_zero() | current_provider_shares.is_zero() {
            return (absorbed_assets, absorbed_asset_amts, reward_assets, reward_amts);
        }

        let updated_reward_amts: Span<u128> = get_provider_pending_rewards(
            provider, current_provider_shares, total_shares, current_epoch, reward_amts
        );

        (absorbed_assets, absorbed_asset_amts, reward_assets, updated_reward_amts)
    }


    //
    // Setters
    //

    #[external]
    fn set_reward(asset: ContractAddress, blesser: ContractAddress, is_active: bool) {
        AccessControl::assert_has_role(AbsorberRoles::SET_REWARD);

        assert(asset.is_non_zero() & blesser.is_non_zero(), 'AB: Address cannot be 0');

        let reward: Reward = Reward {
            asset, blesser: IBlesserDispatcher { contract_address: blesser }, is_active
        };

        // If this reward token hasn't been added yet, add it to the list first
        let reward_id: u8 = reward_id::read(asset);

        // Emit event 
        RewardSet(asset, blesser, is_active);

        // If the reward doesn't yet exist, add it to the list
        if reward_id == 0 {
            let current_count: u8 = rewards_count::read();
            let new_count = current_count + 1;

            rewards_count::write(new_count);
            reward_id::write(asset, new_count);
            rewards::write(new_count, reward);
        } else {
            // Otherwise, update the existing reward
            rewards::write(reward_id, reward);
        }
    }

    #[external]
    fn set_removal_limit(limit: Ray) {
        AccessControl::assert_has_role(AbsorberRoles::SET_REMOVAL_LIMIT);
        set_removal_limit_internal(limit);
    }


    //
    // External
    //

    // Supply yin to the absorber.
    // Requires the caller to have approved spending by the absorber.
    #[external]
    fn provide(amount: Wad) {
        assert_live();

        let current_epoch: u32 = current_epoch::read();
        let provider: ContractAddress = get_caller_address();

        // Withdraw absorbed collateral before updating shares
        let provision: Provision = provisions::read(provider);
        reap_internal(provider, provision, current_epoch);

        // Calculate number of shares to issue to provider and to add to total for current epoch
        // The two values deviate only when it is the first provision of an epoch and
        // total shares is below the minimum initial shares.
        let (new_provision_shares, issued_shares) = convert_to_shares(amount, false);

        // If epoch has changed, convert shares in previous epoch to new epoch's shares
        let converted_shares: Wad = convert_epoch_shares(
            provision.epoch, current_epoch, provision.shares
        );

        let new_shares: Wad = converted_shares + new_provision_shares;
        provisions::write(provider, Provision { epoch: current_epoch, shares: new_shares });

        // Update total shares for current epoch
        let new_total_shares: Wad = total_shares::read() + issued_shares;
        total_shares::write(new_total_shares);

        // Perform transfer of yin
        let absorber: ContractAddress = get_contract_address();

        let success: bool = yin_erc20().transfer_from(provider, absorber, amount.into());
        assert(success, 'AB: Transfer failed');

        // Event emission
        Provide(provider, current_epoch, amount);
    }


    // Submit a request to `remove` that is valid for a fixed period of time after a variable timelock.
    // - This is intended to prevent atomic removals to avoid risk-free yield (from rewards and interest)
    //   frontrunning tactics.
    //   The timelock increases if another request is submitted before the previous has cooled down.
    // - A request is expended by either (1) a removal; (2) expiry; or (3) submitting a new request.
    // - Note: A request may become valid in the next epoch if a provider in the previous epoch
    //         submitted a request, a draining absorption occurs, and the provider provides again
    //         in the next epoch. This is expected to be rare, and the maximum risk-free profit is
    //         in any event greatly limited.

    #[external]
    fn request() {
        let provider: ContractAddress = get_caller_address();
        let provision: Provision = provisions::read(provider);
        assert_provider(provision);

        let request: Request = provider_request::read(provider);
        let current_timestamp: u64 = get_block_timestamp();

        let mut timelock: u64 = REQUEST_BASE_TIMELOCK;
        if request.timestamp
            + REQUEST_COOLDOWN > current_timestamp {
                timelock = request.timelock * REQUEST_TIMELOCK_MULTIPLIER;
            }

        let capped_timelock: u64 = timelock - REQUEST_MAX_TIMELOCK;
        provider_request::write(
            provider,
            Request { timestamp: current_timestamp, timelock: capped_timelock, has_removed: false }
        );
        RequestSubmitted(provider, current_timestamp, capped_timelock);
    }

    // Withdraw yin (if any) and all absorbed collateral assets from the absorber.
    #[external]
    fn remove(amount: Wad) {
        let provider: ContractAddress = get_caller_address();
        let provision: Provision = provisions::read(provider);
        let request: Request = provider_request::read(provider);
        assert_provider(provision);
        assert_can_remove(request);

        let current_epoch: u32 = current_epoch::read();

        // Withdraw absorbed collateral before updating shares
        reap_internal(provider, provision, current_epoch);

        // Fetch the shares for current epoch
        let current_provider_shares: Wad = convert_epoch_shares(
            provision.epoch, current_epoch, provision.shares
        );

        if current_provider_shares.is_zero() {
            // If no remaining shares after converting across epochs,
            // provider's deposit has been completely absorbed.
            // Since absorbed collateral have been reaped,
            // we can update the provision to current epoch and shares.
            provisions::write(provider, Provision { epoch: current_epoch, shares: 0_u128.into() });

            provider_request::write(
                provider,
                Request {
                    timestamp: request.timestamp, timelock: request.timelock, has_removed: true
                }
            );

            // Event emission
            Remove(provider, current_epoch, 0_u128.into());
        } else {
            // Calculations for yin need to be performed before updating total shares.
            // Cap `amount` to maximum removable for provider, then derive the number of shares.
            let max_removable_yin: Wad = convert_to_yin(current_provider_shares);
            let yin_amt: Wad = min(amount, max_removable_yin);

            // Due to precision loss, we need to re-check if the amount to remove is the max
            // removable, and then set the shares to remove as the provider's balance to avoid
            // any remaining dust shares.
            let mut shares_to_remove = current_provider_shares;
            if yin_amt != max_removable_yin {
                let (shares_to_remove_ceiled, _) = convert_to_shares(yin_amt, true);
                shares_to_remove = shares_to_remove_ceiled;
            }

            total_shares::write(total_shares::read() - shares_to_remove);

            // Update provision
            let new_provider_shares: Wad = current_provider_shares - shares_to_remove;
            provisions::write(
                provider, Provision { epoch: current_epoch, shares: new_provider_shares }
            );

            provider_request::write(
                provider,
                Request {
                    timestamp: request.timestamp, timelock: request.timelock, has_removed: true
                }
            );

            let yin_amt_uint: u256 = yin_amt.into();
            let success: bool = yin_erc20().transfer(provider, yin_amt_uint);
            assert(success, 'AB: Transfer failed');

            // Event emission
            Remove(provider, current_epoch, yin_amt);
        }
    }

    // Withdraw absorbed collateral only from the absorber
    // Note that `reap` alone will not update a caller's Provision in storage
    #[external]
    fn reap() {
        let provider: ContractAddress = get_caller_address();
        let provision: Provision = provisions::read(provider);
        assert_provider(provision);

        let current_epoch: u32 = current_epoch::read();

        reap_internal(provider, provision, current_epoch);

        // Update provider's epoch and shares to current epoch's
        // Epoch must be updated to prevent provider from repeatedly claiming rewards
        let current_provider_shares: Wad = convert_epoch_shares(
            provision.epoch, current_epoch, provision.shares
        );
        provisions::write(
            provider, Provision { epoch: current_epoch, shares: current_provider_shares }
        );
    }

    // Update assets received after an absorption
    #[external]
    fn update(assets: Span<ContractAddress>, asset_amts: Span<u128>) {
        AccessControl::assert_has_role(AbsorberRoles::UPDATE);

        let current_epoch: u32 = current_epoch::read();

        // Trigger issuance of rewards
        let rewards_count: u8 = rewards_count::read();
        bestow(current_epoch, rewards_count);

        // Increment absorption ID
        let prev_absorption_id: u32 = absorptions_count::read();
        let current_absorption_id: u32 = prev_absorption_id + 1;
        absorptions_count::write(current_absorption_id);

        // Update epoch for absorption ID
        absorption_epoch::write(current_absorption_id, current_epoch);

        let total_shares: Wad = total_shares::read();

        // Loop through assets and calculate amount entitled per share
        // Copy the Spans so as to not consume the originals with `pop_front()`
        let mut assets_copy: Span<ContractAddress> = assets;
        let mut asset_amts_copy: Span<u128> = asset_amts;

        loop {
            match assets_copy.pop_front() {
                Option::Some(asset) => {
                    let asset_amt: u128 = *asset_amts_copy.pop_front().unwrap();
                    update_absorbed_asset(current_absorption_id, total_shares, *asset, asset_amt);
                },
                Option::None(_) => {
                    break ();
                }
            };
        };

        // Emit `Gain` event
        Gain(assets, asset_amts, total_shares, current_epoch, current_absorption_id);

        // Increment epoch ID if yin per share drops below threshold or stability pool is emptied
        let absorber: ContractAddress = get_contract_address();
        let yin_balance_uint: u256 = yin_erc20().balance_of(absorber);
        let yin_balance: Wad = Wad { val: yin_balance_uint.try_into().unwrap() };
        let yin_per_share: Wad = yin_balance / total_shares;

        // This also checks for absorber's yin balance being emptied because yin per share will be
        // below threshold if yin balance is 0.
        if YIN_PER_SHARE_THRESHOLD <= yin_per_share.val {
            return ();
        }

        let new_epoch: u32 = current_epoch + 1;
        current_epoch::write(new_epoch);

        // If new epoch's yin balance exceeds the initial minimum shares, deduct the initial
        // minimum shares worth of yin from the yin balance so that there is at least such amount
        // of yin that cannot be removed in the next epoch.
        let mut yin_balance_for_shares: Wad = yin_balance;
        if INITIAL_SHARES <= yin_balance.val {
            yin_balance_for_shares -= INITIAL_SHARES.into();
        }

        let epoch_share_conversion_rate: Ray = wadray::rdiv_ww(
            yin_balance_for_shares, total_shares
        );

        // If absorber is emptied, this will be set to 0.
        epoch_share_conversion_rate::write(current_epoch, epoch_share_conversion_rate);

        // If absorber is emptied, this will be set to 0.
        total_shares::write(yin_balance);
        EpochChanged(current_epoch, new_epoch);

        // Transfer reward errors of current epoch to the next epoch
        propagate_reward_errors(rewards_count, current_epoch);
    }

    #[external]
    fn kill() {
        AccessControl::assert_has_role(AbsorberRoles::KILL);
        is_live::write(false);
        Killed();
    }

    #[external]
    fn compensate(
        recipient: ContractAddress, assets: Span<ContractAddress>, asset_amts: Span<u128>
    ) {
        AccessControl::assert_has_role(AbsorberRoles::COMPENSATE);
        transfer_assets(recipient, assets, asset_amts);
        Compensate(recipient, assets, asset_amts);
    }

    //
    // Internal 
    // 
    fn assert_provider(provision: Provision) {
        assert(provision.epoch != 0, 'AB: Not a provider');
    }

    fn assert_live() {
        assert(is_live::read(), 'AB: Not live');
    }

    fn set_removal_limit_internal(limit: Ray) {
        assert(MIN_LIMIT <= limit.val, 'AB: Limit is too low');
        let prev_limit = removal_limit::read();
        removal_limit::write(limit);
        RemovalLimitUpdated(prev_limit, limit);
    }


    //
    // Internal - helpers for accounting of shares
    //

    // Convert to shares with a flag for whether the value should be rounded up or rounded down.
    // When converting to shares, we always favour the Absorber to the expense of the provider.
    // - Round down for `provide` (default for integer division)
    // - Round up for `remove`
    // Returns a tuple of the shares to be issued to the provider, and the total number of shares
    // issued for the system.
    // - There will be a difference between the two values only if it is the first `provide` of an epoch and
    //   the total shares is less than the minimum initial shares.
    fn convert_to_shares(yin_amt: Wad, round_up: bool) -> (Wad, Wad) {
        let total_shares: Wad = total_shares::read();

        if INITIAL_SHARES <= total_shares.val {
            return ((yin_amt.val - INITIAL_SHARES).into(), INITIAL_SHARES.into());
        }

        let absorber: ContractAddress = get_contract_address();
        let yin_balance: Wad = Wad { val: yin_erc20().balance_of(absorber).try_into().unwrap() };

        // TODO: This could easily overflow, should be done with u256
        let (computed_shares, r) = u128_safe_divmod(
            yin_amt.val * total_shares.val, yin_balance.val.try_into().expect('Division by zero')
        );
        if round_up & r != 0 {
            return ((computed_shares + 1).into(), (computed_shares + 1).into());
        }
        (computed_shares.into(), computed_shares.into())
    }

    // This implementation is slightly different from Gate because the concept of shares is
    // used for internal accounting only, and both shares and yin are wads.
    fn convert_to_yin(shares_amt: Wad) -> Wad {
        let total_shares: Wad = total_shares::read();

        // If no shares are issued yet, then it is a new epoch and absorber is emptied.
        if total_shares.is_zero() {
            return Wad { val: 0 };
        }

        let absorber: ContractAddress = get_contract_address();
        let yin_balance: Wad = Wad { val: yin_erc20().balance_of(absorber).try_into().unwrap() };

        let yin: Wad = (shares_amt * yin_balance) / total_shares;
        yin
    }

    // Convert an epoch's shares to a subsequent epoch's shares
    // Return argument is named for testing
    fn convert_epoch_shares(start_epoch: u32, end_epoch: u32, start_shares: Wad) -> Wad {
        if start_epoch == end_epoch {
            return start_shares;
        }

        let epoch_conversion_rate: Ray = epoch_share_conversion_rate::read(start_epoch);

        // `rmul` of a wad and a ray returns a wad
        let new_shares: Wad = wadray::rmul_wr(start_shares, epoch_conversion_rate);

        convert_epoch_shares(start_epoch + 1, end_epoch, new_shares)
    }

    //
    // Internal - helpers for `update`
    //

    // Helper function to update each provider's entitlement of an absorbed asset
    fn update_absorbed_asset(
        absorption_id: u32, total_shares: Wad, asset: ContractAddress, amount: u128
    ) {
        if amount == 0 {
            return ();
        }

        let last_error: u128 = get_recent_asset_absorption_error(asset, absorption_id);
        let total_amount_to_distribute: u128 = amount + last_error;

        let asset_amt_per_share: u128 = wadray::wdiv_internal(
            total_amount_to_distribute, total_shares.val
        );
        let actual_amount_distributed: u128 = wadray::wmul_internal(
            asset_amt_per_share, total_shares.val
        );
        let error: u128 = total_amount_to_distribute - actual_amount_distributed;

        asset_absorption::write(
            (asset, absorption_id), AssetApportion { asset_amt_per_share, error }
        );
    }


    // Returns the last error for an asset at a given `absorption_id` if the packed value is non-zero.
    // Otherwise, check `absorption_id - 1` recursively for the last error.
    fn get_recent_asset_absorption_error(asset: ContractAddress, absorption_id: u32) -> u128 {
        if absorption_id == 0 {
            return 0;
        }

        let absorption: AssetApportion = asset_absorption::read((asset, absorption_id));
        // asset_amt_per_share is checked because it is possible for the error to be zero. 
        // On the other hand, asset_amt_per_share should never be zero, save for extreme edge cases. 
        if absorption.asset_amt_per_share != 0 {
            return absorption.error;
        }

        get_recent_asset_absorption_error(asset, absorption_id - 1)
    }


    //
    // Internal - helpers for `reap`
    //

    // Internal function to be called whenever a provider takes an action to ensure absorbed assets
    // are properly transferred to the provider before updating the provider's information
    fn reap_internal(provider: ContractAddress, provision: Provision, current_epoch: u32) {
        // Trigger issuance of rewards
        let rewards_count: u8 = rewards_count::read();
        bestow(current_epoch, rewards_count);

        let provider_last_absorption_id: u32 = provider_last_absorption::read(provider);
        let current_absorption_id: u32 = absorptions_count::read();

        // This should be updated before early return so that first provision by a new
        // address is properly updated.
        provider_last_absorption::write(provider, current_absorption_id);

        if provider_last_absorption_id == current_absorption_id {
            return ();
        }

        let total_shares: Wad = total_shares::read();

        // Loop over absorbed assets and transfer
        let (absorbed_assets, absorbed_asset_amts) = get_absorbed_assets_for_provider_internal(
            provider, provision, provider_last_absorption_id, current_absorption_id
        );
        transfer_assets(provider, absorbed_assets, absorbed_asset_amts);

        // Loop over accumulated rewards, transfer and update provider's rewards cumulative
        let (reward_assets, reward_asset_amts) = get_provider_accumulated_rewards(
            provider, provision, current_epoch, rewards_count
        );
        transfer_assets(provider, reward_assets, reward_asset_amts);

        update_provider_cumulative_rewards(
            provider, current_epoch, REWARDS_LOOP_START, reward_assets
        );

        Reap(provider, absorbed_assets, absorbed_asset_amts, reward_assets, reward_asset_amts);
    }

    // Internal function to calculate the absorbed assets that a provider is entitled to
    // Returns a tuple of an array of assets and an array of amounts of each asset
    fn get_absorbed_assets_for_provider_internal(
        provider: ContractAddress,
        provision: Provision,
        provided_absorption_id: u32,
        current_absorption_id: u32
    ) -> (Span<ContractAddress>, Span<u128>) {
        let mut asset_amts: Array<u128> = ArrayTrait::new();

        // Early termination by returning empty arrays

        if provision.shares.is_zero() | current_absorption_id == provided_absorption_id {
            let empty_assets: Array<ContractAddress> = ArrayTrait::new();
            return (empty_assets.span(), asset_amts.span());
        }

        let assets: Span<ContractAddress> = sentinel::read().get_yang_addresses();

        let assets_len = assets.len();
        let mut idx = 0;

        // Loop over all assets and calculate the amount of 
        // each asset that the provider is entitled to
        loop {
            if idx == assets_len {
                // TODO: return (assets, asset_amts) here once possible
                break ();
            }

            // Loop over all absorptions from `provided_absorption_id` for the current asset and add
            // the amount of the asset that the provider is entitled to for each absorption to `absorbed_amt`. 
            let mut absorbed_amt: u128 = 0;
            let mut start_absorption_id = provided_absorption_id;

            loop {
                if start_absorption_id == current_absorption_id {
                    break ();
                }

                start_absorption_id += 1;
                let absorption_epoch: u32 = absorption_epoch::read(start_absorption_id);

                // If `provision.epoch == absorption_epoch`, then `adjusted_shares == provision.shares`.
                let adjusted_shares: Wad = convert_epoch_shares(
                    provision.epoch, absorption_epoch, provision.shares
                );

                // Terminate if provider does not have any shares for current epoch
                if adjusted_shares.is_zero() {
                    break ();
                }

                let absorption: AssetApportion = asset_absorption::read(
                    (*assets[idx], start_absorption_id)
                );

                absorbed_amt +=
                    wadray::wmul_internal(adjusted_shares.val, absorption.asset_amt_per_share);
            };

            asset_amts.append(absorbed_amt);
        };

        (assets, asset_amts.span())
    }


    // Helper function to iterate over an array of assets to transfer to an address
    fn transfer_assets(
        to: ContractAddress, mut assets: Span<ContractAddress>, mut asset_amts: Span<u128>
    ) {
        loop {
            match assets.pop_front() {
                Option::Some(asset) => {
                    let asset_amt: u128 = *asset_amts.pop_front().unwrap();
                    if asset_amt != 0 {
                        let asset_amt: u256 = asset_amt.into();
                        IERC20Dispatcher { contract_address: *asset }.transfer(to, asset_amt);
                    }
                },
                Option::None(_) => {
                    break ();
                },
            };
        };
    }


    //
    // Internal - helpers for remove
    //

    // Returns shrine global LTV divided by the global LTV threshold
    fn get_shrine_ltv_to_threshold() -> Ray {
        let shrine = shrine::read();
        let (threshold, value) = shrine.get_shrine_threshold_and_value();
        let debt: Wad = shrine.get_total_debt();
        let ltv: Ray = wadray::rdiv_ww(debt, value);
        wadray::rdiv(ltv, threshold)
    }

    fn assert_can_remove(request: Request) {
        let ltv_to_threshold: Ray = get_shrine_ltv_to_threshold();
        let limit: Ray = removal_limit::read();

        assert(ltv_to_threshold <= limit, 'AB: relative LTV above limit');

        assert(request.timestamp != 0, 'AB: No request found');
        assert(!request.has_removed, 'AB: Only 1 removal per request');

        let current_timestamp: u64 = starknet::get_block_timestamp();
        let removal_start_timestamp: u64 = request.timestamp + request.timelock;
        assert(removal_start_timestamp <= current_timestamp, 'AB: Request is not valid yet');
        assert(
            current_timestamp <= removal_start_timestamp + REQUEST_VALIDITY_PERIOD,
            'AB: Request has expired'
        );
    }

    //
    // Internal - helpers for rewards
    //

    fn bestow(epoch: u32, rewards_count: u8) {
        // Defer rewards until at least one provider deposits
        let total_shares: Wad = total_shares::read();
        if total_shares.is_zero() {
            return ();
        }

        // Trigger issuance of active rewards
        let mut rewards: Array<ContractAddress> = ArrayTrait::new();
        let mut blessed_amts: Array<u128> = ArrayTrait::new();
        let mut current_rewards_id: u8 = 0;

        loop {
            if current_rewards_id == rewards_count + REWARDS_LOOP_START {
                break ();
            }

            let reward: Reward = rewards::read(current_rewards_id);
            if !reward.is_active {
                current_rewards_id += 1;
                continue;
            }

            rewards.append(reward.asset);

            let blessed_amt = reward.blesser.bless();
            blessed_amts.append(blessed_amt);

            if blessed_amt != 0 {
                let epoch_reward_info: AssetApportion = reward_by_epoch::read(
                    (reward.asset, epoch)
                );
                let total_amount_to_distribute: u128 = blessed_amt + epoch_reward_info.error;

                let asset_amt_per_share: u128 = wadray::wdiv_internal(
                    total_amount_to_distribute, total_shares.val
                );
                let actual_amount_distributed: u128 = wadray::wmul_internal(
                    asset_amt_per_share, total_shares.val
                );
                let error: u128 = total_amount_to_distribute - actual_amount_distributed;

                let updated_asset_amt_per_share: u128 = epoch_reward_info.asset_amt_per_share
                    + asset_amt_per_share;

                reward_by_epoch::write(
                    (reward.asset, epoch),
                    AssetApportion {
                        asset_amt_per_share: updated_asset_amt_per_share, error: error
                    }
                );
            }

            current_rewards_id += 1;
        };

        Bestow(rewards.span(), blessed_amts.span(), total_shares, epoch);
    }

    // Helper function to perform an outer loop over all rewards and calculate the accumulated amounts
    // for a provider. It also writes the asset address and accumulated amounts for rewards to two respective arrays.
    // To get all rewards, `current_rewards_id` should start at `1`.
    fn get_provider_accumulated_rewards(
        provider: ContractAddress, provision: Provision, current_epoch: u32, rewards_count: u8
    ) -> (Span<ContractAddress>, Span<u128>) {
        let mut rewards: Array<ContractAddress> = ArrayTrait::new();
        let mut reward_amts: Array<u128> = ArrayTrait::new();
        let mut current_rewards_id: u8 = 0;

        loop {
            if current_rewards_id == rewards_count
                + REWARDS_LOOP_START {
                    break (rewards.span(), reward_amts.span());
                }

            let reward: Reward = rewards::read(current_rewards_id);
            let mut reward_amt: u128 = 0;
            let mut epoch: u32 = provision.epoch;
            let mut epoch_shares: Wad = provision.shares;

            loop {
                // Terminate after the current epoch because we need to calculate rewards for the current
                // epoch first
                // There is also an early termination if the provider has no shares in current epoch
                if epoch == current_epoch + 1 | epoch_shares.is_zero() {
                    break ();
                }

                let epoch_reward_info: AssetApportion = reward_by_epoch::read(
                    (reward.asset, epoch)
                );

                // Calculate the difference with the provider's cumulative value if it is the
                // same epoch as the provider's Provision epoch.
                // This is because the provider's cumulative value may not have been fully updated for that epoch. 
                let mut rate: u128 = epoch_reward_info.asset_amt_per_share;
                if epoch == provision.epoch {
                    let provider_cumulative_diff: u128 = epoch_reward_info.asset_amt_per_share
                        - provider_last_reward_cumulative::read((provider, reward.asset));
                }
                reward_amt += wadray::wmul_internal(rate, epoch_shares.val);

                epoch_shares = convert_epoch_shares(epoch, epoch + 1, epoch_shares);

                epoch += 1;
            };

            rewards.append(reward.asset);
            reward_amts.append(reward_amt);

            current_rewards_id += 1;
        }
    }

    // Update a provider's cumulative rewards to the given epoch
    // All rewards should be updated for a provider because an inactive reward may be set to active,
    // receive a distribution, and set to inactive again. If a provider's cumulative is not updated
    // for this reward, the provider can repeatedly claim the difference and drain the absorber.
    fn update_provider_cumulative_rewards(
        provider: ContractAddress, epoch: u32, rewards_count: u8, mut assets: Span<ContractAddress>, 
    ) {
        loop {
            match assets.pop_front() {
                Option::Some(asset) => {
                    let epoch_reward_info: AssetApportion = reward_by_epoch::read((*asset, epoch));
                    provider_last_reward_cumulative::write(
                        (provider, *asset), epoch_reward_info.asset_amt_per_share
                    )
                },
                Option::None(_) => {
                    break ();
                },
            };
        };
    }

    // Transfers the error for a reward from the given epoch to the next epoch
    // `current_rewards_id` should start at `1`.
    fn propagate_reward_errors(rewards_count: u8, epoch: u32) {
        let mut current_rewards_id: u8 = 0;

        loop {
            if current_rewards_id == rewards_count + REWARDS_LOOP_START {
                break ();
            }

            let reward: Reward = rewards::read(current_rewards_id);
            let epoch_reward_info: AssetApportion = reward_by_epoch::read((reward.asset, epoch));
            let next_epoch_reward_info: AssetApportion = AssetApportion {
                asset_amt_per_share: 0, error: epoch_reward_info.error, 
            };
            reward_by_epoch::write((reward.asset, epoch + 1), next_epoch_reward_info);
            current_rewards_id += 1;
        };
    }

    // Helper function to iterate over all rewards and calculate the pending reward amounts
    // for a provider.
    // Takes in a Span of accumulated amounts, and writes the sum of the accumulated amount and
    // the pending amount to a new Span.
    // To get all rewards, `current_rewards_id` should start at `1`.
    fn get_provider_pending_rewards(
        provider: ContractAddress,
        current_provider_shares: Wad,
        total_shares: Wad,
        current_epoch: u32,
        mut accumulated_asset_amts: Span<u128>
    ) -> Span<u128> {
        let mut updated_asset_amts: Array<u128> = ArrayTrait::new();
        let mut current_rewards_id: u8 = REWARDS_LOOP_START;

        loop {
            match accumulated_asset_amts.pop_front() {
                Option::Some(accumulated_amt) => {
                    let reward: Reward = rewards::read(current_rewards_id);
                    let pending_amt: u128 = reward.blesser.preview_bless();
                    let reward_info: AssetApportion = reward_by_epoch::read(
                        (reward.asset, current_epoch)
                    );

                    let pending_amt_per_share: u128 = wadray::wdiv_internal(
                        pending_amt + reward_info.error, total_shares.val
                    );
                    let provider_pending_amt: u128 = wadray::wmul_internal(
                        pending_amt_per_share, current_provider_shares.val
                    );
                    updated_asset_amts.append(*accumulated_amt + provider_pending_amt);
                    current_rewards_id += 1;
                },
                Option::None(_) => {
                    break ();
                },
            };
        };

        updated_asset_amts.span()
    }


    // Helper function to return a Yin ERC20 contract
    #[inline(always)]
    fn yin_erc20() -> IERC20Dispatcher {
        IERC20Dispatcher { contract_address: shrine::read().contract_address }
    }

    //
    // Public AccessControl functions
    //

    #[view]
    fn get_roles(account: ContractAddress) -> u128 {
        AccessControl::get_roles(account)
    }

    #[view]
    fn has_role(role: u128, account: ContractAddress) -> bool {
        AccessControl::has_role(role, account)
    }

    #[view]
    fn get_admin() -> ContractAddress {
        AccessControl::get_admin()
    }

    #[external]
    fn grant_role(role: u128, account: ContractAddress) {
        AccessControl::grant_role(role, account);
    }

    #[external]
    fn revoke_role(role: u128, account: ContractAddress) {
        AccessControl::revoke_role(role, account);
    }

    #[external]
    fn renounce_role(role: u128) {
        AccessControl::renounce_role(role);
    }

    #[external]
    fn set_pending_admin(new_admin: ContractAddress) {
        AccessControl::set_pending_admin(new_admin);
    }

    #[external]
    fn accept_admin() {
        AccessControl::accept_admin();
    }
}
