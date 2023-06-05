#[contract]
mod Purger {
    use array::{ArrayTrait, SpanTrait};
    use cmp::min;
    use starknet::{ContractAddress, get_caller_address};
    use traits::{Default, Into};
    use zeroable::Zeroable;

    use aura::interfaces::IAbsorber::{IAbsorberDispatcher, IAbsorberDispatcherTrait};
    use aura::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::reentrancy_guard::ReentrancyGuard;
    use aura::utils::serde;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RayZeroable, RAY_ONE, Wad, WadZeroable};

    // This is mulitplied by a trove's threshold to determine the minimum LTV 
    // the trove should have after a liquidation. 
    const THRESHOLD_MARGIN: u128 = 900000000000000000000000000; // 0.9 (ray)

    // Maximum liquidation penalty (ray): 0.125 * RAY_ONE
    const MAX_PENALTY: u128 = 125000000000000000000000000;

    // Minimum liquidation penalty (ray): 0.03 * RAY_ONE
    const MIN_PENALTY: u128 = 30000000000000000000000000;

    // LTV at the maximum liquidation penalty (ray): 0.8888 * RAY_ONE
    // `absorb` can be called only if a trove's LTV exceeds this value
    const MAX_PENALTY_LTV: u128 = 888800000000000000000000000;

    // Percentage of each asset being freed in `absorb`
    // that's transferred to the caller as compensation: 0.03 (Ray)
    const COMPENSATION_PCT: u128 = 30000000000000000000000000;

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
    }

    //
    // Events
    //

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
        shrine: ContractAddress,
        sentinel: ContractAddress,
        absorber: ContractAddress,
        oracle: ContractAddress,
    ) {
        shrine::write(IShrineDispatcher { contract_address: shrine });
        sentinel::write(ISentinelDispatcher { contract_address: sentinel });
        absorber::write(IAbsorberDispatcher { contract_address: absorber });
        oracle::write(IOracleDispatcher { contract_address: oracle });
    }

    //
    // View
    //

    // Returns the liquidation penalty based on the LTV (ray)
    // Returns 0 if trove is healthy
    #[view]
    fn get_penalty(trove_id: u64) -> Ray {
        let (threshold, ltv, value, debt) = shrine::read().get_trove_info(trove_id);

        if ltv <= threshold {
            return RayZeroable::zero();
        }

        get_penalty_internal(threshold, ltv, value, debt)
    }

    // Returns the maximum amount of debt that can be closed for a Trove based on the close factor
    // Returns 0 if trove is healthy
    #[view]
    fn get_max_close_amount(trove_id: u64) -> Wad {
        let (threshold, ltv, _, debt) = shrine::read().get_trove_info(trove_id);

        if ltv <= threshold {
            return WadZeroable::zero();
        }

        get_max_close_amount_internal(ltv, debt)
    }

    //
    // External
    //

    // Performs searcher liquidations that requires the caller address to supply the amount of debt to repay
    // and the recipient address to send the freed collateral to.
    // Reverts if:
    // - the trove is not liquidatable (i.e. LTV > threshold).
    // - the repayment amount exceeds the maximum amount as determined by the close factor.
    // - if the trove's LTV is worse off than before the liquidation (should not be possible, but as a precaution)
    // Returns a tuple of an ordered array of yang addresses and an ordered array of freed collateral amounts
    // in the decimals of each respective asset due to the recipient for performing the liquidation.
    #[external]
    fn liquidate(
        trove_id: u64, amt: Wad, recipient: ContractAddress
    ) -> (Span<ContractAddress>, Span<u128>) {
        let shrine: IShrineDispatcher = shrine::read();
        let (trove_threshold, trove_ltv, trove_value, trove_debt) = shrine.get_trove_info(trove_id);

        assert(trove_threshold < trove_ltv, 'PU: Not liquidatable');

        // Cap the liquidation amount to the trove's maximum close amount
        let max_close_amt: Wad = get_max_close_amount_internal(trove_ltv, trove_debt);
        let purge_amt: Wad = min(amt, max_close_amt);

        let percentage_freed: Ray = get_percentage_freed(
            trove_threshold, trove_ltv, trove_value, trove_debt, purge_amt
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

        assert(trove_ltv.val > MAX_PENALTY_LTV, 'PU: Not absorbable');

        let caller: ContractAddress = get_caller_address();
        let absorber: IAbsorberDispatcher = absorber::read();

        let absorber_yin_bal: Wad = shrine.get_yin(absorber.contract_address);

        let compensation_pct: Ray = get_compensation_pct(trove_value);

        // Transfer a percentage of the trove value as compensation to caller.
        // This is independent of the amount of yin repaid by the absorber.
        let (yangs, compensations) = free(shrine, trove_id, compensation_pct, caller);

        // If absorber does not have sufficient yin balance to pay down the trove's debt in full,
        // cap the amount to pay down to the absorber's balance (including if it is zero).
        let purge_amt: Wad = min(trove_debt, absorber_yin_bal);

        let can_absorb_any: bool = purge_amt.is_non_zero();
        let is_fully_absorbed: bool = purge_amt == trove_debt;

        // Only update the absorber and emit the `Purged` event if Absorber has some yin  
        // to melt the trove's debt and receive freed trove assets in return
        if can_absorb_any {
            // Calculate the percentage of the remaining trove value (after deducting the compensation) 
            // that should be transferred to the Absorber for repaying the `purge_amt`.
            // This value is set to 100% for a full absorption, or otherwise calculated based on the 
            // absorber's yin balance.
            let percentage_freed: Ray = if is_fully_absorbed {
                RAY_ONE.into()
            } else {
                get_percentage_freed(trove_threshold, trove_ltv, trove_value, trove_debt, purge_amt)
            };

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
    // Note: this function reverts if the trove's LTV is below its threshold
    #[inline(always)]
    fn get_max_close_amount_internal(
        debt: Wad, value: Wad, ltv: Ray, threshold: Ray, penalty: Ray
    ) -> Wad {
        let penalty_multiplier = RAY_ONE.into() + penalty;
        if ltv >= RAY_ONE.into() / penalty_multiplier {
            return debt;
        }

        let target_ltv = THRESHOLD_MARGIN.into() * threshold;

        wadray::rdiv_wr(
            debt - wadray::rmul_wr(value, target_ltv),
            RAY_ONE.into() - penalty_multiplier * target_ltv
        )
    }

    // Assumption: Trove's LTV has exceeded its threshold
    //
    //                                                maxLiqPenalty - minLiqPenalty
    // 1. If LTV <= MAX_PENALTY_LTV, penalty = LTV * ------------------------------- + b
    //                                                maxPenaltyLTV - liqThreshold
    //
    //                                       = LTV * m + b
    //
    //    `b` is to be derived by solving `penalty = LTV * m + b` using the minimum liquidation
    //     penalty, the derived `m` and the trove's threshold.
    //
    //                                               (trove_value - trove_debt)
    // 2. If MAX_PENALTY_LTV < LTV <= 100%, penalty = -------------------------
    //                                                      trove_debt
    //
    // 3. If 100% < LTV, penalty = 0
    fn get_penalty_internal(
        trove_threshold: Ray, trove_ltv: Ray, trove_value: Wad, trove_debt: Wad, 
    ) -> Ray {
        if trove_ltv.val >= RAY_ONE {
            return RayZeroable::zero();
        }

        if trove_ltv.val <= MAX_PENALTY_LTV {
            let m: Ray = (MAX_PENALTY - MIN_PENALTY).into()
                / (MAX_PENALTY_LTV.into() - trove_threshold);
            let b: Ray = MIN_PENALTY.into() - (trove_threshold * m);
            return (trove_ltv * m) + b;
        }

        wadray::rdiv_ww(trove_value - trove_debt, trove_debt)
    }

    // Helper function to calculate percentage of collateral freed.
    // If LTV <= 100%, calculate based on the sum of amount paid down and liquidation penalty divided
    // If LTV > 100%, pro-rate based on amount paid down divided by total debt.
    // by total trove value.
    fn get_percentage_freed(
        trove_threshold: Ray, trove_ltv: Ray, trove_value: Wad, trove_debt: Wad, purge_amt: Wad, 
    ) -> Ray {
        if trove_ltv.val <= RAY_ONE {
            let penalty: Ray = get_penalty_internal(
                trove_threshold, trove_ltv, trove_value, trove_debt
            );
            let penalty_amt: Wad = wadray::rmul_wr(purge_amt, penalty);
            // Capping the freed amount to the maximum possible (which is the trove's entire value)
            let freed_amt: Wad = min(penalty_amt + purge_amt, trove_value);

            wadray::rdiv_ww(freed_amt, trove_value)
        } else {
            wadray::rdiv_ww(purge_amt, trove_debt)
        }
    }

    // Returns the amount of compensation due to the caller of `absorb` as a percentage of 
    // the value of the trove's collateral, capped at 3% of the trove's value or the percentage
    // of the trove's value equivalent to `COMPENSATION_CAP`.
    fn get_compensation_pct(trove_value: Wad) -> Ray {
        let default_compensation_pct: Ray = COMPENSATION_PCT.into();
        let default_compensation: Wad = wadray::rmul_wr(trove_value, default_compensation_pct);
        if default_compensation.val < COMPENSATION_CAP {
            default_compensation_pct
        } else {
            wadray::rdiv_ww(COMPENSATION_CAP.into(), trove_value)
        }
    }
}
