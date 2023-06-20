#[cfg(test)]
mod TestPurger {
    use array::{ArrayTrait, SpanTrait};
    use integer::BoundedU128;
    use option::OptionTrait;
    use starknet::ContractAddress;
    use starknet::testing::set_contract_address;
    use traits::Into;
    use zeroable::Zeroable;

    use aura::core::purger::Purger;
    use aura::core::roles::PurgerRoles;

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IAbsorber::{IAbsorberDispatcher, IAbsorberDispatcherTrait};
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IPurger::{IPurgerDispatcher, IPurgerDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RayZeroable, RAY_ONE, RAY_PERCENT, Wad, WadZeroable, WAD_ONE};

    use aura::tests::common;
    use aura::tests::purger::utils::PurgerUtils;
    use aura::tests::shrine::utils::ShrineUtils;

    use debug::PrintTrait;

    // 
    // Constants
    // 

    const HIGH_THRESHOLD: u128 = 950000000000000000000000000; // 95% (Ray)

    //
    // Tests - Setup
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_purger_setup() {
        let (shrine, abbot, absorber, purger, yangs, gates) = PurgerUtils::purger_deploy();
        let purger_ac = IAccessControlDispatcher { contract_address: purger.contract_address };
        assert(
            purger_ac.get_roles(PurgerUtils::admin()) == PurgerRoles::default_admin_role(),
            'wrong role for admin'
        );
    }

    //
    // Tests - Liquidate
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_liquidate_pass() {
        let searcher_start_yin: Wad = PurgerUtils::SEARCHER_YIN.into();
        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            searcher_start_yin
        );
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        let (threshold, _, value, debt) = shrine.get_trove_info(target_trove);
        let target_ltv: Ray = (threshold.val + 1).into();
        PurgerUtils::adjust_prices_for_trove_ltv(shrine, yangs, value, debt, target_ltv);

        // Sanity check
        PurgerUtils::assert_trove_is_liquidatable(shrine, purger, target_trove);

        let (_, _, before_value, before_debt) = shrine.get_trove_info(target_trove);

        let penalty: Ray = purger.get_liquidation_penalty(target_trove);
        let max_close_amt: Wad = purger.get_max_liquidation_amount(target_trove);
        let searcher: ContractAddress = PurgerUtils::searcher();

        let before_searcher_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, common::wrap_address_as_span(searcher)
        );

        set_contract_address(searcher);
        purger.liquidate(target_trove, BoundedU128::max().into(), searcher);

        // Check that LTV is close to safety margin
        let (_, after_ltv, _, after_debt) = shrine.get_trove_info(target_trove);
        assert(after_debt == before_debt - max_close_amt, 'wrong debt after liquidation');

        let expected_ltv: Ray = Purger::THRESHOLD_SAFETY_MARGIN.into() * threshold;
        let error_margin: Ray = (RAY_PERCENT / 10).into();
        common::assert_equalish(
            after_ltv, expected_ltv, error_margin, 'LTV not within safety margin'
        );

        // Check searcher yin balance
        assert(
            shrine.get_yin(searcher) == searcher_start_yin - max_close_amt,
            'wrong searcher yin balance'
        );

        // Check that searcher has received collateral
        let expected_freed_pct: Ray = PurgerUtils::get_expected_freed_pct(
            before_value, max_close_amt, penalty
        );
        let target_trove_yang_asset_amts: Span<u128> = PurgerUtils::target_trove_yang_asset_amts();
        let expected_freed_amts: Span<u128> = common::transform_span_by_pct(
            target_trove_yang_asset_amts, expected_freed_pct
        );
        let after_searcher_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, common::wrap_address_as_span(searcher)
        );

        PurgerUtils::assert_received_assets(
            before_searcher_asset_bals,
            after_searcher_asset_bals,
            expected_freed_amts,
            10_u128, // error margin
        );
    }

    // This test parametrizes over thresholds (by setting all yangs thresholds to the given value)
    // and the LTV at liquidation, and checks for the following
    // 1. LTV has decreased
    // 2. trove's debt is reduced by the close amount
    // 3. If it is not a full liquidation, then the post-liquidation LTV is at the target safety margin
    #[test]
    #[available_gas(20000000000)]
    fn test_liquidate_parametrized() {
        let mut thresholds: Span<Ray> = PurgerUtils::interesting_thresholds_for_liquidation();

        let num_thresholds: usize = thresholds.len();
        let mut safe_ltv_count: usize = 0;

        loop {
            match thresholds.pop_front() {
                Option::Some(threshold) => {
                    let mut target_ltvs: Array<Ray> = Default::default();
                    target_ltvs.append((*threshold.val + 1).into()); // just above threshold
                    target_ltvs.append(*threshold + RAY_PERCENT.into()); // 1% above threshold
                    // halfway between threshold and 100%
                    target_ltvs.append(*threshold + ((RAY_ONE.into() - *threshold).val / 2).into());
                    target_ltvs.append((RAY_ONE - RAY_PERCENT).into()); // 99%
                    target_ltvs.append((RAY_ONE + RAY_PERCENT).into()); // 101%
                    let mut target_ltvs: Span<Ray> = target_ltvs.span();

                    let expected_safe_ltv: Ray = Purger::THRESHOLD_SAFETY_MARGIN.into() * *threshold;

                    // Assert that we hit the branch for safety margin check at least once per threshold
                    let mut safety_margin_achieved: bool = false;
    
                    // Inner loop iterating over LTVs at liquidation
                    loop {
                        'inner loop'.print();
                        match target_ltvs.pop_front() {
                            Option::Some(target_ltv) => {
                                let searcher_start_yin: Wad = PurgerUtils::SEARCHER_YIN.into();
                                let (shrine, abbot, absorber, purger, yangs, gates) =
                                    PurgerUtils::purger_deploy_with_searcher(
                                    searcher_start_yin
                                );

                                // Set thresholds to provided value
                                PurgerUtils::set_thresholds(shrine, yangs, *threshold);

                                let trove_debt: Wad = PurgerUtils::TARGET_TROVE_YIN.into();
                                let target_trove: u64 = PurgerUtils::funded_healthy_trove(
                                    abbot, yangs, gates, trove_debt
                                );

                                let (_, before_ltv, value, before_debt) = shrine.get_trove_info(target_trove);
                                PurgerUtils::adjust_prices_for_trove_ltv(shrine, yangs, value, before_debt, *target_ltv);

                                let penalty: Ray = purger.get_liquidation_penalty(target_trove);
                                let max_close_amt: Wad = purger.get_max_liquidation_amount(target_trove);

                                let searcher: ContractAddress = PurgerUtils::searcher();
                                set_contract_address(searcher);
                                purger.liquidate(target_trove, BoundedU128::max().into(), searcher);        

                                // Check that LTV is close to safety margin
                                let (_, after_ltv, _, after_debt) = shrine.get_trove_info(target_trove);
                                assert(after_debt == before_debt - max_close_amt, 'wrong debt after liquidation');
                                assert(after_ltv < before_ltv, 'LTV should decrease');

                                let is_fully_liquidated: bool = trove_debt == max_close_amt;
                                if !is_fully_liquidated {
                                    let error_margin: Ray = (RAY_PERCENT / 10).into();
                                    common::assert_equalish(
                                        after_ltv, expected_safe_ltv, error_margin, 'LTV not within safety margin'
                                    );

                                    if !safety_margin_achieved {
                                        safe_ltv_count += 1;
                                        safety_margin_achieved = true;
                                    }
                                }
                            },
                            Option::None(_) => {
                                break;
                            },
                        };
                    };
                },
                Option::None(_) => {
                    break;
                },
            };
        };

        // We should hit the branch to check the post-liquidation LTV is at the expected safety margin
        // at least once per threshold, based on the target LTV that is just above the threshold.
        // This assertion provides this assurance.
        assert(safe_ltv_count == num_thresholds, 'at least one per threshold');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not liquidatable', 'ENTRYPOINT_FAILED'))]
    fn test_liquidate_trove_healthy_fail() {
        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let healthy_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        PurgerUtils::assert_trove_is_healthy(shrine, purger, healthy_trove);

        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);
        purger.liquidate(healthy_trove, BoundedU128::max().into(), searcher);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not liquidatable', 'ENTRYPOINT_FAILED'))]
    fn test_liquidate_trove_healthy_high_threshold_fail() {
        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let healthy_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        PurgerUtils::set_thresholds(shrine, yangs, HIGH_THRESHOLD.into());
        let max_forge_amt: Wad = shrine.get_max_forge(healthy_trove);

        let healthy_trove_owner: ContractAddress = PurgerUtils::target_trove_owner();
        set_contract_address(healthy_trove_owner);
        abbot.forge(healthy_trove, max_forge_amt, 0_u128.into());

        let (threshold, ltv, _, _) = shrine.get_trove_info(healthy_trove);
        // Sanity check
        assert(ltv > Purger::ABSORPTION_THRESHOLD.into(), 'too low');

        PurgerUtils::assert_trove_is_healthy(shrine, purger, healthy_trove);

        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);
        purger.liquidate(healthy_trove, BoundedU128::max().into(), searcher);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED'))]
    fn test_liquidate_insufficient_yin_fail() {
        let target_trove_yin: Wad = PurgerUtils::TARGET_TROVE_YIN.into();
        let searcher_yin: Wad = (target_trove_yin.val / 10).into();

        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            searcher_yin
        );
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, target_trove_yin
        );

        let (threshold, _, value, debt) = shrine.get_trove_info(target_trove);

        let target_ltv: Ray = (Purger::ABSORPTION_THRESHOLD + 1).into();
        PurgerUtils::adjust_prices_for_trove_ltv(shrine, yangs, value, debt, target_ltv);

        PurgerUtils::assert_trove_is_liquidatable(shrine, purger, target_trove);

        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);

        purger.liquidate(target_trove, BoundedU128::max().into(), searcher);
    }

    //
    // Tests - Absorb
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_full_absorb_pass() {
        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        let (threshold, _, start_value, before_debt) = shrine.get_trove_info(target_trove);

        // Fund the absorber with twice the target trove's debt
        let absorber_start_yin: Wad = (before_debt.val * 2).into();
        PurgerUtils::funded_absorber(shrine, abbot, absorber, yangs, gates, absorber_start_yin);

        // sanity check
        assert(shrine.get_yin(absorber.contract_address) > before_debt, 'not full absorption');

        // Make the target trove absorbable
        let target_ltv: Ray = (Purger::ABSORPTION_THRESHOLD + 1).into();
        PurgerUtils::adjust_prices_for_trove_ltv(
            shrine, yangs, start_value, before_debt, target_ltv
        );

        PurgerUtils::assert_trove_is_absorbable(shrine, purger, target_trove);

        let penalty: Ray = purger.get_absorption_penalty(target_trove);
        let max_close_amt: Wad = purger.get_max_absorption_amount(target_trove);
        let caller: ContractAddress = PurgerUtils::random_user();

        let before_caller_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, common::wrap_address_as_span(caller)
        );
        let before_absorber_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, common::wrap_address_as_span(absorber.contract_address)
        );
        let expected_compensation_value: Wad = purger.get_compensation(target_trove);

        let (_, _, before_value, _) = shrine.get_trove_info(target_trove);

        set_contract_address(caller);
        purger.absorb(target_trove);

        // Check absorption occured
        assert(absorber.get_absorptions_count() == 1, 'wrong absorptions count');

        // Check trove debt and LTV
        let (_, after_ltv, _, after_debt) = shrine.get_trove_info(target_trove);
        assert(after_debt == before_debt - max_close_amt, 'wrong debt after liquidation');

        let is_fully_absorbed: bool = after_debt.is_zero();
        if !is_fully_absorbed {
            let expected_ltv: Ray = Purger::THRESHOLD_SAFETY_MARGIN.into() * threshold;
            let error_margin: Ray = (RAY_PERCENT / 10).into();
            common::assert_equalish(
                after_ltv, expected_ltv, error_margin, 'LTV not within safety margin'
            );
        }

        // Check that caller has received compensation
        let expected_compensation_pct: Ray = wadray::rdiv_ww(
            expected_compensation_value, before_value
        );
        let target_trove_yang_asset_amts: Span<u128> = PurgerUtils::target_trove_yang_asset_amts();
        let expected_compensation_amts: Span<u128> = common::transform_span_by_pct(
            target_trove_yang_asset_amts, expected_compensation_pct
        );
        let after_caller_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, common::wrap_address_as_span(caller)
        );

        PurgerUtils::assert_received_assets(
            before_caller_asset_bals,
            after_caller_asset_bals,
            expected_compensation_amts,
            10_u128, // error margin
        );

        // Check absorber yin balance
        assert(
            shrine.get_yin(absorber.contract_address) == absorber_start_yin - max_close_amt,
            'wrong absorber yin balance'
        );

        // Check that absorber has received collateral
        let expected_freed_pct: Ray = PurgerUtils::get_expected_freed_pct(
            before_value, max_close_amt, penalty
        );
        let expected_freed_amts: Span<u128> = common::transform_span_by_pct(
            target_trove_yang_asset_amts, expected_freed_pct
        );
        let after_absorber_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, common::wrap_address_as_span(absorber.contract_address)
        );

        PurgerUtils::assert_received_assets(
            before_absorber_asset_bals,
            after_absorber_asset_bals,
            expected_freed_amts,
            10_u128, // error margin
        );
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_partial_absorb_with_redistribution_pass() {
        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        let (threshold, _, start_value, before_debt) = shrine.get_trove_info(target_trove);

        // Fund the absorber with a third of the target trove's debt
        let absorber_start_yin: Wad = (before_debt.val / 3).into();
        PurgerUtils::funded_absorber(shrine, abbot, absorber, yangs, gates, absorber_start_yin);

        // sanity check
        assert(shrine.get_yin(absorber.contract_address) < before_debt, 'not partial absorption');

        // Make the target trove absorbable
        let target_ltv: Ray = (Purger::ABSORPTION_THRESHOLD + 1).into();
        PurgerUtils::adjust_prices_for_trove_ltv(
            shrine, yangs, start_value, before_debt, target_ltv
        );

        PurgerUtils::assert_trove_is_absorbable(shrine, purger, target_trove);

        let penalty: Ray = purger.get_absorption_penalty(target_trove);
        let max_close_amt: Wad = purger.get_max_liquidation_amount(target_trove);
        let close_amt: Wad = absorber_start_yin;
        let caller: ContractAddress = PurgerUtils::random_user();

        let before_caller_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, common::wrap_address_as_span(caller)
        );
        let before_absorber_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, common::wrap_address_as_span(absorber.contract_address)
        );
        let expected_compensation_value: Wad = purger.get_compensation(target_trove);

        let (_, _, before_value, _) = shrine.get_trove_info(target_trove);

        set_contract_address(caller);
        purger.absorb(target_trove);

        // Check absorption occured
        assert(absorber.get_absorptions_count() == 1, 'wrong absorptions count');

        // Check trove debt and LTV
        let (_, after_ltv, _, after_debt) = shrine.get_trove_info(target_trove);
        assert(after_debt == before_debt - max_close_amt, 'wrong debt after liquidation');

        let is_fully_absorbed: bool = after_debt.is_zero();
        if !is_fully_absorbed {
            let expected_ltv: Ray = Purger::THRESHOLD_SAFETY_MARGIN.into() * threshold;
            let error_margin: Ray = (RAY_PERCENT / 10).into();
            common::assert_equalish(
                after_ltv, expected_ltv, error_margin, 'LTV not within safety margin'
            );
        }

        // Check that caller has received compensation
        let expected_compensation_pct: Ray = wadray::rdiv_ww(
            expected_compensation_value, before_value
        );
        let target_trove_yang_asset_amts: Span<u128> = PurgerUtils::target_trove_yang_asset_amts();
        let expected_compensation_amts: Span<u128> = common::transform_span_by_pct(
            target_trove_yang_asset_amts, expected_compensation_pct
        );
        let after_caller_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, common::wrap_address_as_span(caller)
        );

        PurgerUtils::assert_received_assets(
            before_caller_asset_bals,
            after_caller_asset_bals,
            expected_compensation_amts,
            10_u128, // error margin
        );

        // Check absorber yin balance is wiped out
        assert(
            shrine.get_yin(absorber.contract_address) == WadZeroable::zero(),
            'wrong absorber yin balance'
        );

        // Check that absorber has received proportionate share of collateral
        let expected_freed_pct: Ray = PurgerUtils::get_expected_freed_pct(
            before_value, close_amt, penalty
        );
        let expected_freed_amts: Span<u128> = common::transform_span_by_pct(
            target_trove_yang_asset_amts, expected_freed_pct
        );
        let after_absorber_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, common::wrap_address_as_span(absorber.contract_address)
        );

        PurgerUtils::assert_received_assets(
            before_absorber_asset_bals,
            after_absorber_asset_bals,
            expected_freed_amts,
            10_u128, // error margin
        );

        // Check redistribution occured
        assert(shrine.get_redistributions_count() == 1, 'wrong redistributions count');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_absorb_full_redistribution_pass() {
        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        let (threshold, ltv, value, debt) = shrine.get_trove_info(target_trove);
        let target_ltv: Ray = (Purger::ABSORPTION_THRESHOLD + 1).into();
        PurgerUtils::adjust_prices_for_trove_ltv(shrine, yangs, value, debt, target_ltv);

        set_contract_address(PurgerUtils::random_user());
        purger.absorb(target_trove);

        let (_, ltv, value, debt) = shrine.get_trove_info(target_trove);
        assert(shrine.is_healthy(target_trove), 'should be healthy');
        assert(ltv == RayZeroable::zero(), 'LTV should be 0');
        assert(value == WadZeroable::zero(), 'value should be 0');
        assert(debt == WadZeroable::zero(), 'debt should be 0');

        // Check no absorption occured
        assert(absorber.get_absorptions_count() == 0, 'wrong absorptions count');

        // Check redistribution occured
        assert(shrine.get_redistributions_count() == 1, 'wrong redistributions count');
    }

    // This test parametrizes over thresholds (by setting all yangs thresholds to the given value)
    // and the LTV at liquidation, and checks for the following
    // 1. LTV has decreased to the target safety margin
    // 2. trove's debt is reduced by the close amount, which is less than the trove's debt
    #[test]
    #[available_gas(20000000000)]
    fn test_absorb_less_than_trove_debt_parametrized() {
        let mut thresholds: Span<Ray> = PurgerUtils::interesting_thresholds_for_absorption_below_trove_debt();
        let mut target_ltvs_by_threshold: Span<Span<Ray>> = PurgerUtils::ltvs_for_interesting_thresholds_for_absorption_below_trove_debt();

        loop {
            match thresholds.pop_front() {
                Option::Some(threshold) => {
                    let mut target_ltvs: Span<Ray> = *target_ltvs_by_threshold.pop_front().unwrap();
                    let expected_safe_ltv: Ray = Purger::THRESHOLD_SAFETY_MARGIN.into() * *threshold;
    
                    // Inner loop iterating over LTVs at liquidation
                    loop {
                        match target_ltvs.pop_front() {
                            Option::Some(target_ltv) => {
                                let searcher_start_yin: Wad = PurgerUtils::SEARCHER_YIN.into();
                                let (shrine, abbot, absorber, purger, yangs, gates) =
                                    PurgerUtils::purger_deploy_with_searcher(
                                    searcher_start_yin
                                );

                                // Set thresholds to provided value
                                PurgerUtils::set_thresholds(shrine, yangs, *threshold);

                                let trove_debt: Wad = PurgerUtils::TARGET_TROVE_YIN.into();
                                let target_trove: u64 = PurgerUtils::funded_healthy_trove(
                                    abbot, yangs, gates, trove_debt
                                );

                                let (_, _, start_value, before_debt) = shrine.get_trove_info(target_trove);

                                // Fund the absorber with twice the target trove's debt
                                let absorber_start_yin: Wad = (before_debt.val * 2).into();
                                PurgerUtils::funded_absorber(shrine, abbot, absorber, yangs, gates, absorber_start_yin);

                                // sanity check
                                assert(shrine.get_yin(absorber.contract_address) > before_debt, 'not full absorption');

                                // Make the target trove absorbable
                                PurgerUtils::adjust_prices_for_trove_ltv(
                                    shrine, yangs, start_value, before_debt, *target_ltv
                                );

                                PurgerUtils::assert_trove_is_absorbable(shrine, purger, target_trove);
      
                                let max_close_amt: Wad = purger.get_max_absorption_amount(target_trove);
                                max_close_amt.print();
                                before_debt.print();
                                assert(max_close_amt < before_debt, 'close amount == debt');

                                set_contract_address(PurgerUtils::random_user());
                                purger.absorb(target_trove);

                                // Check that LTV is close to safety margin
                                let (_, after_ltv, _, after_debt) = shrine.get_trove_info(target_trove);
                                after_debt.print();
                                (before_debt - max_close_amt).print();
                                assert(after_debt == before_debt - max_close_amt, 'wrong debt after liquidation');

                                let error_margin: Ray = (RAY_PERCENT / 10).into();
                                common::assert_equalish(
                                    after_ltv, expected_safe_ltv, error_margin, 'LTV not within safety margin'
                                );

                            },
                            Option::None(_) => {
                                break;
                            },
                        };
                    };
                },
                Option::None(_) => {
                    break;
                },
            };
        };
    }

    // This test parametrizes over thresholds (by setting all yangs thresholds to the given value)
    // and the LTV at liquidation, and checks that the trove's debt is absorbed in full
    #[test]
    #[available_gas(20000000000)]
    fn test_absorb_trove_debt_parametrized() {
        let mut thresholds: Span<Ray> = PurgerUtils::interesting_thresholds_for_absorption_trove_debt();

        loop {
            match thresholds.pop_front() {
                Option::Some(threshold) => {
                    let mut target_ltvs: Array<Ray> = Default::default();

                    let above_max_possible_penalty_ltv: Ray = PurgerUtils::ABOVE_MAX_POSSIBLE_PENALTY_LTV.into();
                    if *threshold < above_max_possible_penalty_ltv {
                        target_ltvs.append(above_max_possible_penalty_ltv);
                    } else {
                        target_ltvs.append((*threshold.val + 1).into()); // just above threshold
                        target_ltvs.append(*threshold + RAY_PERCENT.into()); // 1% above threshold
                    }
                    target_ltvs.append((RAY_ONE - RAY_PERCENT).into()); // 99%
                    target_ltvs.append((RAY_ONE + RAY_PERCENT).into()); // 101%
                    let mut target_ltvs: Span<Ray> = target_ltvs.span();
    
                    // Inner loop iterating over LTVs at liquidation
                    loop {
                        match target_ltvs.pop_front() {
                            Option::Some(target_ltv) => {
                                let searcher_start_yin: Wad = PurgerUtils::SEARCHER_YIN.into();
                                let (shrine, abbot, absorber, purger, yangs, gates) =
                                    PurgerUtils::purger_deploy_with_searcher(
                                    searcher_start_yin
                                );

                                // Set thresholds to provided value
                                PurgerUtils::set_thresholds(shrine, yangs, *threshold);

                                let trove_debt: Wad = PurgerUtils::TARGET_TROVE_YIN.into();
                                let target_trove: u64 = PurgerUtils::funded_healthy_trove(
                                    abbot, yangs, gates, trove_debt
                                );

                                let (_, _, start_value, before_debt) = shrine.get_trove_info(target_trove);

                                // Fund the absorber with twice the target trove's debt
                                let absorber_start_yin: Wad = (before_debt.val * 2).into();
                                PurgerUtils::funded_absorber(shrine, abbot, absorber, yangs, gates, absorber_start_yin);

                                // sanity check
                                assert(shrine.get_yin(absorber.contract_address) > before_debt, 'not full absorption');

                                // Make the target trove absorbable
                                PurgerUtils::adjust_prices_for_trove_ltv(
                                    shrine, yangs, start_value, before_debt, *target_ltv
                                );

                                let (_, after_ltv, _, _) = shrine.get_trove_info(target_trove);

                                after_ltv.print();
                                PurgerUtils::assert_trove_is_absorbable(shrine, purger, target_trove);
      
                                let max_close_amt: Wad = purger.get_max_absorption_amount(target_trove);
                                max_close_amt.print();
                                before_debt.print();
                                assert(max_close_amt == before_debt, 'close amount != debt');

                                set_contract_address(PurgerUtils::random_user());
                                purger.absorb(target_trove);

                                // Check that LTV is close to safety margin
                                let (_, after_ltv, after_value, after_debt) = shrine.get_trove_info(target_trove);
                                after_debt.print();
                                (before_debt - max_close_amt).print();
                                assert(after_ltv == RayZeroable::zero(), 'wrong debt after liquidation');
                                assert(after_value == WadZeroable::zero(), 'wrong debt after liquidation');
                                assert(after_debt == WadZeroable::zero(), 'wrong debt after liquidation');

                            },
                            Option::None(_) => {
                                break;
                            },
                        };
                    };
                },
                Option::None(_) => {
                    break;
                },
            };
        };
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not absorbable', 'ENTRYPOINT_FAILED'))]
    fn test_absorb_trove_healthy_fail() {
        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let healthy_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        PurgerUtils::assert_trove_is_healthy(shrine, purger, healthy_trove);

        set_contract_address(PurgerUtils::random_user());
        purger.absorb(healthy_trove);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not absorbable', 'ENTRYPOINT_FAILED'))]
    fn test_absorb_below_absorbable_ltv_fail() {
        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        assert(shrine.is_healthy(target_trove), 'should be healthy');

        let (threshold, ltv, value, debt) = shrine.get_trove_info(target_trove);
        // Calculate the target trove value for the LTV to be above the threshold by 1%

        let target_ltv: Ray = threshold + RAY_PERCENT.into();
        PurgerUtils::adjust_prices_for_trove_ltv(shrine, yangs, value, debt, target_ltv);

        let (_, new_ltv, value, _) = shrine.get_trove_info(target_trove);

        PurgerUtils::assert_trove_is_liquidatable(shrine, purger, target_trove);
        PurgerUtils::assert_trove_is_not_absorbable(purger, target_trove);

        set_contract_address(PurgerUtils::random_user());
        purger.absorb(target_trove);
    }
}
