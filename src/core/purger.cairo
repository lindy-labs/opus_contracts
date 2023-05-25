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
    // that's transferred to the caller as compensation
    const COMPENSATION_PCT: u128 = 3;

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
    // External
    //

    // Performs searcher liquidations that requires the caller address to supply the amount of debt to repay
    // and the recipient address to send the freed collateral to.
    // Reverts if:
    // - the trove is not liquidatable (i.e. LTV > threshold).
    // - the repayment amount exceeds the maximum amount as determined by the close factor.
    // - if the trove's LTV is worse off than before the purge (should not be possible, but as a precaution)
    // Returns a tuple of an ordered array of yang addresses and an ordered array of freed collateral amounts
    #[external]
    fn liquidate(
        trove_id: u64, amt: Wad, recipient: ContractAddress
    ) -> (Span<ContractAddress>, Span<u128>) {
        let shrine: IShrineDispatcher = shrine::read();
        let (trove_threshold, trove_ltv, trove_value, trove_debt) = shrine.get_trove_info(trove_id);

        assert_liquidatable(trove_threshold, trove_ltv);

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
        assert(updated_trove_ltv <= trove_ltv, 'LTV increased');

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
    #[external]
    fn absorb(trove_id: u64) -> (Span<ContractAddress>, Span<u128>) {
        let shrine: IShrineDispatcher = shrine::read();
        let (trove_threshold, trove_ltv, trove_value, trove_debt) = shrine.get_trove_info(trove_id);

        assert_liquidatable(trove_threshold, trove_ltv);
        assert(trove_ltv.val > MAX_PENALTY_LTV, 'Not absorbable');

        let caller: ContractAddress = get_caller_address();
        let absorber: IAbsorberDispatcher = absorber::read();

        let absorber_yin_bal: Wad = shrine.get_yin(absorber.contract_address);

        if trove_debt <= absorber_yin_bal {
            let (yangs, freed_assets_amts) = purge(
                shrine,
                trove_id,
                trove_ltv,
                trove_debt,
                RAY_ONE.into(),
                absorber.contract_address,
                absorber.contract_address
            );

            let (absorbed_assets, compensations) = split_purged_assets(freed_assets_amts);

            absorber.compensate(caller, yangs, compensations);
            absorber.update(yangs, absorbed_assets);

            (yangs, freed_assets_amts)
        } else {
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

            // Split freed amounts to compensate caller for keeping protocol stable
            let (absorbed_assets, compensations) = split_purged_assets(freed_assets_amts);

            shrine.redistribute(trove_id);

            absorber.compensate(caller, yangs, compensations);

            // Update yang prices due to an appreciation in ratio of asset to yang from 
            // redistribution
            oracle::read().update_prices();

            // Only update absorber if its yin was used
            if absorber_yin_bal.val != 0 {
                absorber.update(yangs, freed_assets_amts);
            }

            (yangs, freed_assets_amts)
        }
    }

    //
    // Internal
    //

    // Asserts that a trove is liquidatable given its LTV and threshold
    #[inline(always)]
    fn assert_liquidatable(threshold: Ray, ltv: Ray) {
        assert(ltv > threshold, 'Not liquidatable');
    }

    // Internal function to handle the paying down of a trove's debt in return for the
    // corresponding freed collateral to be sent to the recipient address
    // Returns a tuple of an ordered array of yang addresses and an ordered array of freed collateral 
    // asset amounts
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

        // The denomination for each value in `freed_assets_amts` will be based on the decimals
        // for the respective asset.
        (yangs, freed_assets_amts.span())
    }

    // Returns the close factor based on the LTV (ray)
    // closeFactor = 2.7 * (LTV ** 2) - 2 * LTV + 0.22
    //               [CF1]                       [CF2]
    //               [  factor_one  ] - [ factor_two ]
    #[inline(always)]
    fn get_close_factor(ltv: Ray) -> Ray {
        let factor_one: Ray = CF1.into() * (ltv * ltv);
        let factor_two: Ray = (2 * ltv.val + CF2).into();
        factor_one - factor_two
    }

    #[inline(always)]
    fn get_max_close_amount_internal(trove_ltv: Ray, debt: Wad) -> Wad {
        let close_amt: Wad = wadray::rmul_wr(debt, get_close_factor(trove_ltv));
        min(debt, close_amt)
    }

    // Assumption: Trove's LTV has exceeded its threshold
    //
    //                                              maxLiqPenalty - minLiqPenalty
    // 1. If LTV <= MAX_PENALTY_LTV, penalty = LTV * ----------------------------- + b
    //                                              maxPenaltyLTV - liqThreshold
    //
    //                                      = LTV * m + b
    //
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
            return (m * trove_ltv) + b;
        }

        wadray::rdiv_ww(trove_value - trove_debt, trove_debt)
    }

    // Helper function to calculate percentage of collateral freed.
    // If LTV > 100%, pro-rate based on amount paid down divided by total debt.
    // If LTV <= 100%, calculate based on the sum of amount paid down and liquidation penalty divided
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

    // Divide the purged assets into two groups - one that's kept in the Absorber and
    // another one that's sent to the caller as compensation. `freed_assets_amts` values
    // are in decimals of each token (hence using `u128`).
    // Returns a tuple of an ordered array of freed collateral asset amounts due to absorber 
    // and an ordered array of freed collateral asset amounts due to caller as compensation
    fn split_purged_assets(mut freed_assets_amts: Span<u128>) -> (Span<u128>, Span<u128>) {
        let mut absorbed_assets: Array<u128> = Default::default();
        let mut compensations: Array<u128> = Default::default();

        loop {
            match freed_assets_amts.pop_front() {
                Option::Some(amount) => {
                    // Rounding is intended to benefit the protocol
                    let one_percent: u128 = *amount / 100;
                    let compensation: u128 = one_percent * COMPENSATION_PCT;
                    compensations.append(compensation);
                    absorbed_assets.append(*amount - compensation);
                },
                Option::None(_) => {
                    break (absorbed_assets.span(), compensations.span());
                }
            };
        }
    }
}
