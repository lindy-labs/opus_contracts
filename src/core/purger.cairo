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
        funder: ContractAddress,
        recipient: ContractAddress,
        percentage_freed: Ray,
        yangs: Span<ContractAddress>,
        freed_assets_amts: Span<u128>,
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
    // in the decimals of each respective asset.
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
        let (yangs, freed_assets_amts) = purge(
            shrine, trove_id, trove_ltv, checked_amt, percentage_freed, funder, recipient
        );

        // Safety check to ensure the new LTV is lower than old LTV 
        let (_, updated_trove_ltv, _, _) = shrine.get_trove_info(trove_id);
        assert(updated_trove_ltv <= trove_ltv, 'PU: LTV increased');

        (yangs, freed_assets_amts)
    }

    // Performs stability pool liquidations to pay down a trove's debt in full and transfer the 
    // freed collateral to the stability pool. If the stability pool does not have sufficient yin, 
    // the trove's debt and collateral will be proportionally redistributed among all troves 
    // containing the trove's collateral.
    // - Amount of debt distributed to each collateral = (value of collateral / trove value) * trove debt
    // Reverts if the trove's LTV is not above the maximum penalty LTV
    // - This also checks the trove is liquidatable because threshold must be lower than max penalty LTV.
    // Returns a tuple of an ordered array of yang addresses and an ordered array of amount of asset freed
    // in the decimals of each respective asset.
    #[external]
    fn absorb(trove_id: u64) -> (Span<ContractAddress>, Span<u128>) {
        let shrine: IShrineDispatcher = shrine::read();
        let (trove_threshold, trove_ltv, trove_value, trove_debt) = shrine.get_trove_info(trove_id);

        assert(trove_ltv.val > MAX_PENALTY_LTV, 'PU: Not absorbable');

        let caller: ContractAddress = get_caller_address();
        let absorber: IAbsorberDispatcher = absorber::read();

        let absorber_yin_bal: Wad = shrine.get_yin(absorber.contract_address);

        // This `if` branch means the debt is fully absorbable by the Absorber
        if trove_debt <= absorber_yin_bal {
            let (yangs, freed_assets_amts) = purge(
                shrine,
                trove_id,
                trove_ltv,
                trove_debt,
                RAY_ONE.into(), // Set `percentage_freed` to 100%
                absorber.contract_address,
                absorber.contract_address
            );

            // Calculate the compensation as a percentage of the freed value, which 
            // in this case is the entire trove's value
            let compensation_pct: Ray = get_compensation_pct(trove_value);
            let (absorbed_assets, compensations) = split_purged_assets(
                compensation_pct, freed_assets_amts
            );

            absorber.compensate(caller, yangs, compensations);
            absorber.update(yangs, absorbed_assets);

            (yangs, freed_assets_amts)
        } else {
            if absorber_yin_bal.is_non_zero() {
                let percentage_freed: Ray = get_percentage_freed(
                    trove_threshold, trove_ltv, trove_value, trove_debt, absorber_yin_bal
                );
                let (yangs, freed_assets_amts) = purge(
                    shrine,
                    trove_id,
                    trove_ltv,
                    absorber_yin_bal,
                    percentage_freed,
                    absorber.contract_address,
                    absorber.contract_address
                );

                // Calculate the compensation as a percentage of the freed value, which 
                // in this case is the trove's value corresponding to the percentage freed
                let freed_value: Wad = wadray::rmul_wr(trove_value, percentage_freed);
                let compensation_pct: Ray = get_compensation_pct(freed_value);

                let (absorbed_assets, compensations) = split_purged_assets(
                    compensation_pct, freed_assets_amts
                );
                absorber.compensate(caller, yangs, compensations);
                absorber.update(yangs, absorbed_assets);

                shrine.redistribute(trove_id);

                // Update yang prices due to an appreciation in ratio of asset to yang from 
                // redistribution
                oracle::read().update_prices();

                (yangs, freed_assets_amts)
            } else {
                // Calculate the compensation as a percentage of the freed value, which 
                // in this case is the entire trove's value that would have been redistributed
                let compensation_pct: Ray = get_compensation_pct(trove_value);

                // Transfer the compensation to the absorber before redistributing the 
                // remaining trove value
                let (yangs, compensations) = purge(
                    shrine,
                    trove_id,
                    trove_ltv,
                    WadZeroable::zero(), // zero, because absorber has zero yin
                    compensation_pct,
                    absorber.contract_address,
                    absorber.contract_address
                );
                absorber.compensate(caller, yangs, compensations);

                shrine.redistribute(trove_id);

                // Update yang prices due to an appreciation in ratio of asset to yang from 
                // redistribution
                oracle::read().update_prices();

                (yangs, compensations)
            }
        }
    }

    //
    // Internal
    //

    // Internal function to handle the paying down of a trove's debt in return for the
    // corresponding freed collateral to be sent to the recipient address
    // Returns a tuple of an ordered array of yang addresses and an ordered array of freed collateral 
    // asset amounts in the decimals of each respective asset.
    fn purge(
        shrine: IShrineDispatcher,
        trove_id: u64,
        trove_ltv: Ray,
        purge_amt: Wad,
        percentage_freed: Ray,
        funder: ContractAddress,
        recipient: ContractAddress,
    ) -> (Span<ContractAddress>, Span<u128>) {
        // Melt from the funder address directly
        shrine.melt(funder, trove_id, purge_amt);

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

        Purged(
            trove_id,
            purge_amt,
            funder,
            recipient,
            percentage_freed,
            yangs,
            freed_assets_amts.span()
        );

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
