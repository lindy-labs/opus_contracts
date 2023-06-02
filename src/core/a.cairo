//
// Setters
//

fn set_reward(
    ref self: Storage, asset: ContractAddress, blesser: ContractAddress, is_active: bool
) {
    AccessControl::assert_has_role(AbsorberRoles::SET_REWARD);

    assert(asset.is_non_zero() & blesser.is_non_zero(), 'ABS: Address cannot be 0');

    let reward: Reward = Reward {
        asset, blesser: IBlesserDispatcher { contract_address: blesser }, is_active
    };

    // If this reward token hasn't been added yet, add it to the list
    let reward_id: u8 = self.reward_id.read(asset);

    if reward_id == 0 {
        let current_count: u8 = self.rewards_count.read();
        let new_count = current_count + 1;

        self.rewards_count.write(new_count);
        self.reward_id.write(asset, new_count);
        self.rewards.write(new_count, reward);
    } else {
        // Otherwise, update the existing reward
        self.rewards.write(reward_id, reward);
    }

    // Emit event 
    RewardSet(asset, blesser, is_active);
}


fn set_removal_limit(ref self: Storage, limit: Ray) {
    AccessControl::assert_has_role(AbsorberRoles::SET_REMOVAL_LIMIT);
    set_removal_limit_internal(limit);
}


//
// External
//

// Supply yin to the absorber.
// Requires the caller to have approved spending by the absorber.

fn provide(ref self: Storage, amount: Wad) {
    assert_live();

    let current_epoch: u32 = self.current_epoch.read();
    let provider: ContractAddress = get_caller_address();

    // Withdraw absorbed collateral before updating shares
    let provision: Provision = self.provisions.read(provider);
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
    self.provisions.write(provider, Provision { epoch: current_epoch, shares: new_shares });

    // Update total shares for current epoch
    let new_total_shares: Wad = self.total_shares.read() + issued_shares;
    self.total_shares.write(new_total_shares);

    // Perform transfer of yin
    let absorber: ContractAddress = get_contract_address();

    let success: bool = yin_erc20().transfer_from(provider, absorber, amount.into());
    assert(success, 'ABS: Transfer failed');

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

fn request(ref self: Storage, ) {
    let provider: ContractAddress = get_caller_address();
    assert_provider(self.provisions.read(provider));

    let request: Request = self.provider_request.read(provider);
    let current_timestamp: u64 = get_block_timestamp();

    let mut timelock: u64 = REQUEST_BASE_TIMELOCK;
    if request.timestamp + REQUEST_COOLDOWN > current_timestamp {
        timelock = request.timelock * REQUEST_TIMELOCK_MULTIPLIER;
    }

    let capped_timelock: u64 = min(timelock, REQUEST_MAX_TIMELOCK);
    self
        .provider_request
        .write(
            provider,
            Request { timestamp: current_timestamp, timelock: capped_timelock, has_removed: false }
        );
    RequestSubmitted(provider, current_timestamp, capped_timelock);
}

// Withdraw yin (if any) and all absorbed collateral assets from the absorber.

fn remove(ref self: Storage, amount: Wad) {
    let provider: ContractAddress = get_caller_address();
    let provision: Provision = self.provisions.read(provider);
    assert_provider(provision);

    let request: Request = self.provider_request.read(provider);
    assert_can_remove(request);

    let current_epoch: u32 = self.current_epoch.read();

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
        self.provisions.write(provider, Provision { epoch: current_epoch, shares: 0_u128.into() });

        self
            .provider_request
            .write(
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

        // Due to precision loss, if the amount to remove is the max removable,
        // set the shares to be removed as the provider's balance to avoid
        // any remaining dust shares.
        let mut shares_to_remove = current_provider_shares;
        if yin_amt != max_removable_yin {
            let (shares_to_remove_ceiled, _) = convert_to_shares(yin_amt, true);
            shares_to_remove = shares_to_remove_ceiled;
        }

        self.total_shares.write(self.total_shares.read() - shares_to_remove);

        // Update provision
        let new_provider_shares: Wad = current_provider_shares - shares_to_remove;
        self
            .provisions
            .write(provider, Provision { epoch: current_epoch, shares: new_provider_shares });

        self
            .provider_request
            .write(
                provider,
                Request {
                    timestamp: request.timestamp, timelock: request.timelock, has_removed: true
                }
            );

        let success: bool = yin_erc20().transfer(provider, yin_amt.into());
        assert(success, 'ABS: Transfer failed');

        // Event emission
        Remove(provider, current_epoch, yin_amt);
    }
}

// Withdraw absorbed collateral only from the absorber
// Note that `reap` alone will not update a caller's Provision in storage

fn reap(ref self: Storage, ) {
    let provider: ContractAddress = get_caller_address();
    let provision: Provision = self.provisions.read(provider);
    assert_provider(provision);

    let current_epoch: u32 = self.current_epoch.read();

    reap_internal(provider, provision, current_epoch);

    // Update provider's epoch and shares to current epoch's
    // Epoch must be updated to prevent provider from repeatedly claiming rewards
    let current_provider_shares: Wad = convert_epoch_shares(
        provision.epoch, current_epoch, provision.shares
    );
    self
        .provisions
        .write(provider, Provision { epoch: current_epoch, shares: current_provider_shares });
}

// Update assets received after an absorption

fn update(ref self: Storage, mut assets: Span<ContractAddress>, mut asset_amts: Span<u128>) {
    AccessControl::assert_has_role(AbsorberRoles::UPDATE);

    let current_epoch: u32 = self.current_epoch.read();

    // Trigger issuance of rewards
    let rewards_count: u8 = self.rewards_count.read();
    bestow(current_epoch, rewards_count);

    // Increment absorption ID
    let current_absorption_id: u32 = self.absorptions_count.read() + 1;
    self.absorptions_count.write(current_absorption_id);

    // Update epoch for absorption ID
    self.absorption_epoch.write(current_absorption_id, current_epoch);

    let total_shares: Wad = self.total_shares.read();

    // Emit `Gain` event before the loop as `assets` and `asset_amts` are consumed by the loop
    Gain(assets, asset_amts, total_shares, current_epoch, current_absorption_id);

    loop {
        match assets.pop_front() {
            Option::Some(asset) => {
                let asset_amt: u128 = *asset_amts.pop_front().unwrap();
                update_absorbed_asset(current_absorption_id, total_shares, *asset, asset_amt);
            },
            Option::None(_) => {
                break;
            }
        };
    };

    //
    // Increment epoch ID only if yin per share drops below threshold or stability pool is emptied
    //

    let absorber: ContractAddress = get_contract_address();
    let yin_balance: Wad = yin_erc20().balance_of(absorber).try_into().unwrap();
    let yin_per_share: Wad = yin_balance / total_shares;

    // This also checks for absorber's yin balance being emptied because yin per share will be
    // below threshold if yin balance is 0.
    if YIN_PER_SHARE_THRESHOLD > yin_per_share.val {
        let new_epoch: u32 = current_epoch + 1;
        self.current_epoch.write(new_epoch);

        // If new epoch's yin balance exceeds the initial minimum shares, deduct the initial
        // minimum shares worth of yin from the yin balance so that there is at least such amount
        // of yin that cannot be removed in the next epoch.
        if INITIAL_SHARES <= yin_balance.val {
            let epoch_share_conversion_rate: Ray = wadray::rdiv_ww(
                yin_balance - INITIAL_SHARES.into(), total_shares
            );

            self.epoch_share_conversion_rate.write(current_epoch, epoch_share_conversion_rate);
            self.total_shares.write(yin_balance);
        } else {
            // Otherwise, set the epoch share conversion rate to 0 and total shares to 0.
            // This is to prevent an attacker from becoming a majority shareholder
            // in a new epoch when the number of shares is very small, which would 
            // allow them to execute an attack similar to a first-deposit front-running attack.
            // This would cause a negligible loss to the previous epoch's providers, but
            // partially compensates the first provider in the new epoch for the deducted
            // minimum initial amount.
            self.epoch_share_conversion_rate.write(current_epoch, 0_u128.into());
            self.total_shares.write(0_u128.into());
        }

        EpochChanged(current_epoch, new_epoch);

        // Transfer reward errors of current epoch to the next epoch
        propagate_reward_errors(rewards_count, current_epoch);
    }
}


fn kill(ref self: Storage, ) {
    AccessControl::assert_has_role(AbsorberRoles::KILL);
    self.is_live.write(false);
    Killed();
}
