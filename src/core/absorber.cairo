#[contract]
mod Absorber {
    use array::ArrayTrait;
    use cmp::min;
    use integer::u128_safe_divmod;
    use option::OptionTrait;
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use zeroable::Zeroable;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
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
    const MIN_LIMIT: u128 = 500000000000000000000000000; // 50 * WadRay::RAY_PERCENT = 0.5

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
    const REWARDS_LOOP_START: u32 = 1;

    struct Storage {
        // mapping between a provider address and the purger contract address
        purger_address: ContractAddress,
        // mapping between a provider address and the sentinel contract address
        sentinel_address: ContractAddress,
        // mapping between a provider address and the shrine contract address
        shrine_address: ContractAddress,
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
        provision: LegacyMap::<ContractAddress, Provision>,
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
    fn PurgerUpdated(old_address: ContractAddress, new_address: ContractAddress) {}

    #[event]
    fn RewardSet(asset_addr: ContractAddress, blesser: ContractAddress, is_active: bool) {}

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
        absorbed_assets: Array<ContractAddress>,
        absorbed_asset_amts: Array<u128>,
        reward_assets: Array<ContractAddress>,
        reward_asset_amts: Array<u128>,
    ) {}

    #[event]
    fn Gain(
        assets: Array<ContractAddress>,
        asset_amts: Array<u128>,
        total_shares: Wad,
        epoch: u32,
        absorption_id: u32,
    ) {}

    #[event]
    fn Bestow(
        assets: Array<ContractAddress>, asset_amts: Array<u128>, total_shares: Wad, epoch: u32, 
    ) {}

    #[event]
    fn Killed() {}

    #[event]
    fn Compensate(
        recipient: ContractAddress, assets: Array<ContractAddress>, asset_amts: Array<u128>, 
    ) {}


    //
    // Constructor
    //
    #[constructor]
    fn constructor(
        admin: ContractAddress,
        shrine_addr: ContractAddress,
        sentinel_addr: ContractAddress,
        limit: Ray
    ) {
        //AccessControl.initializer(admin);
        //AccessControl._grant_role(AbsorberRoles.DEFAULT_ABSORBER_ADMIN_ROLE, admin);

        shrine_address::write(shrine_addr);
        sentinel_address::write(sentinel_addr);
        is_live::write(true);
    //set_removal_limit_internal(limit);
    }

    //
    // Getters
    //

    #[view]
    fn get_purger() -> ContractAddress {
        purger_address::read()
    }

    #[view]
    fn get_rewards_count() -> u8 {
        rewards_count::read()
    }

    #[view]
    fn get_rewards() -> Array<Reward> {
        let rewards_count: u8 = rewards_count::read();
        get_rewards_loop(REWARDS_LOOP_START, rewards_count)
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
        provision::read(provider)
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
    fn get_asset_absorption(asset_addr: ContractAddress, absorption_id: u32) -> AssetApportion {
        asset_absorption::read((asset_addr, absorption_id))
    }

    #[view]
    fn get_asset_reward(asset_addr: ContractAddress, epoch: u32) -> AssetApportion {
        reward_by_epoch::read((asset_addr, epoch))
    }

    #[view]
    fn get_provider_last_reward_cumulative(
        provider: ContractAddress, asset_addr: ContractAddress
    ) -> u128 {
        provider_last_reward_cumulative::read((provider, asset_addr))
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
        let provision: Provision = provision::read(provider);
        let current_epoch: u32 = current_epoch::read();
        let current_provider_shares: Wad = convert_epoch_shares(
            provision.epoch, current_epoch, provision.shares
        );

        convert_to_yin(current_provider_shares)
    }

    #[view]
    fn preview_reap(
        provider: ContractAddress
    ) -> (Array<ContractAddress>, Array<u128>, Array<ContractAddress>, Array<u128>) {
        let provision: Provision = provision::read(provider);
        let provider_last_absorption_id: ufelt = provider_last_absorption::read(provider);
        let current_absorption_id: ufelt = absorptions_count::read();

        let (absorbed_assets, absorbed_asset_amts) = get_absorbed_assets_for_provider_internal(
            provider, provision, provider_last_absorption_id, current_absorption_id
        );

        // Get accumulated rewards
        let rewards_count: ufelt = rewards_count::read();
        let current_epoch: u32 = current_epoch::read();
        let (reward_assets, reward_asset_amts) = get_provider_accumulated_rewards(
            provider, provision, current_epoch, REWARDS_LOOP_START, rewards_count
        );

        // Add pending rewards
        let total_shares: Wad = total_shares::read();
        let has_providers: bool = total_shares.is_non_zero();

        let current_provider_shares: Wad = convert_epoch_shares(
            provision.epoch, current_epoch, provision.shares
        );
        let has_shares: bool = current_provider_shares.is_non_zero();

        let has_pending_rewards: bool = has_providers & has_shares;

        if !(has_providers & has_shares) {
            return (absorbed_assets, absorbed_asset_amts, reward_assets, reward_asset_amts, );
        }

        let updated_reward_asset_amts: Array<u128> = get_provider_pending_rewards(
            provider, current_provider_shares, total_shares, current_epoch, 1, reward_assset_amts
        );

        return (absorbed_assets, absorbed_asset_amts, reward_assets, updated_reward_asset_amts, );
    }


    //
    // Setters
    //

    #[external]
    fn set_purger(purger_addr: ContractAddress) {
        //AccessControl.assert_has_role(AbsorberRoles.SET_PURGER);

        assert(purger_addr.is_non_zero(), 'AB: Address cannot be 0');

        let shrine_addr: ContractAddress = shrine_address::read();
        let yin = IERC20Dispatcher { contract_address: shrine_addr };

        // Approve new address for unlimited balance of yin
        yin.approve(purger, u256 { low: ALL_ONES, high: ALL_ONES });

        let old_purger_addr: ContractAddress = purger_address::read();
        purger_address::write(purger_addr);
        PurgerUpdated(old_purger_addr, purger_addr);

        // Remove allowance for previous address
        if (old_purger_addr != 0) {
            yin.approve(old_purger_addr, u256 { low: 0, high: 0 });
        }
    }

    #[external]
    fn set_reward(asset_addr: ContractAddress, blesser_addr: ContractAddress, is_active: bool) {
        //AccessControl.assert_has_role(AbsorberRoles.SET_REWARD);

        assert(asset_addr.is_non_zero() & blesser_addr.is_non_zero(), 'AB: Address cannot be 0');

        let reward: Reward = Reward { asset_addr, blesser, is_active };

        // If this reward token hasn't been added yet, add it to the list first
        let reward_id: u8 = reward_id::read(asset_addr);
        if reward_id == 0 {
            let current_count: u8 = rewards_count::read();
            let new_count: ufelt = current_count + 1;

            rewards_count::write(new_count);
            reward_id::write(asset_addr, new_count);
            rewards::write(new_count, reward);

            RewardSet(asset_addr, blesser_addr, is_active);
        }

        rewards::write(reward_id, reward);

        // Event emission
        RewardSet(asset_addr, blesser_addr, is_active);
    }

    #[external]
    fn set_removal_limit(limit: Ray) {
        //AccessControl.assert_has_role(AbsorberRoles.SET_REMOVAL_LIMIT);
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
        let provision: Provision = provision::read(provider);
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
        provision::write(provider, Provision { epoch: current_epoch, shares: new_shares });

        // Update total shares for current epoch
        let new_total_shares: Wad = total_shares::read() + issued_shares;
        total_shares::write(new_total_shares);

        // Perform transfer of yin
        let shrine_addr: ContractAddress = shrine_address::read();
        let absorber_addr: ContractAddress = get_contract_address();
        let amount_uint: u256 = WadRay.to_uint(amount);

        let success: bool = IERC20Dispatcher {
            contract_address: shrine
        }.transfer_from(provider, absorber, amount.val.into());
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
        let provision: Provision = provision::read(provider);
        assert_provider(provision);

        let request: Request = provider_request::read(provider);
        let current_timestamp: u64 = get_block_timestamp();

        let mut timelock: u64 = REQUEST_BASE_TIMELOCK;
        if request.timestamp
            + REQUEST_COOLDOWN > current_timestamp {
                time_lock = request.time_lock * REQUEST_TIMELOCK_COOLDOWN_MULTIPLIER;
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
        let provision: Provision = provision::read(provider);
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

        if current_provider_shares == 0 {
            // If no remaining shares after converting across epochs,
            // provider's deposit has been completely absorbed.
            // Since absorbed collateral have been reaped,
            // we can update the provision to current epoch and shares.
            provision::write(provider, Provision { epoch: current_epoch, timestamp: 0 });

            provider_request::write(
                provider,
                Request {
                    timestamp: request.timestamp, timelock: request.timelock, has_removed: true
                }
            );

            // Event emission
            Remove(provider, current_epoch, 0);
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

            let _new_total_shares: Wad = total_shares::read() - shares_to_remove;
            total_shares::write(new_total_shares);

            // Update provision
            let new_provider_shares: Wad = current_provider_shares - shares_to_remove;
            provision::write(
                provider, Provision { epoch: current_epoch, shares: new_provider_shares }
            );

            provider_request::write(
                provider,
                Request {
                    timestamp: request.timestamp, timelock: request.timelock, has_removed: true
                }
            );

            let yin_amt_uint: u256 = yin_amt.val.into();
            let shrine_addr: ContractAddress = shrine_address::read();
            let success: bool = IERC20Dispatcher {
                contract_address: shrine
            }.transfer(provider, yin_amt_uint);
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
        let provision: Provision = provision::read(provider);
        assert_provider(provision);

        let current_epoch: u32 = current_epoch::read();

        reap_internal(provider, provision, current_epoch);

        // Update provider's epoch and shares to current epoch's
        // Epoch must be updated to prevent provider from repeatedly claiming rewards
        let current_provider_shares: Wad = convert_epoch_shares(
            provision.epoch, current_epoch, provision.shares
        );
        provision::write(
            provider, Provision { epoch: current_epoch, shares: current_provider_shares }
        );
    }

    // Update assets received after an absorption
    #[external]
    fn update(assets: Array<ContractAddress>, asset_amts: Array<u128>) {
        //AccessControl.assert_has_role(AbsorberRoles.UPDATE);
        let assets_span: Span<ContractAddress> = assets.span();
        let asset_amts_span: Span<u128> = asset_amts.span();

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
        let mut assets_span: Span<ContractAddress> = assets.span();
        let mut asset_amts_span: Span<u128> = asset_amts.span();
        loop {
            match assets_span.pop_front() {
                Option::Some(asset_addr) => {
                    let asset_amt: u128 = *asset_amts_span.pop_front().unwrap();
                    update_absorbed_asset(
                        current_absorption_id, total_shares, *asset_adr, asset_amt
                    );
                },
                Option::None => {
                    break ();
                }
            };
        };

        // Emit `Gain` event
        Gain(assets, asset_amts, total_shares, current_epoch, current_absorption_id);

        // Increment epoch ID if yin per share drops below threshold or stability pool is emptied
        let shrine_addr: ContractAddress = shrine_address::read();
        let absorber_addr: ContractAddress = get_contract_address();
        let yin_balance_uint: Uint256 = IERC20Dispatcher {
            contract_address: shrine
        }.balance_of(absorber);
        let yin_balance: Wad = Wad { val: yin_balance_uint.try_into().unwrap() };
        let yin_per_share: Wad = yin_balance / total_shares;

        // This also checks for absorber's yin balance being emptied because yin per share will be
        // below threshold if yin balance is 0.
        let above_threshold: bool = is_nn_le(YIN_PER_SHARE_THRESHOLD, yin_per_share);
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
            yin_balance_for_shares -= INITIAL_SHARES;
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
        propagate_reward_errors_loop(REWARDS_LOOP_START, rewards_count, current_epoch);
    }

    #[external]
    fn kill() {
        //AccessControl.assert_has_role(AbsorberRoles.KILL);
        is_live::write(false);
        Killed();
    }

    #[external]
    fn compensate(
        recipient: ContractAddress, assets: Array<ContractAddress>, asset_amts: Array<u128>
    ) {
        //AccessControl.assert_has_role(AbsorberRoles.COMPENSATE);
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
        RemovalLimitSet(prev_limit, limit);
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
            return (Wad { val: yin_amt.val - INITIAL_SHARES }, INITIAL_SHARES);
        }

        let shrine_addr: ContractAddress = shrine_address::read();
        let absorber_addr: ContractAddress = get_contract_address();
        let yin_balance: Wad = Wad {
            val: IERC20Dispatcher {
                contract_address: shrine_addr
            }.balance_of(absorber_addr).try_into().unwrap()
        };

        // TODO: This could easily overflow, should be done with u256
        let (computed_shares, r) = u128_safe_divmod(
            yin_amt.val * total_shares.val, yin_balance.val
        );
        if round_up & r != 0 {
            return (computed_shares + 1, computed_shares + 1);
        }
        (computed_shares, computed_shares)
    }

    // This implementation is slightly different from Gate because the concept of shares is
    // used for internal accounting only, and both shares and yin are wads.
    fn convert_to_yin(shares_amt: Wad) -> Wad {
        let total_shares: Wad = total_shares::read();

        // If no shares are issued yet, then it is a new epoch and absorber is emptied.
        if total_shares.is_zero() {
            return Wad { val: 0 };
        }

        let shrine_addr: ContractAddress = shrine_address::read();
        let absorber_addr: ContractAddress = get_contract_address();
        let yin_balance: Wad = Wad {
            val: IERC20Dispatcher {
                contract_address: shrine_addr
            }.balance_of(absorber_addr).try_into().unwrap()
        };

        let yin: Wad = (shares_amt * yin_balance) / total_shares;
        yin
    }

    // Convert an epoch's shares to a subsequent epoch's shares
    // Return argument is named for testing
    fn convert_epoch_shares(start_epoch: u32, end_epoch: u32, start_shares: Wad) -> Wad {
        if start_epoch == end_epoch {
            return (start_shares, );
        }

        let epoch_conversion_rate: Ray = epoch_share_conversion_rate::read(start_epoch);

        // `rmul` of a wad and a ray returns a wad
        let new_shares: Wad = wadray::rmul_wr(start_shares, epoch_conversion_rate);

        return convert_epoch_shares(start_epoch + 1, end_epoch, new_shares);
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
        let total_amount_to_distribute: Wad = amount + last_error;

        let asset_amt_per_share: Wad = total_amount_to_distribute / total_shares;
        let actual_amount_distributed: u128 = asset_amt_per_share * total_shares;
        let error: u128 = (total_amount_to_distribute - actual_amount_distributed).val;

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
            provider, provision, current_epoch, REWARDS_LOOP_START
        );
        transfer_assets(provider, reward_assets, reward_asset_amts);

        update_provider_cumulative_rewards_loop(
            provider, current_epoch, REWARDS_LOOP_START, reward_assets
        );

        Reap(provider, absorbed_assets, absorbed_asset_amts, reward_assets, reward_asset_amts, );
    }

    // Internal function to calculate the absorbed assets that a provider is entitled to
    fn get_absorbed_assets_for_provider_internal(
        provider: ContractAddress,
        provision: Provision,
        provided_absorption_id: u32,
        current_absorption_id: u32
    ) -> (Array<ContractAddress>, Array<u128>) {
        // Early termination by returning empty arrays
        if provision.shares.is_zero() | current_absorption_id =
            provided_absorption_id {
                return (Array::new(), Array::new());
            }

        let assets: Array<ContractAddress> = ISentinelDispatcher {
            contract_address: sentinel_address::read()
        }.get_yang_addresses();
    }
}
