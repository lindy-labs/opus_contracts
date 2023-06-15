#[contract]
mod Purger {
    use array::{ArrayTrait, SpanTrait};
    use cmp::min;
    use option::OptionTrait;
    use starknet::{ContractAddress, get_caller_address};
    use traits::{Default, Into};
    use zeroable::Zeroable;

    use aura::core::roles::PurgerRoles;

    use aura::interfaces::IAbsorber::{IAbsorberDispatcher, IAbsorberDispatcherTrait};
    use aura::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};

    use aura::utils::access_control::AccessControl;
    use aura::utils::reentrancy_guard::ReentrancyGuard;
    use aura::utils::serde;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RayZeroable, RAY_ONE, Wad, WadZeroable};

    // This is multiplied by a trove's threshold to determine the target LTV 
    // the trove should have after a liquidation, which in turn determines the
    // maximum amount of the trove's debt that can be liquidated.
    const THRESHOLD_SAFETY_MARGIN: u128 = 900000000000000000000000000; // 0.9 (ray)

    // Maximum liquidation penalty (ray): 0.125 * RAY_ONE
    const MAX_PENALTY: u128 = 125000000000000000000000000;

    // Minimum liquidation penalty (ray): 0.03 * RAY_ONE
    const MIN_PENALTY: u128 = 30000000000000000000000000;

    // Bounds on the penalty scalar for absorber liquidations
    const MIN_PENALTY_SCALAR: u128 = 1000000000000000000000000000; // 1.0 (ray)
    const MAX_PENALTY_SCALAR: u128 = 1060000000000000000000000000; // 1.06 (ray)

    // LTV past which `absorb` can be called regardless of whether the other 
    // absorption condition has been fulfilled
    const ABSORPTION_THRESHOLD: u128 = 900000000000000000000000000; // 0.9 (ray)

    // Percentage of the liquidation penalty in `absorb`
    // that's transferred to the caller as compensation: 0.2 (Ray)
    const COMPENSATION_PCT: u128 = 200000000000000000000000000;

    // Cap on compensation value: 200 (Wad)
    const COMPENSATION_CAP: u128 = 200000000000000000000;

    struct Storage {
        // the Shrine associated with this Purger
        shrine: IShrineDispatcher,
        // the Sentinel associated with the Shrine and this Purger
        sentinel: ISentinelDispatcher,
        // the Absorber associated with this Purger
        absorber: IAbsorberDispatcher,
        // the Oracle associated with the Shrine and this Purger
        oracle: IOracleDispatcher,
        // Scalar for multiplying penalties above `ABSORPTION_THRESHOLD`
        penalty_scalar: Ray,
    }

    //
    // Events
    //

    #[event]
    fn PenaltyScalarUpdated(new_scalar: Ray) {}

    #[event]
    fn Purged(
        trove_id: u64,
        purge_amt: Wad,
        percentage_freed: Ray,
        funder: ContractAddress,
        recipient: ContractAddress,
        yangs: Span<ContractAddress>,
        freed_assets_amts: Span<u128>,
    ) {}

    #[event]
    fn Compensate(
        recipient: ContractAddress, assets: Span<ContractAddress>, asset_amts: Span<u128>, 
    ) {}

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        admin: ContractAddress,
        shrine: ContractAddress,
        sentinel: ContractAddress,
        absorber: ContractAddress,
        oracle: ContractAddress,
    ) {
        AccessControl::initializer(admin);

        // Grant admin permission
        AccessControl::grant_role_internal(PurgerRoles::default_admin_role(), admin);

        shrine::write(IShrineDispatcher { contract_address: shrine });
        sentinel::write(ISentinelDispatcher { contract_address: sentinel });
        absorber::write(IAbsorberDispatcher { contract_address: absorber });
        oracle::write(IOracleDispatcher { contract_address: oracle });

        penalty_scalar::write(RAY_ONE.into());
        PenaltyScalarUpdated(RAY_ONE.into());
    }

    //
    // View
    //

    // Returns the liquidation penalty based on the LTV (ray)
    // Returns 0 if trove is healthy
    #[view]
    fn get_liquidation_penalty(trove_id: u64, is_absorption: bool) -> Ray {
        let (threshold, ltv, _, _) = shrine::read().get_trove_info(trove_id);

        match get_penalty_internal(threshold, ltv, is_absorption) {
            Option::Some(penalty) => penalty,
            Option::None(_) => RayZeroable::zero(),
        }
    }

    // Returns the maximum amount of debt that can be closed for a Trove
    // Returns 0 if trove is healthy and `is_absorption` is false, or if the trove is not absorbable and 
    // `is_absorption` is true
    #[view]
    fn get_max_close_amount(trove_id: u64, is_absorption: bool) -> Wad {
        let (threshold, ltv, value, debt) = shrine::read().get_trove_info(trove_id);

        match get_penalty_internal(threshold, ltv, is_absorption) {
            Option::Some(penalty) => get_max_close_amount_internal(
                threshold, ltv, value, debt, penalty
            ),
            Option::None(_) => WadZeroable::zero(),
        }
    }

    #[view]
    fn is_absorbable(trove_id: u64) -> bool {
        let (threshold, ltv, value, debt) = shrine::read().get_trove_info(trove_id);

        match get_penalty_internal(threshold, ltv, true) {
            Option::Some(_) => true,
            Option::None(_) => false,
        }
    }

    //
    // External
    //

    #[external]
    fn set_penalty_scalar(new_scalar: Ray) {
        AccessControl::assert_has_role(PurgerRoles::SET_PENALTY_SCALAR);
        assert(
            MIN_PENALTY_SCALAR.into() <= new_scalar & new_scalar <= MAX_PENALTY_SCALAR.into(),
            'PU: Invalid scalar'
        );

        penalty_scalar::write(new_scalar);
        PenaltyScalarUpdated(new_scalar);
    }

    // Performs searcher liquidations that requires the caller address to supply the amount of debt to repay
    // and the recipient address to send the freed collateral to.
    // Reverts if:
    // - the trove is not liquidatable (i.e. LTV > threshold).
    // - if the trove's LTV is worse off than before the liquidation (should not be possible, but as a precaution)
    // Returns a tuple of an ordered array of yang addresses and an ordered array of freed collateral amounts
    // in the decimals of each respective asset due to the recipient for performing the liquidation.
    #[external]
    fn liquidate(
        trove_id: u64, amt: Wad, recipient: ContractAddress
    ) -> (Span<ContractAddress>, Span<u128>) {
        let shrine: IShrineDispatcher = shrine::read();
        let (trove_threshold, trove_ltv, trove_value, trove_debt) = shrine.get_trove_info(trove_id);

        // Panics if the trove is healthy
        let trove_penalty: Ray = get_penalty_internal(trove_threshold, trove_ltv, false)
            .expect('PU: Not liquidatable');
        let max_close_amt: Wad = get_max_close_amount_internal(
            trove_threshold, trove_ltv, trove_value, trove_debt, trove_penalty
        );

        // Cap the liquidation amount to the trove's maximum close amount
        let purge_amt: Wad = min(amt, max_close_amt);

        let percentage_freed: Ray = get_percentage_freed(
            trove_ltv, trove_value, trove_debt, trove_penalty, purge_amt
        );

        let funder: ContractAddress = get_caller_address();

        // Melt from the funder address directly
        shrine.melt(funder, trove_id, purge_amt);

        // Free collateral corresponding to the purged amount
        let (yangs, freed_assets_amts) = free(shrine, trove_id, percentage_freed, recipient);

        // Safety check to ensure the new LTV is lower than old LTV 
        let (_, updated_trove_ltv, _, _) = shrine.get_trove_info(trove_id);
        assert(updated_trove_ltv <= trove_ltv, 'PU: LTV increased');

        Purged(
            trove_id, purge_amt, percentage_freed, funder, recipient, yangs, freed_assets_amts, 
        );

        (yangs, freed_assets_amts)
    }

    // Performs stability pool liquidations to pay down a trove's debt in full and transfer the 
    // freed collateral to the stability pool. If the stability pool does not have sufficient yin, 
    // the trove's debt and collateral will be proportionally redistributed among all troves 
    // containing the trove's collateral.
    // - Amount of debt distributed to each collateral = (value of collateral / trove value) * trove debt
    // Reverts if the trove's LTV is not above the maximum penalty LTV
    // - This also checks the trove is liquidatable because threshold must be lower than max penalty LTV.
    // Returns a tuple of an ordered array of yang addresses and an ordered array of asset amounts
    // in the decimals of each respective asset due to the caller as compensation.
    #[external]
    fn absorb(trove_id: u64) -> (Span<ContractAddress>, Span<u128>) {
        let shrine: IShrineDispatcher = shrine::read();
        let (trove_threshold, trove_ltv, trove_value, trove_debt) = shrine.get_trove_info(trove_id);
        let trove_penalty: Ray = get_penalty_internal(trove_threshold, trove_ltv, true)
            .expect('PU: Not absorbable');

        let caller: ContractAddress = get_caller_address();
        let absorber: IAbsorberDispatcher = absorber::read();

        let compensation_pct: Ray = get_compensation_pct(
            trove_debt, trove_value, trove_ltv, trove_penalty
        );

        // Transfer a percentage of the penalty to the caller as compensation
        //
        // `compensation_pct` must be scaled by `trove_ltv` because 
        // it is a percentage of the trove debt, and `free` requires 
        // a percentage of the trove value.
        let (yangs, compensations) = free(shrine, trove_id, compensation_pct * trove_ltv, caller);

        // Penalty the absorber providers will actually earn after the caller's 
        // compensation is deducted
        let net_penalty = trove_penalty - compensation_pct;

        let absorber_yin_bal: Wad = shrine.get_yin(absorber.contract_address);
        let max_purge_amount: Wad = get_max_close_amount_internal(
            trove_threshold, trove_ltv, trove_value, trove_debt, trove_penalty
        );

        // If absorber does not have sufficient yin balance to pay down the trove's debt in full,
        // cap the amount to pay down to the absorber's balance (including if it is zero).
        let purge_amt = min(max_purge_amount, absorber_yin_bal);

        let can_absorb_any: bool = purge_amt.is_non_zero();
        let is_fully_absorbed: bool = purge_amt == max_purge_amount;

        // Only update the absorber and emit the `Purged` event if Absorber has some yin  
        // to melt the trove's debt and receive freed trove assets in return
        if can_absorb_any {
            let percentage_freed: Ray = get_percentage_freed(
                trove_ltv, trove_value, trove_debt, net_penalty, purge_amt
            );

            // Melt the trove's debt using the absorber's yin directly
            shrine.melt(absorber.contract_address, trove_id, purge_amt);

            // Free collateral corresponding to the purged amount
            let (yangs, absorbed_assets_amts) = free(
                shrine, trove_id, percentage_freed, absorber.contract_address
            );

            absorber.update(yangs, absorbed_assets_amts);
            Purged(
                trove_id,
                purge_amt,
                percentage_freed,
                absorber.contract_address,
                absorber.contract_address,
                yangs,
                absorbed_assets_amts
            );
        }

        // If it is not a full absorption, perform redistribution.
        if !is_fully_absorbed {
            shrine.redistribute(trove_id);

            // Update yang prices due to an appreciation in ratio of asset to yang from 
            // redistribution
            oracle::read().update_prices();
        }

        Compensate(caller, yangs, compensations);

        (yangs, compensations)
    }

    //
    // Internal
    //

    // Internal function to transfer the given percentage of a trove's collateral to the given
    // recipient address.
    // Returns a tuple of an ordered array of yang addresses and an ordered array of freed collateral 
    // asset amounts in the decimals of each respective asset.
    fn free(
        shrine: IShrineDispatcher, trove_id: u64, percentage_freed: Ray, recipient: ContractAddress, 
    ) -> (Span<ContractAddress>, Span<u128>) {
        // reentrancy guard is used as a precaution
        ReentrancyGuard::start();

        let sentinel: ISentinelDispatcher = sentinel::read();
        let yangs: Span<ContractAddress> = sentinel.get_yang_addresses();
        let mut freed_assets_amts: Array<u128> = Default::default();

        let mut yangs_copy: Span<ContractAddress> = yangs;

        // Loop through yang addresses and transfer to recipient
        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => {
                    let deposited_yang_amt: Wad = shrine.get_deposit(*yang, trove_id);

                    // Continue iteration if no yang deposited
                    if deposited_yang_amt.is_zero() {
                        freed_assets_amts.append(0);
                        continue;
                    }

                    let freed_yang: Wad = wadray::rmul_wr(deposited_yang_amt, percentage_freed);

                    let freed_asset_amt: u128 = sentinel
                        .exit(*yang, recipient, trove_id, freed_yang);
                    freed_assets_amts.append(freed_asset_amt);
                    shrine.seize(*yang, trove_id, freed_yang);
                },
                Option::None(_) => {
                    break;
                }
            };
        };

        ReentrancyGuard::end();

        (yangs, freed_assets_amts.span())
    }


    // Returns the maximum amount of debt that can be paid off in a given liquidation
    // Note: this function reverts if the trove's LTV is below its threshold multiplied by `THRESHOLD_SAFETY_MARGIN`
    // because `debt - wadray::rmul_wr(value, target_ltv)` would underflow
    #[inline(always)]
    fn get_max_close_amount_internal(
        threshold: Ray, ltv: Ray, value: Wad, debt: Wad, penalty: Ray
    ) -> Wad {
        let penalty_multiplier = RAY_ONE.into() + penalty;
        // If the LTV is greater than 1 / penalty_multiplier, then the max close amount
        // based on the equation below will be greater than `debt`, so we cap it at `debt`. 
        if ltv >= RAY_ONE.into() / penalty_multiplier {
            return debt;
        }

        let target_ltv = THRESHOLD_SAFETY_MARGIN.into() * threshold;

        wadray::rdiv_wr(
            debt - wadray::rmul_wr(value, target_ltv),
            RAY_ONE.into() - penalty_multiplier * target_ltv
        )
    }

    // Assumes ltv >= threshold
    // If is_absorption == true, assumes threshold >= ABSORPTION_THRESHOLD
    // 1. 
    // 2. 
    // 3. 
    // 4. 
    fn get_penalty_internal(threshold: Ray, ltv: Ray, is_absorption: bool) -> Option<Ray> {
        if ltv <= threshold | (is_absorption & threshold <= ABSORPTION_THRESHOLD.into()) {
            return Option::None(());
        }

        if is_absorption {
            if ltv >= ABSORPTION_THRESHOLD.into() {
                let scalar = penalty_scalar::read();
                let penalty = min(
                    min(
                        MIN_PENALTY.into() + scalar * ltv / threshold - RAY_ONE.into(),
                        MAX_PENALTY.into()
                    ),
                    (RAY_ONE.into() - ltv) / ltv
                );
                return Option::Some(penalty);
            } else {
                let max_possible_penalty = (RAY_ONE.into() - ltv) / ltv;
                let penalty = min(
                    min(MIN_PENALTY.into() + ltv / threshold - RAY_ONE.into(), MAX_PENALTY.into()),
                    max_possible_penalty
                );
                if penalty == max_possible_penalty {
                    return Option::Some(penalty);
                } else {
                    return Option::None(());
                }
            }
        }

        let penalty = min(
            min(MIN_PENALTY.into() + ltv / threshold - RAY_ONE.into(), MAX_PENALTY.into()),
            (RAY_ONE.into() - ltv) / ltv
        );
        Option::Some(penalty)
    }

    // Helper function to calculate percentage of collateral freed.
    // If LTV <= 100%, calculate based on the sum of amount paid down and liquidation penalty divided by total trove value.
    // If LTV > 100%, pro-rate based on amount paid down divided by total debt.
    fn get_percentage_freed(
        trove_ltv: Ray, trove_value: Wad, trove_debt: Wad, penalty: Ray, purge_amt: Wad, 
    ) -> Ray {
        if trove_ltv.val <= RAY_ONE {
            let penalty_amt: Wad = wadray::rmul_wr(purge_amt, penalty);
            // Capping the freed amount to the maximum possible (which is the trove's entire value)
            let freed_amt: Wad = min(penalty_amt + purge_amt, trove_value);

            wadray::rdiv_ww(freed_amt, trove_value)
        } else {
            wadray::rdiv_ww(purge_amt, trove_debt)
        }
    }

    // Returns the amount of compensation due to the caller of `absorb` as a percentage of 
    // the value of the trove's collateral, capped at 20% of the liquidation penalty or
    // `COMPENSATION_CAP`, whichever is smaller.
    fn get_compensation_pct(
        trove_debt: Wad, trove_value: Wad, trove_ltv: Ray, trove_penalty: Ray
    ) -> Ray {
        let default_compensation_pct: Ray = COMPENSATION_PCT.into() * trove_penalty;
        let default_compensation: Wad = wadray::rmul_wr(trove_debt, default_compensation_pct);
        if default_compensation.val < COMPENSATION_CAP {
            // Must be scaled by `trove_ltv` since 
            // we want the compensation to be a percentage of the trove's
            // collateral value and not the trove's debt
            default_compensation_pct * trove_ltv
        } else {
            wadray::rdiv_ww(COMPENSATION_CAP.into(), trove_value)
        }
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

    #[view]
    fn get_pending_admin() -> ContractAddress {
        AccessControl::get_pending_admin()
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
