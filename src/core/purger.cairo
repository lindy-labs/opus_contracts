use array::ArrayTrait;
use starknet::ContractAddress;

use aura::utils::wadray::Wad;

#[abi]
trait IAbsorber {
    fn compensate(
        recipient: ContractAddress, assets: Array<ContractAddress>, asset_amts: Array<u128>
    );
    fn update(assets: Array<ContractAddress>, asset_amts: Array<u128>);
}

#[abi]
trait IEmpiric {
    fn update_prices();
}

#[abi]
trait ISentinel {
    fn get_yang_addresses() -> Array<ContractAddress>;
    fn exit(yang: ContractAddress, user: ContractAddress, trove_id: u64, yang_amt: Wad) -> u128;
}

#[contract]
mod Purger {
    use array::ArrayTrait;
    use array::SpanTrait;
    use starknet::ContractAddress;
    use starknet::get_caller_address;

    use aura::interfaces::IShrine::IShrineDispatcher;
    use aura::interfaces::IShrine::IShrineDispatcherTrait;
    use aura::utils::wadray::Ray;
    use aura::utils::wadray::RAY_ONE;
    use aura::utils::wadray::rdiv_ww;
    use aura::utils::wadray::rmul_wr;
    use aura::utils::wadray::Wad;

    use super::IAbsorberDispatcher;
    use super::IAbsorberDispatcherTrait;
    use super::IEmpiricDispatcher;
    use super::IEmpiricDispatcherTrait;
    use super::ISentinelDispatcher;
    use super::ISentinelDispatcherTrait;

    // Close factor function parameters
    // (ray): 2.7 * RAY_ONE
    const CF1: u128 = 2700000000000000000000000000;
    // (ray): 0.22 * RAY_ONE
    const CF2: u128 = 220000000000000000000000000;

    // Maximum liquidation penalty (ray): 0.125 * RAY_ONE
    const MAX_PENALTY: u128 = 125000000000000000000000000;

    // Minimum liquidation penalty (ray): 0.03 * RAY_ONE
    const MIN_PENALTY: u128 = 30000000000000000000000000;

    // TV at the maximum liquidation penalty (ray): 0.8888 * RAY_ONE
    const MAX_PENALTY_LTV: u128 = 888800000000000000000000000;

    // percentage of each asset being purged in `absorb`
    // that's transferred to the caller as compensation
    const COMPENSATION_PCT: u128 = 3;

    struct Storage {
        shrine: ContractAddress,
        sentinel: ContractAddress,
        absorber: ContractAddress,
        oracle: ContractAddress,
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
        yangs: Array<ContractAddress>,
        freed_assets_amts: Array<u128>,
    ) {}

    //
    // View
    //

    // Returns the liquidation penalty based on the LTV (ray)
    // Returns 0 if trove is healthy
    #[view]
    fn get_penalty(trove_id: u64) -> Ray {
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine::read() };
        let (threshold, ltv, value, debt) = shrine.get_trove_info(trove_id);

        if ltv <= threshold {
            return Ray { val: 0 };
        }

        get_penalty_internal(threshold, ltv, value, debt)
    }

    // Returns the maximum amount of debt that can be closed for a Trove based on the close factor
    // Returns 0 if trove is healthy
    #[view]
    fn get_max_close_amount(trove_id: u64) -> Wad {
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine::read() };
        let (threshold, ltv, _, debt) = shrine.get_trove_info(trove_id);

        if ltv <= threshold {
            return Wad { val: 0 };
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
        shrine::write(shrine);
        sentinel::write(sentinel);
        absorber::write(absorber);
        oracle::write(oracle);
    }

    //
    // External
    //

    // Performs searcher liquidations that requires the caller address to supply the amount of debt to repay
    // and the recipient address to send the freed collateral to.
    // Reverts if the trove is not liquidatable (i.e. LTV > threshold)
    // Reverts if the repayment amount exceeds the maximum amount as determined by the close factor.
    // Reverts if the trove's LTV is worse off than before the purge
    // - This should not be possible, but is added in for safety.
    // Returns a tuple of an ordered array of yang addresses and an ordered array of freed collateral amounts
    #[external]
    fn liquidate(
        trove_id: u64, purge_amt: Wad, recipient: ContractAddress
    ) -> (Array<ContractAddress>, Array<u128>) {
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine::read() };
        let (trove_threshold, trove_ltv, trove_value, trove_debt) = shrine.get_trove_info(trove_id);

        assert_liquidatable(trove_threshold, trove_ltv);

        // Cap `purge_amt` to the `max_close_amt`
        let max_close_amt: Wad = get_max_close_amount_internal(trove_ltv, trove_debt);

        // TODO: min of max_close_amt and purge_amt
        let safe_purge_amt: Wad = max_close_amt;

        let percentage_freed: Ray = get_percentage_freed(
            trove_threshold, trove_ltv, trove_value, trove_debt, safe_purge_amt
        );

        let funder: ContractAddress = get_caller_address();
        let (yangs, freed_assets_amts) = purge(
            shrine.contract_address,
            trove_id,
            trove_ltv,
            safe_purge_amt,
            percentage_freed,
            funder,
            recipient
        );

        let (_, updated_trove_ltv, _, _) = shrine.get_trove_info(trove_id);
        assert(updated_trove_ltv <= trove_ltv, 'PU: LTV increased');

        (yangs, freed_assets_amts);
    }

    // Performs stability pool liquidations to pay down a trove's debt in full and transfer the freed collateral
    // to the stability pool. If the stability pool does not have sufficient yin, the trove's debt and collateral
    // will be proportionally redistributed among all troves containing the trove's collateral.
    // - The amount of debt distributed to each collateral = (value of collateral / trove value) * trove debt
    // Reverts if the trove's LTV is not above the max penalty LTV
    // - It follows that the trove must also be liquidatable because threshold < max penalty LTV.
    // Returns a tuple of an ordered array of yang addresses and an ordered array of amount of asset freed
    #[external]
    fn absorb(trove_id: u64) -> (Array<ContractAddress>, Array<u128>) {
        let shrine: ContractAddress = shrine::read();
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine };
        let (trove_threshold, trove_ltv, trove_value, trove_debt) = shrine.get_trove_info(trove_id);

        assert_liquidatable(trove_threshold, trove_ltv);
        assert(trove_ltv.val > MAX_PENALTY_LTV, 'PU: Not absorbable');

        let caller: ContractAddress = get_caller_address();
        let absorber: IAbsorberDispatcher = IAbsorberDispatcher {
            contract_address: absorber::read()
        };

        let absorber_yin_bal: Wad = shrine.get_yin(absorber.contract_address);

        if trove_debt <= absorber_yin_bal {
            let (yangs, freed_assets_amts) = purge(
                shrine.contract_address,
                trove_id,
                trove_ltv,
                trove_debt,
                Ray { val: RAY_ONE },
                absorber.contract_address,
                absorber.contract_address
            );

            let (absorbed_assets, compensations) = split_purged_assets(freed_assets_amts);

            absorber.compensate(caller, yangs, compensations);
            absorber.update(yangs, absorbed_assets);

            (yangs, freed_assets_amts);
        } else {
            let percentage_freed: Ray = get_percentage_freed(
                trove_threshold, trove_ltv, trove_value, trove_debt, absorber_yin_bal
            );
            let (yangs, freed_assets_amts) = purge(
                shrine.contract_address,
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
            let oracle: ContractAddress = oracle::read();
            IEmpiricDispatcher { contract_address: oracle }.update_prices();

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
    fn assert_liquidatable(threshold: Ray, ltv: Ray) {
        assert(ltv > threshold, 'PU: Not liquidatable');
    }

    // Internal function to handle the paying down of a trove's debt in return for the
    // corresponding freed collateral to be sent to the recipient address
    // Returns a tuple of an ordered array of yang addresses and an ordered array of freed collateral asset amounts
    fn purge(
        shrine: ContractAddress,
        trove_id: u64,
        trove_ltv: Ray,
        purge_amt: Wad,
        percentage_freed: Ray,
        funder: ContractAddress,
        recipient: ContractAddress,
    ) -> (Array<ContractAddress>, Array<u128>) {
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine::read() };

        // Melt from the funder address directly
        shrine.melt(funder, trove_id, purge_amt);

        let sentinel: ISentinelDispatcher = ISentinelDispatcher {
            contract_address: sentinel::read()
        };
        let yangs: Array<ContractAddress> = sentinel.get_yang_addresses();
        let mut freed_assets_amts: Array<u128> = ArrayTrait::new();

        let mut idx: u32 = 0;
        let yangs_span: Span<ContractAddress> = yangs.span();
        let yangs_count: u32 = yangs_span.len();

        // Loop through yang addresses and transfer to recipient
        loop {
            if idx == yangs_count {
                break ();
            }

            let yang: ContractAddress = *yangs[idx];
            let deposited_yang_amt: Wad = shrine.get_deposit(yang, trove_id);

            // TODO: `continue` if no yang deposited
            let freed_yang: Wad = rmul_wr(deposited_yang_amt, percentage_freed);

            // TODO: Add reentrancy guard
            let freed_asset_amt: u128 = sentinel.exit(yang, recipient, trove_id, freed_yang);
            freed_assets_amts.append(freed_asset_amt);
            shrine.seize(yang, trove_id, freed_yang);

            idx += 1;
        };

        Purged(trove_id, purge_amt, funder, recipient, percentage_freed, yangs, freed_assets_amts);

        // The denomination for each value in `freed_assets_amts` will be based on the decimals
        // for the respective asset.
        (yangs, freed_assets_amts)
    }

    // Returns the close factor based on the LTV (ray)
    // closeFactor = 2.7 * (LTV ** 2) - 2 * LTV + 0.22
    //               [CF1]                       [CF2]
    //               [  factor_one  ] - [ factor_two ]
    fn get_close_factor(ltv: Ray) -> Ray {
        let factor_one: Ray = Ray { val: CF1 } * (ltv * ltv);
        let factor_two: Ray = Ray { val: 2 * ltv.val + CF2 };
        factor_one - factor_two
    }

    fn get_max_close_amount_internal(trove_ltv: Ray, debt: Wad) -> Wad {
        let close_factor: Ray = get_close_factor(trove_ltv);
        let close_amt: Wad = rmul_wr(debt, close_factor);
        if debt <= close_amt {
            debt
        } else {
            close_amt
        }
    }

    // Assumption: Trove's LTV has exceeded its threshold
    //
    //                                              maxLiqPenalty - minLiqPenalty
    // - If LTV <= MAX_PENALTY_LTV, penalty = LTV * ----------------------------- + b
    //                                              maxPenaltyLTV - liqThreshold
    //
    //                                      = LTV * m + b
    //
    //
    //                                               (trove_value - trove_debt)
    // - If MAX_PENALTY_LTV < LTV <= 100%, penalty = -------------------------
    //                                                      trove_debt
    //
    // - If 100% < LTV, penalty = 0
    // Return value is a tuple so that function can be modified as an external view for testing
    fn get_penalty_internal(
        trove_threshold: Ray, trove_ltv: Ray, trove_value: Wad, trove_debt: Wad, 
    ) -> Ray {
        if trove_ltv.val >= RAY_ONE {
            return Ray { val: 0 };
        }

        if trove_ltv.val <= MAX_PENALTY_LTV {
            let m: Ray = Ray {
                val: MAX_PENALTY - MIN_PENALTY
            } / (Ray { val: MAX_PENALTY_LTV } - trove_threshold);
            let b: Ray = Ray { val: MIN_PENALTY } - (trove_threshold * m);
            return (m * trove_ltv) + b;
        }

        return rdiv_ww(trove_value - trove_debt, trove_debt);
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
            let penalty_amt: Wad = rmul_wr(purge_amt, penalty);
            let freed_amt: Wad = penalty_amt + purge_amt;

            rdiv_ww(freed_amt, trove_value)
        } else {
            rdiv_ww(purge_amt, trove_debt)
        }
    }

    // Divide the purged assets into two groups - one that's kept in the Absorber and
    // another one that's sent to the caller as compensation. `freed_assets_amt` values
    // are in decimals of each token (hence using `u128`).
    // Returns a tuple of an ordered array of freed collateral asset amounts due to absorber 
    // and an ordered array of freed collateral asset amounts due to caller as compensation
    fn split_purged_assets(freed_assets_amts: Array<u128>) -> (Array<u128>, Array<u128>) {
        let mut absorbed_assets: Array<u128> = ArrayTrait::new();
        let mut compensations: Array<u128> = ArrayTrait::new();

        let mut idx: u32 = 0;
        let freed_assets_amts_span: Span<u128> = freed_assets_amts.span();
        let assets_count: u32 = freed_assets_amts_span.len();

        loop {
            if idx == assets_count {
                break ();
            }

            let amount: u128 = *freed_assets_amts[idx];
            // Rounding is intended to benefit the protocol
            let one_percent: u128 = amount / 100;
            let compensation: u128 = one_percent * COMPENSATION_PCT;
            compensations.append(compensation);
            absorbed_assets.append(amount - compensation);

            idx += 1;
        };

        (absorbed_assets, compensations)
    }
}