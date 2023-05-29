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

    // Close factor function parameters
    // (ray): 2.7 * RAY_ONE
    const CF1: u128 = 2700000000000000000000000000;
    // (ray): 0.22 * RAY_ONE
    const CF2: u128 = 220000000000000000000000000;

    // Maximum liquidation penalty (ray): 0.125 * RAY_ONE
    const MAX_PENALTY: u128 = 125000000000000000000000000;

    // Minimum liquidation penalty (ray): 0.03 * RAY_ONE
    const MIN_PENALTY: u128 = 30000000000000000000000000;

    // LTV at the maximum liquidation penalty (ray): 0.8888 * RAY_ONE
    // `absorb` can be called only if a trove's LTV exceeds this value
    const MAX_PENALTY_LTV: u128 = 888800000000000000000000000;

    // Percentage of each asset being purged in `absorb`
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
    // - if the trove's LTV is worse off than before the purge (should not be possible, but as a precaution)
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
        let checked_amt: Wad = min(amt, max_close_amt);

        let percentage_freed: Ray = get_percentage_freed(
            trove_threshold, trove_ltv, trove_value, trove_debt, checked_amt
        );

        let funder: ContractAddress = get_caller_address();

        // Melt from the funder address directly
        shrine.melt(funder, trove_id, checked_amt);

        // Free collateral corresopnding to the purged amount
        let (yangs, freed_assets_amts) = free(shrine, trove_id, percentage_freed, recipient);

        // Safety check to ensure the new LTV is lower than old LTV 
        let (_, updated_trove_ltv, _, _) = shrine.get_trove_info(trove_id);
        assert(updated_trove_ltv <= trove_ltv, 'PU: LTV increased');

        Purged(
            trove_id, checked_amt, percentage_freed, funder, recipient, yangs, freed_assets_amts, 
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

        // Use `purge` to transfer compensation to caller
        let (yangs, compensations) = free(shrine, trove_id, compensation_pct, caller);

        // Cap the liquidation amount to the trove's maximum close amount
        let purge_amt: Wad = min(trove_debt, absorber_yin_bal);

        // Set the initial value of `percentage_freed` to 100%, assuming a full absorption
        // If it is not a full absorption, calculate `percentage_freed` based on the absorber's yin balance.
        let mut percentage_freed: Ray = RAY_ONE.into();
        let is_fully_absorbed: bool = purge_amt == trove_debt;
        if !is_fully_absorbed {
            percentage_freed =
                get_percentage_freed(
                    trove_threshold, trove_ltv, trove_value, trove_debt, purge_amt
                );
        }

        // Melt the trove's debt using the absorber's yin directly
        shrine.melt(absorber.contract_address, trove_id, purge_amt);

        // Free collateral corresopnding to the purged amount
        // If `percentage_freed` is zero, return values are empty arrays.
        let (yangs, absorbed_assets_amts) = free(
            shrine, trove_id, percentage_freed, absorber.contract_address
        );

        // If array arguments are empty, `absorber.update` is returned early.
        absorber.update(yangs, absorbed_assets_amts);

        // If it is not a full absorption, perform redistribution.
        if !is_fully_absorbed {
            shrine.redistribute(trove_id);

            // Update yang prices due to an appreciation in ratio of asset to yang from 
            // redistribution
            oracle::read().update_prices();
        }

        // Only emit the event if Absorber's yin balance was used to melt the 
        // trove's debt and some assets were freed to the Absorber
        if yangs.len().is_non_zero() {
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
        let sentinel: ISentinelDispatcher = sentinel::read();
        let yangs: Span<ContractAddress> = sentinel.get_yang_addresses();
        let mut freed_assets_amts: Array<u128> = Default::default();

        let mut yangs_copy: Span<ContractAddress> = yangs;

        // Early return if nothing to free (e.g. full redistribution)
        if percentage_freed.is_zero() {
            let yangs: Array<ContractAddress> = Default::default();
            let asset_amts: Array<u128> = Default::default();
            return (yangs.span(), asset_amts.span());
        }

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

                    // reentrancy guard is used as a precaution
                    ReentrancyGuard::start();
                    let freed_asset_amt: u128 = sentinel
                        .exit(*yang, recipient, trove_id, freed_yang);
                    freed_assets_amts.append(freed_asset_amt);
                    shrine.seize(*yang, trove_id, freed_yang);
                    ReentrancyGuard::end();
                },
                Option::None(_) => {
                    break;
                }
            };
        };

        (yangs, freed_assets_amts.span())
    }

    // Returns the close factor based on the LTV (ray)
    // closeFactor = 2.7 * (LTV ** 2) - 2 * LTV + 0.22
    //              [CF1]                        [CF2]
    #[inline(always)]
    fn get_close_factor(ltv: Ray) -> Ray {
        (CF1.into() * (ltv * ltv)) - (2 * ltv.val).into() + CF2.into()
    }

    #[inline(always)]
    fn get_max_close_amount_internal(trove_ltv: Ray, debt: Wad) -> Wad {
        let close_amt: Wad = wadray::rmul_wr(debt, get_close_factor(trove_ltv));
        min(debt, close_amt)
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
            let freed_amt: Wad = penalty_amt + purge_amt;

            wadray::rdiv_ww(freed_amt, trove_value)
        } else {
            wadray::rdiv_ww(purge_amt, trove_debt)
        }
    }

    // Returns the amount of compensation due to the caller of `absorb` as a percentage of 
    // the value of:
    // - the freed collateral (in the case of full absorptions and partial absorptions 
    // with redistributions); or 
    // - the trove's collateral (in the case of a full redistribution).
    fn get_compensation_pct(freed_value: Wad) -> Ray {
        let base_compensation_pct: Ray = COMPENSATION_PCT.into();
        let base_compensation: Wad = wadray::rmul_wr(freed_value, base_compensation_pct);
        if base_compensation.val < COMPENSATION_CAP {
            base_compensation_pct
        } else {
            wadray::rdiv_ww(COMPENSATION_CAP.into(), freed_value)
        }
    }

    // Divide the purged assets into two groups - one that's kept in the Absorber and
    // another one that's sent to the caller as compensation. `freed_assets_amts` values
    // are in decimals of each token (hence using `u128`).
    // Returns a tuple of an ordered array of freed collateral asset amounts due to absorber 
    // and an ordered array of freed collateral asset amounts due to caller as compensation
    fn split_purged_assets(
        split_pct: Ray, mut freed_assets_amts: Span<u128>
    ) -> (Span<u128>, Span<u128>) {
        let mut absorbed_assets: Array<u128> = Default::default();
        let mut compensations: Array<u128> = Default::default();

        loop {
            match freed_assets_amts.pop_front() {
                Option::Some(amount) => {
                    // Rounding is intended to benefit the protocol
                    let compensation: Wad = wadray::rmul_wr((*amount).into(), split_pct);
                    compensations.append(compensation.val);
                    absorbed_assets.append(*amount - compensation.val);
                },
                Option::None(_) => {
                    break (absorbed_assets.span(), compensations.span());
                }
            };
        }
    }
}
