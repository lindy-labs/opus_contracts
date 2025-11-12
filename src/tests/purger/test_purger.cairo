mod test_purger {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::cmp::{max, min};
    use core::num::traits::{Bounded, Pow, Zero};
    use opus::core::absorber::absorber as absorber_contract;
    use opus::core::purger::purger as purger_contract;
    use opus::core::roles::purger_roles;
    use opus::core::shrine::shrine as shrine_contract;
    use opus::interfaces::IAbbot::IAbbotDispatcherTrait;
    use opus::interfaces::IAbsorber::IAbsorberDispatcherTrait;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::IPurger::IPurgerDispatcherTrait;
    use opus::interfaces::IShrine::IShrineDispatcherTrait;
    use opus::mock::flash_liquidator::IFlashLiquidatorDispatcherTrait;
    use opus::tests::absorber::utils::absorber_utils;
    use opus::tests::common;
    use opus::tests::flash_mint::utils::flash_mint_utils;
    use opus::tests::purger::utils::purger_utils;
    use opus::tests::purger::utils::purger_utils::PurgerTestConfig;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::{AssetBalance, Health, HealthTrait};
    use opus::utils::math::scale_u128_by_ray;
    use snforge_std::{
        EventSpyAssertionsTrait, EventSpyTrait, EventsFilterTrait, spy_events, start_cheat_block_timestamp_global,
        start_cheat_caller_address, stop_cheat_caller_address,
    };
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::{RAY_ONE, RAY_PERCENT, Ray, WAD_ONE, Wad};

    const BOOL_PARAMETRIZED: [bool; 2] = [true, false];

    //
    // Tests - Setup
    //

    #[test]
    fn test_purger_setup() {
        let mut spy = spy_events();
        let PurgerTestConfig { purger, .. } = purger_utils::purger_deploy(Option::None);

        let purger_ac = IAccessControlDispatcher { contract_address: purger.contract_address };
        assert(purger_ac.get_roles(purger_utils::ADMIN) == purger_roles::ADMIN, 'wrong role for admin');

        let expected_events = array![
            (
                purger.contract_address,
                purger_contract::Event::PenaltyScalarUpdated(
                    purger_contract::PenaltyScalarUpdated { new_scalar: RAY_ONE.into() },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    //
    // Tests - Setters
    //

    #[test]
    fn test_set_penalty_scalar_pass() {
        let PurgerTestConfig {
            shrine, abbot, seer, purger, yangs, gates, ..,
        } = purger_utils::purger_deploy(Option::None);
        let mut spy = spy_events();

        purger_utils::create_whale_trove(abbot, yangs, gates);

        let target_trove: u64 = purger_utils::funded_healthy_trove(
            abbot, yangs, gates, purger_utils::TARGET_TROVE_YIN.into(),
        );

        // Set thresholds to 91% so we can check the scalar is applied to the penalty
        let threshold: Ray = (91 * RAY_PERCENT).into();
        purger_utils::set_thresholds(shrine, yangs, threshold);

        let target_trove_health: Health = shrine.get_trove_health(target_trove);
        let target_ltv: Ray = threshold + RAY_PERCENT.into(); // 92%
        purger_utils::lower_prices_to_raise_trove_ltv(
            shrine, seer, yangs, target_trove_health.value, target_trove_health.debt, target_ltv,
        );

        // sanity check that LTV is at the target liquidation LTV
        let target_trove_health: Health = shrine.get_trove_health(target_trove);
        let error_margin: Ray = 2000000_u128.into();
        common::assert_equalish(target_trove_health.ltv, target_ltv, error_margin, 'LTV sanity check');

        let mut expected_events: Array<(ContractAddress, purger_contract::Event)> = ArrayTrait::new();

        // Set scalar to 1
        start_cheat_caller_address(purger.contract_address, purger_utils::ADMIN);
        let penalty_scalar: Ray = RAY_ONE.into();
        purger.set_penalty_scalar(penalty_scalar);

        assert(purger.get_penalty_scalar() == penalty_scalar, 'wrong penalty scalar #1');

        let (penalty, _, _) = purger.preview_absorb(target_trove).expect('Should be absorbable');
        let expected_penalty: Ray = 41000000000000000000000000_u128.into(); // 4.1%
        let error_margin: Ray = (RAY_PERCENT / 100).into(); // 0.01%
        common::assert_equalish(penalty, expected_penalty, error_margin, 'wrong scalar penalty #1');

        expected_events
            .append(
                (
                    purger.contract_address,
                    purger_contract::Event::PenaltyScalarUpdated(
                        purger_contract::PenaltyScalarUpdated { new_scalar: penalty_scalar },
                    ),
                ),
            );

        // Set scalar to 0.97
        let penalty_scalar: Ray = purger_contract::MIN_PENALTY_SCALAR.into();
        purger.set_penalty_scalar(penalty_scalar);

        assert(purger.get_penalty_scalar() == penalty_scalar, 'wrong penalty scalar #2');

        let (penalty, _, _) = purger.preview_absorb(target_trove).expect('Should be absorbable');
        let expected_penalty: Ray = 10700000000000000000000000_u128.into(); // 1.07%
        common::assert_equalish(penalty, expected_penalty, error_margin, 'wrong scalar penalty #2');

        expected_events
            .append(
                (
                    purger.contract_address,
                    purger_contract::Event::PenaltyScalarUpdated(
                        purger_contract::PenaltyScalarUpdated { new_scalar: penalty_scalar },
                    ),
                ),
            );

        // Set scalar to 1.06
        let penalty_scalar: Ray = purger_contract::MAX_PENALTY_SCALAR.into();
        purger.set_penalty_scalar(penalty_scalar);

        assert(purger.get_penalty_scalar() == penalty_scalar, 'wrong penalty scalar #3');

        let (penalty, _, _) = purger.preview_absorb(target_trove).expect('Should be absorbable');
        let expected_penalty: Ray = 54300000000000000000000000_u128.into(); // 5.43%
        common::assert_equalish(penalty, expected_penalty, error_margin, 'wrong scalar penalty #3');

        expected_events
            .append(
                (
                    purger.contract_address,
                    purger_contract::Event::PenaltyScalarUpdated(
                        purger_contract::PenaltyScalarUpdated { new_scalar: penalty_scalar },
                    ),
                ),
            );

        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_penalty_scalar_lower_bound() {
        let PurgerTestConfig {
            shrine, abbot, seer, purger, yangs, gates, ..,
        } = purger_utils::purger_deploy(Option::None);

        purger_utils::create_whale_trove(abbot, yangs, gates);

        let target_trove: u64 = purger_utils::funded_healthy_trove(
            abbot, yangs, gates, purger_utils::TARGET_TROVE_YIN.into(),
        );

        // Set thresholds to 90% so we can check the scalar is not applied to the penalty
        let threshold: Ray = (90 * RAY_PERCENT).into();
        purger_utils::set_thresholds(shrine, yangs, threshold);

        let target_trove_health: Health = shrine.get_trove_health(target_trove);
        // 91%; Note that if a penalty scalar is applied, then the trove would be absorbable
        // at this LTV because the penalty would be the maximum possible penalty. On the other
        // hand, if a penalty scalar is not applied, then the maximum possible penalty will be
        // reached from 92.09% onwards, so the trove would not be absorbable at this LTV
        let target_ltv: Ray = 910000000000000000000000000_u128.into();
        purger_utils::lower_prices_to_raise_trove_ltv(
            shrine, seer, yangs, target_trove_health.value, target_trove_health.debt, target_ltv,
        );

        let target_trove_health: Health = shrine.get_trove_health(target_trove);
        // sanity check that threshold is correct
        assert(target_trove_health.threshold == threshold, 'threshold sanity check');

        // sanity check that LTV is at the target liquidation LTV
        let error_margin: Ray = 100000000_u128.into();
        common::assert_equalish(target_trove_health.ltv, target_ltv, error_margin, 'LTV sanity check');

        assert(purger.preview_absorb(target_trove).is_none(), 'should not be absorbable #1');

        // Set scalar to 1.06 and check the trove is still not absorbable.
        start_cheat_caller_address(purger.contract_address, purger_utils::ADMIN);
        let penalty_scalar: Ray = purger_contract::MAX_PENALTY_SCALAR.into();
        purger.set_penalty_scalar(penalty_scalar);

        assert(purger.preview_absorb(target_trove).is_none(), 'should not be absorbable #2');
    }

    #[test]
    #[should_panic(expected: 'PU: Invalid scalar')]
    fn test_set_penalty_scalar_too_low_fail() {
        let PurgerTestConfig { purger, .. } = purger_utils::purger_deploy(Option::None);

        start_cheat_caller_address(purger.contract_address, purger_utils::ADMIN);
        purger.set_penalty_scalar((purger_contract::MIN_PENALTY_SCALAR - 1).into());
    }

    #[test]
    #[should_panic(expected: 'PU: Invalid scalar')]
    fn test_set_penalty_scalar_too_high_fail() {
        let PurgerTestConfig { purger, .. } = purger_utils::purger_deploy(Option::None);

        start_cheat_caller_address(purger.contract_address, purger_utils::ADMIN);
        purger.set_penalty_scalar((purger_contract::MAX_PENALTY_SCALAR + 1).into());
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_set_penalty_scalar_unauthorized_fail() {
        let PurgerTestConfig { purger, .. } = purger_utils::purger_deploy(Option::None);

        start_cheat_caller_address(purger.contract_address, common::BAD_GUY);
        purger.set_penalty_scalar(RAY_ONE.into());
    }

    //
    // Tests - Liquidate
    //

    // This test fixes the trove's debt to 1,000 in order to test the ground truth values of the
    // penalty and close amount when LTV is at threshold. The error margin is relaxed because
    // `lower_prices_to_raise_trove_ltv` may not put the trove in the exact LTV as the threshold.
    //
    // For low thresholds (arbitraily defined as 2% or less), the trove's debt is set based on the
    // value instead. See inline comments for more details.
    #[test]
    #[test_case(0, 1_u128.into(), (12 * RAY_PERCENT + RAY_PERCENT / 2).into())] // 1 wei (0% threshold); 12.5% penalty
    #[test_case(1, 13904898408200000000_u128.into(), (3 * RAY_PERCENT).into())] // 13.904... (1% threshold); 3% penalty
    #[test_case(2, 284822000000000000000_u128.into(), (3 * RAY_PERCENT).into())] // 284.822 (70% threshold); 3% penalty
    #[test_case(3, 386997000000000000000_u128.into(), (3 * RAY_PERCENT).into())] // 386.997 (80% threshold); 3% penalty
    #[test_case(4, 603509000000000000000_u128.into(), (3 * RAY_PERCENT).into())] // 603.509 (90% threshold); 3% penalty
    #[test_case(5, 908381000000000000000_u128.into(), (3 * RAY_PERCENT).into())] // 908.381 (96% threshold); 3% penalty
    #[test_case(6, 992098000000000000000_u128.into(), (3 * RAY_PERCENT).into())] // 992.098 (97% threshold); 3% penalty
    #[test_case(
        7, (WAD_ONE * 1000).into(), 10101000000000000000000000_u128.into(),
    )] // 1000 debt (99% threshold); 1.0101% penalty
    fn test_preview_liquidate_parametrized(threshold_idx: usize, expected_max_close_amt: Wad, expected_penalty: Ray) {
        let threshold: Ray = *purger_utils::interesting_thresholds_for_liquidation().at(threshold_idx);
        let default_trove_debt: Wad = (WAD_ONE * 1000).into();

        let PurgerTestConfig {
            shrine, abbot, seer, purger, yangs, gates, ..,
        } = purger_utils::purger_deploy(Option::None);

        purger_utils::create_whale_trove(abbot, yangs, gates);

        // If the threshold is below 2%, we set the trove's debt such that
        // we get the desired ltv for the trove from the get-go in order to
        // avoid overflow issues in `lower_prices_to_raise_trove_ltv`.
        //
        // This is because `lower_prices_to_raise_trove_ltv` is designed for
        // raising the trove's LTV to the given *higher* LTV,
        // not lowering it.
        //
        // NOTE: This 2% cut off is completely arbitrary and meant only for excluding
        // the two test cases in `interesting_thresholds_for_liquidation`: 0% and 1%.
        // If more low thresholds were added that were above 2% but below the
        // starting LTV of the trove, then this cutoff would need to be adjusted.
        let target_threshold_above_cutoff = threshold > (RAY_PERCENT * 2).into();
        let trove_debt = if target_threshold_above_cutoff {
            default_trove_debt
        } else {
            let target_trove_yang_amts: Span<Wad> = array![
                purger_utils::TARGET_TROVE_ETH_DEPOSIT_AMT.into(),
                (purger_utils::TARGET_TROVE_WBTC_DEPOSIT_AMT * 10_u128.pow(10)).into(),
            ]
                .span();

            let trove_value: Wad = purger_utils::get_sum_of_value(shrine, yangs, target_trove_yang_amts);

            wadray::rmul_wr(trove_value, threshold) + 1_u128.into()
        };

        let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, trove_debt);

        purger_utils::set_thresholds(shrine, yangs, threshold);

        let target_trove_health: Health = shrine.get_trove_health(target_trove);

        if target_threshold_above_cutoff {
            purger_utils::lower_prices_to_raise_trove_ltv(
                shrine, seer, yangs, target_trove_health.value, target_trove_health.debt, threshold,
            );
        }

        let target_trove_updated_health: Health = shrine.get_trove_health(target_trove);
        purger_utils::assert_trove_is_liquidatable(shrine, purger, target_trove, target_trove_updated_health);

        let (penalty, max_close_amt) = purger.preview_liquidate(target_trove).expect('Should be liquidatable');

        common::assert_equalish(penalty, expected_penalty, (RAY_ONE / 10).into(), 'wrong penalty');

        common::assert_equalish(max_close_amt, expected_max_close_amt, (WAD_ONE * 2).into(), 'wrong max close amt');
    }

    #[test]
    fn test_liquidate_pass() {
        let searcher_start_yin: Wad = purger_utils::SEARCHER_YIN.into();
        let PurgerTestConfig {
            shrine, abbot, seer, purger, yangs, gates, ..,
        } = purger_utils::purger_deploy_with_searcher(searcher_start_yin, Option::None);
        let mut spy = spy_events();

        purger_utils::create_whale_trove(abbot, yangs, gates);

        let initial_trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
        let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, initial_trove_debt);

        // Accrue some interest
        common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);

        let shrine_health: Health = shrine.get_shrine_health();
        let before_total_debt: Wad = shrine_health.debt;
        let target_trove_start_health: Health = shrine.get_trove_health(target_trove);
        let accrued_interest: Wad = target_trove_start_health.debt - initial_trove_debt;
        // Sanity check that some interest has accrued
        assert(accrued_interest.is_non_zero(), 'no interest accrued');

        let target_ltv: Ray = (target_trove_start_health.threshold.into() + 1_u128).into();
        purger_utils::lower_prices_to_raise_trove_ltv(
            shrine, seer, yangs, target_trove_start_health.value, target_trove_start_health.debt, target_ltv,
        );

        // Sanity check that LTV is at the target liquidation LTV
        let target_trove_updated_start_health: Health = shrine.get_trove_health(target_trove);
        purger_utils::assert_trove_is_liquidatable(shrine, purger, target_trove, target_trove_updated_start_health);

        let (penalty, max_close_amt) = purger.preview_liquidate(target_trove).expect('Should be liquidatable');
        let searcher: ContractAddress = purger_utils::SEARCHER;

        let before_searcher_asset_bals: Span<Span<u128>> = common::get_token_balances(yangs, array![searcher].span());

        start_cheat_caller_address(purger.contract_address, searcher);
        let freed_assets: Span<AssetBalance> = purger.liquidate(target_trove, Bounded::MAX, searcher);

        // Assert that total debt includes accrued interest on liquidated trove
        let shrine_health: Health = shrine.get_shrine_health();
        let after_total_debt: Wad = shrine_health.debt;
        assert(after_total_debt == before_total_debt + accrued_interest - max_close_amt, 'wrong total debt');

        // Check that LTV is close to safety margin
        let target_trove_after_health: Health = shrine.get_trove_health(target_trove);
        assert(
            target_trove_after_health.debt == target_trove_updated_start_health.debt - max_close_amt,
            'wrong debt after liquidation',
        );

        purger_utils::assert_ltv_at_safety_margin(
            target_trove_start_health.threshold, target_trove_after_health.ltv, Option::None,
        );

        // Check searcher yin balance
        assert(shrine.get_yin(searcher) == searcher_start_yin - max_close_amt, 'wrong searcher yin balance');

        let (expected_freed_pct, expected_freed_amts) = purger_utils::get_expected_liquidation_assets(
            purger_utils::target_trove_yang_asset_amts(),
            target_trove_updated_start_health,
            max_close_amt,
            penalty,
            Option::None,
        );
        let expected_freed_assets: Span<AssetBalance> = common::combine_assets_and_amts(yangs, expected_freed_amts);

        // Check that searcher has received collateral
        purger_utils::assert_received_assets(
            before_searcher_asset_bals,
            common::get_token_balances(yangs, array![searcher].span()),
            expected_freed_assets,
            10_u128, // error margin
            'wrong searcher asset balance',
        );

        common::assert_asset_balances_equalish(
            freed_assets, expected_freed_assets, 10_u128, // error margin
            'wrong freed asset amount',
        );

        let expected_events = array![
            (
                purger.contract_address,
                purger_contract::Event::Purged(
                    purger_contract::Purged {
                        trove_id: target_trove,
                        purge_amt: max_close_amt,
                        percentage_freed: expected_freed_pct,
                        funder: searcher,
                        recipient: searcher,
                        freed_assets: freed_assets,
                    },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);

        shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
    }

    #[test]
    fn test_liquidate_with_flashmint_pass() {
        let PurgerTestConfig {
            shrine, abbot, seer, purger, yangs, gates, ..,
        } = purger_utils::purger_deploy_with_searcher(purger_utils::SEARCHER_YIN.into(), Option::None);

        purger_utils::create_whale_trove(abbot, yangs, gates);

        let target_trove: u64 = purger_utils::funded_healthy_trove(
            abbot, yangs, gates, purger_utils::TARGET_TROVE_YIN.into(),
        );
        let flashmint = flash_mint_utils::flashmint_deploy(shrine.contract_address);
        let flash_liquidator = purger_utils::flash_liquidator_deploy(
            shrine.contract_address,
            abbot.contract_address,
            flashmint.contract_address,
            purger.contract_address,
            Option::None,
        );

        // Fund flash liquidator contract with some collateral to open a trove
        // but not draw any debt
        common::fund_user(flash_liquidator.contract_address, yangs, absorber_utils::provider_asset_amts());

        // Accrue some interest
        common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);

        // Update prices and multiplier

        let target_trove_start_health: Health = shrine.get_trove_health(target_trove);
        let target_ltv: Ray = (target_trove_start_health.threshold.into() + 1_u128).into();
        purger_utils::lower_prices_to_raise_trove_ltv(
            shrine, seer, yangs, target_trove_start_health.value, target_trove_start_health.debt, target_ltv,
        );

        // Sanity check that LTV is at the target liquidation LTV
        let target_trove_updated_start_health: Health = shrine.get_trove_health(target_trove);
        purger_utils::assert_trove_is_liquidatable(shrine, purger, target_trove, target_trove_updated_start_health);
        let (_, max_close_amt) = purger.preview_liquidate(target_trove).expect('Should be liquidatable');

        let searcher: ContractAddress = purger_utils::SEARCHER;

        start_cheat_caller_address(flash_liquidator.contract_address, searcher);
        flash_liquidator.flash_liquidate(target_trove, yangs, gates);

        // Check that LTV is close to safety margin
        let target_trove_after_health: Health = shrine.get_trove_health(target_trove);
        assert(
            target_trove_after_health.debt == target_trove_updated_start_health.debt - max_close_amt,
            'wrong debt after liquidation',
        );

        purger_utils::assert_ltv_at_safety_margin(
            target_trove_start_health.threshold, target_trove_after_health.ltv, Option::None,
        );

        shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
    }

    // This test parametrizes over thresholds (by setting all yangs thresholds to the given value)
    // and the LTV at liquidation, and checks for the following
    // 1. LTV has decreased
    // 2. trove's debt is reduced by the close amount
    // 3. If it is not a full liquidation, then the post-liquidation LTV is at the target safety margin
    #[test]
    #[test_case(name: "threshold1_a", *purger_utils::interesting_thresholds_for_liquidation()[0], true)]
    #[test_case(name: "threshold1_b", *purger_utils::interesting_thresholds_for_liquidation()[0], false)]
    #[test_case(name: "threshold2_a", *purger_utils::interesting_thresholds_for_liquidation()[1], true)]
    #[test_case(name: "threshold2_b", *purger_utils::interesting_thresholds_for_liquidation()[1], false)]
    #[test_case(name: "threshold3_a", *purger_utils::interesting_thresholds_for_liquidation()[2], true)]
    #[test_case(name: "threshold3_b", *purger_utils::interesting_thresholds_for_liquidation()[2], false)]
    #[test_case(name: "threshold4_a", *purger_utils::interesting_thresholds_for_liquidation()[3], true)]
    #[test_case(name: "threshold4_b", *purger_utils::interesting_thresholds_for_liquidation()[3], false)]
    #[test_case(name: "threshold5_a", *purger_utils::interesting_thresholds_for_liquidation()[4], true)]
    #[test_case(name: "threshold5_b", *purger_utils::interesting_thresholds_for_liquidation()[4], false)]
    #[test_case(name: "threshold6_a", *purger_utils::interesting_thresholds_for_liquidation()[5], true)]
    #[test_case(name: "threshold6_b", *purger_utils::interesting_thresholds_for_liquidation()[5], false)]
    #[test_case(name: "threshold7_a", *purger_utils::interesting_thresholds_for_liquidation()[6], true)]
    #[test_case(name: "threshold7_b", *purger_utils::interesting_thresholds_for_liquidation()[6], false)]
    #[test_case(name: "threshold8_a", *purger_utils::interesting_thresholds_for_liquidation()[7], true)]
    #[test_case(name: "threshold8_b", *purger_utils::interesting_thresholds_for_liquidation()[7], false)]
    fn test_liquidate(threshold: Ray, is_recovery_mode: bool) {
        let classes = Option::Some(purger_utils::declare_contracts());

        let low_ltv_cutoff: Ray = (2 * RAY_PERCENT).into();

        let target_ltvs: Span<Ray> = array![
            (threshold.into() + 1_u128).into(), //just above threshold
            threshold + RAY_PERCENT.into(), // 1% above threshold
            // halfway between threshold and 100%
            threshold + ((RAY_ONE - threshold.into()) / 2_u128).into(),
            (RAY_ONE - RAY_PERCENT).into(), // 99%
            (RAY_ONE + RAY_PERCENT).into() // 101%
        ]
            .span();

        for target_ltv in target_ltvs {
            let searcher_start_yin: Wad = purger_utils::SEARCHER_YIN.into();
            let PurgerTestConfig {
                shrine, abbot, seer, purger, yangs, gates, ..,
            } = purger_utils::purger_deploy_with_searcher(searcher_start_yin, classes);

            let mut spy = spy_events();

            purger_utils::create_whale_trove(abbot, yangs, gates);

            // NOTE: This 2% cut off is completely arbitrary and meant only for excluding
            // the two test cases in `interesting_thresholds_for_liquidation`: 0% and 1%.
            // If more low thresholds were added that were above 2% but below the
            // starting LTV of the trove, then this cutoff would need to be adjusted.
            let target_ltv_above_cutoff = *target_ltv > low_ltv_cutoff;
            let trove_debt: Wad = if target_ltv_above_cutoff {
                // If target_ltv is above 2%, then we can set the trove's debt
                // to `TARGET_TROVE_YIN` and adjust prices in order to reach
                // the target LTV
                purger_utils::TARGET_TROVE_YIN.into()
            } else {
                // Otherwise, we set the debt for the trove such that we get
                // the desired ltv for the trove from the get-go in order
                // to avoid overflow issues in lower_prices_to_raise_trove_ltv
                //
                // This is because lower_prices_to_raise_trove_ltv is designed for
                // raising the trove's LTV to the given *higher* LTV,
                // not lowering it.
                let target_trove_yang_amts: Span<Wad> = array![
                    purger_utils::TARGET_TROVE_ETH_DEPOSIT_AMT.into(),
                    (purger_utils::TARGET_TROVE_WBTC_DEPOSIT_AMT * 10_u128.pow(10)).into(),
                ]
                    .span();

                let trove_value: Wad = purger_utils::get_sum_of_value(shrine, yangs, target_trove_yang_amts);

                wadray::rmul_wr(trove_value, *target_ltv) + 1_u128.into()
            };

            let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, trove_debt);

            // Set thresholds to provided value
            purger_utils::set_thresholds(shrine, yangs, threshold);

            // Accrue some interest
            common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);

            let target_trove_start_health: Health = shrine.get_trove_health(target_trove);

            if threshold > low_ltv_cutoff && target_ltv_above_cutoff {
                purger_utils::lower_prices_to_raise_trove_ltv(
                    shrine, seer, yangs, target_trove_start_health.value, target_trove_start_health.debt, *target_ltv,
                );

                // Note that although recovery mode is parametrized, the limitation is that
                // it is not reasonably feasible to trigger recovery mode in a sensible way
                // when the threshold is very low because we would essentially need to lower
                // the collateral prices to near zero, which would lead to an underflow in the
                // helper function.
                if is_recovery_mode {
                    purger_utils::trigger_recovery_mode(
                        shrine, seer, yangs, common::RecoveryModeSetupType::ExceedsBuffer,
                    );
                }
            }

            // Get the updated values after adjusting prices
            // The threshold may have changed if in recovery mode
            let target_trove_updated_start_health: Health = shrine.get_trove_health(target_trove);

            let (penalty, max_close_amt) = purger.preview_liquidate(target_trove).expect('Should be liquidatable');

            let searcher: ContractAddress = purger_utils::SEARCHER;
            start_cheat_caller_address(purger.contract_address, searcher);
            let freed_assets: Span<AssetBalance> = purger.liquidate(target_trove, Bounded::MAX, searcher);

            // Check that LTV is close to safety margin
            let target_trove_after_health: Health = shrine.get_trove_health(target_trove);

            let is_fully_liquidated: bool = target_trove_updated_start_health.debt == max_close_amt;
            if !is_fully_liquidated {
                purger_utils::assert_ltv_at_safety_margin(
                    target_trove_updated_start_health.threshold, target_trove_after_health.ltv, Option::None,
                );

                assert(
                    target_trove_after_health.debt == target_trove_updated_start_health.debt - max_close_amt,
                    'wrong debt after liquidation',
                );
            } else {
                assert(target_trove_after_health.debt.is_zero(), 'should be 0 debt');
            }

            let (expected_freed_pct, _) = purger_utils::get_expected_liquidation_assets(
                purger_utils::target_trove_yang_asset_amts(),
                target_trove_updated_start_health,
                max_close_amt,
                penalty,
                Option::None,
            );

            let expected_events = array![
                (
                    purger.contract_address,
                    purger_contract::Event::Purged(
                        purger_contract::Purged {
                            trove_id: target_trove,
                            purge_amt: max_close_amt,
                            percentage_freed: expected_freed_pct,
                            funder: searcher,
                            recipient: searcher,
                            freed_assets,
                        },
                    ),
                ),
            ];

            spy.assert_emitted(@expected_events);

            shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
        };
    }

    #[test]
    #[should_panic(expected: 'PU: Not liquidatable')]
    fn test_liquidate_trove_healthy_fail() {
        let PurgerTestConfig {
            shrine, abbot, purger, yangs, gates, ..,
        } = purger_utils::purger_deploy_with_searcher(purger_utils::SEARCHER_YIN.into(), Option::None);
        let healthy_trove: u64 = purger_utils::funded_healthy_trove(
            abbot, yangs, gates, purger_utils::TARGET_TROVE_YIN.into(),
        );

        purger_utils::assert_trove_is_healthy(shrine, purger, healthy_trove, shrine.get_trove_health(healthy_trove));

        let searcher: ContractAddress = purger_utils::SEARCHER;
        start_cheat_caller_address(purger.contract_address, searcher);
        purger.liquidate(healthy_trove, Bounded::MAX, searcher);
    }

    #[test]
    #[should_panic(expected: 'PU: Not liquidatable')]
    fn test_liquidate_trove_healthy_high_threshold_fail() {
        let PurgerTestConfig {
            shrine, abbot, purger, yangs, gates, ..,
        } = purger_utils::purger_deploy_with_searcher(purger_utils::SEARCHER_YIN.into(), Option::None);
        let healthy_trove: u64 = purger_utils::funded_healthy_trove(
            abbot, yangs, gates, purger_utils::TARGET_TROVE_YIN.into(),
        );

        let threshold: Ray = (95 * RAY_PERCENT).into();
        purger_utils::set_thresholds(shrine, yangs, threshold);
        let max_forge_amt: Wad = shrine.get_max_forge(healthy_trove);

        let healthy_trove_owner: ContractAddress = purger_utils::TARGET_TROVE_OWNER;
        start_cheat_caller_address(abbot.contract_address, healthy_trove_owner);
        abbot.forge(healthy_trove, max_forge_amt, Zero::zero());
        stop_cheat_caller_address(abbot.contract_address);

        // Sanity check that LTV is above absorption threshold and safe
        let health: Health = shrine.get_trove_health(healthy_trove);
        assert(health.ltv > purger_contract::ABSORPTION_THRESHOLD.into(), 'too low');
        purger_utils::assert_trove_is_healthy(shrine, purger, healthy_trove, health);

        let searcher: ContractAddress = purger_utils::SEARCHER;
        start_cheat_caller_address(purger.contract_address, searcher);
        purger.liquidate(healthy_trove, Bounded::MAX, searcher);
    }

    #[test]
    #[should_panic(expected: 'SH: Insufficient yin balance')]
    fn test_liquidate_insufficient_yin_fail() {
        let target_trove_yin: Wad = purger_utils::TARGET_TROVE_YIN.into();
        let searcher_yin: Wad = (target_trove_yin.into() / 10_u128).into();

        let PurgerTestConfig {
            shrine, abbot, seer, purger, yangs, gates, ..,
        } = purger_utils::purger_deploy_with_searcher(searcher_yin, Option::None);
        let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, target_trove_yin);

        let target_trove_health: Health = shrine.get_trove_health(target_trove);

        let target_ltv: Ray = (target_trove_health.threshold.into() + 1_u128).into();
        purger_utils::lower_prices_to_raise_trove_ltv(
            shrine, seer, yangs, target_trove_health.value, target_trove_health.debt, target_ltv,
        );

        // Sanity check that LTV is at the target liquidation LTV
        let updated_target_trove_health: Health = shrine.get_trove_health(target_trove);
        purger_utils::assert_trove_is_liquidatable(shrine, purger, target_trove, updated_target_trove_health);

        let searcher: ContractAddress = purger_utils::SEARCHER;
        start_cheat_caller_address(purger.contract_address, searcher);
        purger.liquidate(target_trove, Bounded::MAX, searcher);
    }

    //
    // Tests - Absorb
    //

    // This test fixes the trove's debt to 1,000 in order to test the ground truth values of the
    // penalty and close amount when LTV is at threshold. The error margin is relaxed because the
    // `lower_prices_to_raise_trove_ltv` may not put the trove in the exact LTV as the threshold.

    #[test]
    #[test_case(
        0,
        593187000000000000000_u128.into(), // 593.187 max close amount (65% threshold, 71.18% LTV)
        415495925821860081925464354_u128.into(), // 65% * (70% * 65%/71.18%) = 41.54...% rm threshold upper bound
        846603498063000000000_u128.into() // 896.358... rm max close amount lower bound
    )]
    #[test_case(
        1,
        696105000000000000000_u128.into(), // 696.105 max close amount (70% threshold, 76.65% LTV)
        447488584474885783433232258_u128.into(), // 70% * (70% * 70%/76.65%) = 44.74...% rm threshold upper bound
        896582503300000000000_u128.into() // 931.454... rm max close amount lower bound
    )]
    #[test_case(
        2,
        842762000000000000000_u128.into(), // 842.762 max close amount (75% threshold, 82.13% LTV)
        479422866187751078323999842_u128.into(), // 75% * (70% * 75%/82.13%) = 47.94...% rm threshold upper bound
        953004076318000000000_u128.into() // 969.503... rm max close amount lower bound
    )]
    #[test_case(
        3,
        999945000000000000000_u128.into(), // 999.945 max close amount (78.74% threshold, 86.2203% LTV)
        503360730593607228930942959_u128
            .into(), // 78.74% * (70% * 78.74%/86.2203%) = 50.33...% rm threshold upper bound
        999985498568000000000_u128.into() // 999.985... rm max close amount lower bound
    )]
    fn test_preview_absorb_below_trove_debt_parametrized(
        idx: usize,
        expected_max_close_amt: Wad,
        // Since recovery mode buffer is exceeded by lowering yangs' prices, this would in turn
        // have a knock-on effect of further lowering the trove's threshold, which makes it difficult
        // to calculate the expected recovery mode threshold beforehand and max close amounts.
        // However, we can relax the strictness by checking that the actual recovery mode threhsold is
        // less than that the recovery mode threshold if recovery mode had been triggered based on the
        // trove's LTV right before prices were lowered to trigger recovery mode.
        expected_rm_threshold_upper_bound: Ray,
        // Since recovery mode buffer is exceeded by lowering yangs' prices, this would in turn
        // have a knock-on effect of further lowering the trove's threshold, which makes it difficult
        // to calculate the expected recovery mode threshold beforehand and max close amounts.
        // However, we can relax the strictness by checking that the actual recovery mode threhsold is
        // less than that the recovery mode threshold if recovery mode had been triggered based on the
        // trove's LTV right before prices were lowered to trigger recovery mode.
        expected_rm_max_close_amt_lower_bound: Wad,
    ) {
        let classes = Option::Some(purger_utils::declare_contracts());

        let threshold: Ray = *purger_utils::interesting_thresholds_for_absorption_below_trove_debt().at(idx);
        let mut target_ltvs: Span<Ray> =
            *purger_utils::ltvs_for_interesting_thresholds_for_absorption_below_trove_debt()
            .at(idx);
        let target_ltv: Ray = *target_ltvs.pop_front().unwrap();

        let trove_debt: Wad = (WAD_ONE * 1000).into();
        let expected_penalty: Ray = purger_contract::MAX_PENALTY.into();

        for is_recovery_mode in BOOL_PARAMETRIZED.span() {
            let PurgerTestConfig {
                shrine, abbot, seer, absorber, purger, yangs, gates,
            } = purger_utils::purger_deploy(classes);

            let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, trove_debt);

            if !(*is_recovery_mode) {
                purger_utils::create_whale_trove(abbot, yangs, gates);
            }

            purger_utils::funded_absorber(shrine, abbot, absorber, yangs, gates, (trove_debt.into() * 2_u128).into());
            purger_utils::set_thresholds(shrine, yangs, threshold);

            // Make the target trove absorbable
            let target_trove_start_health: Health = shrine.get_trove_health(target_trove);
            purger_utils::lower_prices_to_raise_trove_ltv(
                shrine, seer, yangs, target_trove_start_health.value, target_trove_start_health.debt, target_ltv,
            );

            if (*is_recovery_mode) {
                purger_utils::trigger_recovery_mode(shrine, seer, yangs, common::RecoveryModeSetupType::ExceedsBuffer);
            } else {
                // sanity check
                assert(!shrine.is_recovery_mode(), 'in recovery mode');
            }

            let target_trove_updated_start_health: Health = shrine.get_trove_health(target_trove);
            purger_utils::assert_trove_is_absorbable(shrine, purger, target_trove, target_trove_updated_start_health);

            let (penalty, max_close_amt, _) = purger.preview_absorb(target_trove).expect('Should be absorbable');
            if *is_recovery_mode {
                assert(
                    target_trove_updated_start_health.threshold < expected_rm_threshold_upper_bound
                        - (RAY_PERCENT / 100).into(),
                    'wrong rm threshold',
                );

                assert(penalty < expected_penalty, 'rm penalty not lower');
                assert(max_close_amt > expected_rm_max_close_amt_lower_bound, 'rm max close amt too low');
            } else {
                common::assert_equalish(penalty, expected_penalty, (RAY_PERCENT / 10).into(), // 0.1%
                'wrong penalty');
                common::assert_equalish(
                    max_close_amt, expected_max_close_amt, (WAD_ONE / 10).into(), 'wrong max close amt',
                );
            }
        };
    }

    #[test]
    fn test_full_absorb_pass() {
        let PurgerTestConfig {
            shrine, abbot, seer, absorber, purger, yangs, gates,
        } = purger_utils::purger_deploy_with_searcher(purger_utils::SEARCHER_YIN.into(), Option::None);
        let mut spy = spy_events();

        let initial_trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
        let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, initial_trove_debt);

        // Accrue some interest
        common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);

        let target_trove_start_health: Health = shrine.get_trove_health(target_trove);
        let accrued_interest: Wad = target_trove_start_health.debt - initial_trove_debt;
        // Sanity check that some interest has accrued
        assert(accrued_interest.is_non_zero(), 'no interest accrued');

        // Fund the absorber with twice the target trove's debt
        let absorber_start_yin: Wad = (target_trove_start_health.debt.into() * 2_u128).into();
        purger_utils::funded_absorber(shrine, abbot, absorber, yangs, gates, absorber_start_yin);

        // sanity check
        assert(shrine.get_yin(absorber.contract_address) > target_trove_start_health.debt, 'not full absorption');

        let shrine_health: Health = shrine.get_shrine_health();
        let before_total_debt: Wad = shrine_health.debt;

        // Make the target trove absorbable
        let target_ltv: Ray = (purger_contract::ABSORPTION_THRESHOLD + 1).into();
        purger_utils::lower_prices_to_raise_trove_ltv(
            shrine, seer, yangs, target_trove_start_health.value, target_trove_start_health.debt, target_ltv,
        );
        let target_trove_updated_start_health: Health = shrine.get_trove_health(target_trove);
        purger_utils::assert_trove_is_absorbable(shrine, purger, target_trove, target_trove_updated_start_health);

        let (penalty, max_close_amt, expected_compensation_value) = purger
            .preview_absorb(target_trove)
            .expect('Should be absorbable');
        let caller: ContractAddress = common::NON_ZERO_ADDR;

        let before_caller_asset_bals: Span<Span<u128>> = common::get_token_balances(yangs, array![caller].span());
        let before_absorber_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, array![absorber.contract_address].span(),
        );

        start_cheat_caller_address(purger.contract_address, caller);
        let compensation: Span<AssetBalance> = purger.absorb(target_trove);

        // Assert that total debt includes accrued interest on liquidated trove
        let shrine_health: Health = shrine.get_shrine_health();
        let after_total_debt: Wad = shrine_health.debt;
        assert(after_total_debt == before_total_debt + accrued_interest - max_close_amt, 'wrong total debt');

        // Check absorption occured
        assert(absorber.get_absorptions_count() == 1, 'wrong absorptions count');

        // Check trove debt and LTV
        let target_trove_after_health: Health = shrine.get_trove_health(target_trove);
        assert(
            target_trove_after_health.debt == target_trove_start_health.debt - max_close_amt,
            'wrong debt after liquidation',
        );

        assert(target_trove_after_health.debt.is_zero(), 'not fully absorbed');

        // Check that caller has received compensation
        let target_trove_yang_asset_amts: Span<u128> = purger_utils::target_trove_yang_asset_amts();
        let expected_compensation_amts: Span<u128> = purger_utils::get_expected_compensation_assets(
            target_trove_yang_asset_amts, target_trove_updated_start_health.value, expected_compensation_value,
        );
        let expected_compensation: Span<AssetBalance> = common::combine_assets_and_amts(
            yangs, expected_compensation_amts,
        );
        purger_utils::assert_received_assets(
            before_caller_asset_bals,
            common::get_token_balances(yangs, array![caller].span()),
            expected_compensation,
            10_u128, // error margin
            'wrong caller asset balance',
        );

        common::assert_asset_balances_equalish(
            compensation, expected_compensation, 10_u128, // error margin
            'wrong freed asset amount',
        );

        // Check absorber yin balance
        assert(
            shrine.get_yin(absorber.contract_address) == absorber_start_yin - max_close_amt,
            'wrong absorber yin balance',
        );

        // Check that absorber has received collateral
        let (_, expected_freed_asset_amts) = purger_utils::get_expected_liquidation_assets(
            target_trove_yang_asset_amts,
            target_trove_updated_start_health,
            max_close_amt,
            penalty,
            Option::Some(expected_compensation_value),
        );

        let expected_freed_assets: Span<AssetBalance> = common::combine_assets_and_amts(
            yangs, expected_freed_asset_amts,
        );
        purger_utils::assert_received_assets(
            before_absorber_asset_bals,
            common::get_token_balances(yangs, array![absorber.contract_address].span()),
            expected_freed_assets,
            10000_u128, // error margin
            'wrong absorber asset balance',
        );

        let mut purger_events = spy.get_events().emitted_by(purger.contract_address).events;

        let (_, raw_purged_event) = purger_events.pop_front().unwrap();
        let purged_event = purger_utils::deserialize_purged_event(raw_purged_event);

        common::assert_asset_balances_equalish(
            purged_event.freed_assets, expected_freed_assets, 10_u128, 'wrong freed assets for event',
        );
        assert(purged_event.trove_id == target_trove, 'wrong Purged trove ID');
        assert(purged_event.purge_amt == max_close_amt, 'wrong Purged amt');
        assert(purged_event.percentage_freed == RAY_ONE.into(), 'wrong Purged freed pct');
        assert(purged_event.funder == absorber.contract_address, 'wrong Purged funder');
        assert(purged_event.recipient == absorber.contract_address, 'wrong Purged recipient');

        let expected_events = array![
            (
                purger.contract_address,
                purger_contract::Event::Compensate(purger_contract::Compensate { recipient: caller, compensation }),
            ),
        ];
        spy.assert_emitted(@expected_events);

        shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
    }


    #[test]
    #[test_case(0, 0, true, true)]
    #[test_case(0, 0, true, false)]
    #[test_case(0, 0, false, false)]
    #[test_case(0, 0, false, true)]
    #[test_case(0, 1, true, true)]
    #[test_case(0, 1, true, false)]
    #[test_case(0, 1, false, false)]
    #[test_case(0, 1, false, true)]
    #[test_case(1, 0, true, true)]
    #[test_case(1, 0, true, false)]
    #[test_case(1, 0, false, false)]
    #[test_case(1, 0, false, true)]
    #[test_case(1, 1, true, true)]
    #[test_case(1, 1, true, false)]
    #[test_case(1, 1, false, false)]
    #[test_case(1, 1, false, true)]
    #[test_case(2, 0, true, true)]
    #[test_case(2, 0, true, false)]
    #[test_case(2, 0, false, false)]
    #[test_case(2, 0, false, true)]
    #[test_case(2, 1, true, true)]
    #[test_case(2, 1, true, false)]
    #[test_case(2, 1, false, false)]
    #[test_case(2, 1, false, true)]
    #[test_case(3, 0, true, true)]
    #[test_case(3, 0, true, false)]
    #[test_case(3, 0, false, false)]
    #[test_case(3, 0, false, true)]
    #[test_case(3, 1, true, true)]
    #[test_case(3, 1, true, false)]
    #[test_case(3, 1, false, false)]
    #[test_case(3, 1, false, true)]
    fn test_partial_absorb_with_redistribution_entire_trove_debt(
        recipient_trove_yang_asset_amts_idx: usize,
        target_trove_yang_asset_amts_idx: usize,
        kill_absorber: bool,
        is_recovery_mode: bool,
    ) {
        let classes = Option::Some(purger_utils::declare_contracts());

        let recipient_trove_yang_asset_amts: Span<u128> = *purger_utils::interesting_yang_amts_for_recipient_trove()
            .at(recipient_trove_yang_asset_amts_idx);
        let target_trove_yang_asset_amts: Span<u128> = *purger_utils::interesting_yang_amts_for_redistributed_trove()
            .at(target_trove_yang_asset_amts_idx);

        let initial_trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
        let absorber_yin_cases: Span<Wad> = purger_utils::generate_operational_absorber_yin_cases(initial_trove_debt);
        for absorber_start_yin in absorber_yin_cases {
            let PurgerTestConfig {
                shrine, abbot, seer, absorber, purger, yangs, gates,
            } = purger_utils::purger_deploy(classes);

            let mut spy = spy_events();

            start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
            shrine.set_debt_ceiling((2000000 * WAD_ONE).into());
            stop_cheat_caller_address(shrine.contract_address);

            let target_trove_owner: ContractAddress = purger_utils::TARGET_TROVE_OWNER;
            common::fund_user(target_trove_owner, yangs, target_trove_yang_asset_amts);
            let target_trove: u64 = common::open_trove_helper(
                abbot, target_trove_owner, yangs, target_trove_yang_asset_amts, gates, initial_trove_debt,
            );

            // Skip interest accrual to facilitate parametrization of
            // absorber's yin balance based on target trove's debt

            let target_trove_start_health: Health = shrine.get_trove_health(target_trove);

            let recipient_trove_owner: ContractAddress = absorber_utils::PROVIDER_1;
            let recipient_trove: u64 = absorber_utils::provide_to_absorber(
                shrine,
                abbot,
                absorber,
                recipient_trove_owner,
                yangs,
                recipient_trove_yang_asset_amts,
                gates,
                *absorber_start_yin,
            );

            // Make the target trove absorbable
            let target_ltv: Ray = (purger_contract::ABSORPTION_THRESHOLD + 1).into();

            purger_utils::lower_prices_to_raise_trove_ltv(
                shrine, seer, yangs, target_trove_start_health.value, target_trove_start_health.debt, target_ltv,
            );

            let mut target_trove_updated_start_health: Health = shrine.get_trove_health(target_trove);
            if is_recovery_mode {
                purger_utils::trigger_recovery_mode(shrine, seer, yangs, common::RecoveryModeSetupType::ExceedsBuffer);

                target_trove_updated_start_health = shrine.get_trove_health(target_trove);
            } else {
                assert(!shrine.is_recovery_mode(), 'recovery mode');
            }

            let shrine_health: Health = shrine.get_shrine_health();
            let before_total_debt: Wad = shrine_health.debt;
            let before_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();

            let recipient_trove_start_health: Health = shrine.get_trove_health(recipient_trove);

            purger_utils::assert_trove_is_absorbable(shrine, purger, target_trove, target_trove_updated_start_health);

            let (penalty, max_close_amt, expected_compensation_value) = purger
                .preview_absorb(target_trove)
                .expect('Should be absorbable');
            let close_amt: Wad = *absorber_start_yin;

            // Sanity check
            assert(shrine.get_yin(absorber.contract_address) < max_close_amt, 'not less than close amount');

            let caller: ContractAddress = common::NON_ZERO_ADDR;

            let before_caller_asset_bals: Span<Span<u128>> = common::get_token_balances(yangs, array![caller].span());
            let before_absorber_asset_bals: Span<Span<u128>> = common::get_token_balances(
                yangs, array![absorber.contract_address].span(),
            );

            if kill_absorber {
                absorber_utils::kill_absorber(absorber);
                assert(!absorber.get_live(), 'sanity check');
            }

            start_cheat_caller_address(purger.contract_address, caller);
            let compensation: Span<AssetBalance> = purger.absorb(target_trove);

            let shrine_health: Health = shrine.get_shrine_health();
            let after_total_debt: Wad = shrine_health.debt;
            assert(after_total_debt == before_total_debt - close_amt, 'wrong total debt');

            // Check absorption occured
            assert(absorber.get_absorptions_count() == 1, 'wrong absorptions count');

            // Check trove debt, value and LTV
            let target_trove_after_health: Health = shrine.get_trove_health(target_trove);
            assert(target_trove_after_health.debt.is_zero(), 'wrong debt after liquidation');
            common::assert_equalish(
                target_trove_after_health.value, Zero::zero(), 2000_u128.into(), 'wrong value after liquidation',
            );

            // Check that caller has received compensation
            let expected_compensation_amts: Span<u128> = purger_utils::get_expected_compensation_assets(
                target_trove_yang_asset_amts, target_trove_updated_start_health.value, expected_compensation_value,
            );
            let expected_compensation: Span<AssetBalance> = common::combine_assets_and_amts(
                yangs, expected_compensation_amts,
            );
            purger_utils::assert_received_assets(
                before_caller_asset_bals,
                common::get_token_balances(yangs, array![caller].span()),
                expected_compensation,
                10_u128, // error margin
                'wrong caller asset balance',
            );

            common::assert_asset_balances_equalish(
                compensation, expected_compensation, 10_u128, // error margin
                'wrong freed asset amount',
            );

            // Check absorber yin balance is wiped out
            assert(shrine.get_yin(absorber.contract_address).is_zero(), 'wrong absorber yin balance');

            // Check that absorber has received proportionate share of
            // collateral
            let (expected_freed_pct, expected_freed_asset_amts) = purger_utils::get_expected_liquidation_assets(
                target_trove_yang_asset_amts,
                target_trove_updated_start_health,
                close_amt,
                penalty,
                Option::Some(expected_compensation_value),
            );

            let expected_freed_assets: Span<AssetBalance> = common::combine_assets_and_amts(
                yangs, expected_freed_asset_amts,
            );
            purger_utils::assert_received_assets(
                before_absorber_asset_bals,
                common::get_token_balances(yangs, array![absorber.contract_address].span()),
                expected_freed_assets,
                2000_u128, // error margin
                'wrong absorber asset balance',
            );

            // Check redistribution occured
            assert(shrine.get_redistributions_count() == 1, 'wrong redistributions count');

            let redistributed_amt: Wad = max_close_amt - close_amt;

            let expected_redistribution_id = 1;

            // Check if the redistribution was exceptional for all yangs
            // i.e. all value went to initial yangs and all debt went to
            // troves' deficit
            let yang1_redistribution: Wad = shrine.get_redistribution_for_yang(*yangs[0], expected_redistribution_id);
            let yang2_redistribution: Wad = shrine.get_redistribution_for_yang(*yangs[1], expected_redistribution_id);
            let is_full_exceptional_redistribution: bool = yang1_redistribution.is_zero()
                && yang2_redistribution.is_zero();

            if is_full_exceptional_redistribution {
                let after_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();
                assert_eq!(
                    after_protocol_owned_troves_debt,
                    before_protocol_owned_troves_debt + redistributed_amt,
                    "wrong troves deficit",
                );
            } else {
                // Check recipient trove's value and debt
                let recipient_trove_after_health: Health = shrine.get_trove_health(recipient_trove);

                // Relax the assertion because exceptional
                // redistribution may be triggered
                assert(
                    recipient_trove_after_health.debt > recipient_trove_start_health.debt, 'wrong recipient trove debt',
                );

                // At small values, the recipient trove may have a lower end value due to
                // fluctuations in yang prices even if yang amount stays the same.
                if redistributed_amt > WAD_ONE.into() {
                    assert(
                        recipient_trove_after_health.value > recipient_trove_start_health.value,
                        'wrong recipient trove value',
                    );
                }
            }

            // Check Purger events
            let mut purger_events = spy.get_events().emitted_by(purger.contract_address).events;

            let (_, raw_purged_event) = purger_events.pop_front().unwrap();
            let purged_event = purger_utils::deserialize_purged_event(raw_purged_event);

            common::assert_asset_balances_equalish(
                purged_event.freed_assets, expected_freed_assets, 1_u128, 'wrong freed assets for event',
            );
            common::assert_equalish(
                purged_event.percentage_freed, expected_freed_pct, 1000000_u128.into(), 'wrong Purged freed pct',
            );
            assert(purged_event.trove_id == target_trove, 'wrong Purged trove ID');
            assert(purged_event.purge_amt == close_amt, 'wrong Purged amt');
            assert(purged_event.funder == absorber.contract_address, 'wrong Purged funder');
            assert(purged_event.recipient == absorber.contract_address, 'wrong Purged recipient');

            let expected_events = array![
                (
                    purger.contract_address,
                    purger_contract::Event::Compensate(purger_contract::Compensate { recipient: caller, compensation }),
                ),
            ];
            spy.assert_emitted(@expected_events);

            // Check Shrine event

            let expected_events = array![
                (
                    shrine.contract_address,
                    shrine_contract::Event::TroveRedistributed(
                        shrine_contract::TroveRedistributed {
                            redistribution_id: expected_redistribution_id,
                            trove_id: target_trove,
                            debt: redistributed_amt,
                        },
                    ),
                ),
            ];

            spy.assert_emitted(@expected_events);

            shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
        };
    }

    // Regarding `absorber_yin_idx`:
    //
    //  - Index 0 is a dummy value for the absorber yin
    //    being a fraction of the trove's debt.
    //  - Index 1 is a dummy value for the lower bound
    //    of the absorber's yin for absorber to be operational.
    //  - Index 2 is a dummy value for the trove's debt
    //    minus the smallest unit of Wad (which would amount to
    //    1001 wei after including the initial amount in Absorber)

    #[test]
    #[test_case(0, 0, false, false, 0)]
    #[test_case(0, 0, false, false, 1)]
    #[test_case(0, 0, false, false, 2)]
    #[test_case(0, 0, false, true, 0)]
    #[test_case(0, 0, false, true, 1)]
    #[test_case(0, 0, false, true, 2)]
    #[test_case(0, 0, true, false, 0)]
    #[test_case(0, 0, true, false, 1)]
    #[test_case(0, 0, true, false, 2)]
    #[test_case(0, 0, true, true, 0)]
    #[test_case(0, 0, true, true, 1)]
    #[test_case(0, 0, true, true, 2)]
    #[test_case(0, 1, false, false, 0)]
    #[test_case(0, 1, false, false, 1)]
    #[test_case(0, 1, false, false, 2)]
    #[test_case(0, 1, false, true, 0)]
    #[test_case(0, 1, false, true, 1)]
    #[test_case(0, 1, false, true, 2)]
    #[test_case(0, 1, true, false, 0)]
    #[test_case(0, 1, true, false, 1)]
    #[test_case(0, 1, true, false, 2)]
    #[test_case(0, 1, true, true, 0)]
    #[test_case(0, 1, true, true, 1)]
    #[test_case(0, 1, true, true, 2)]
    #[test_case(0, 2, false, false, 0)]
    #[test_case(0, 2, false, false, 1)]
    #[test_case(0, 2, false, false, 2)]
    #[test_case(0, 2, false, true, 0)]
    #[test_case(0, 2, false, true, 1)]
    #[test_case(0, 2, false, true, 2)]
    #[test_case(0, 2, true, false, 0)]
    #[test_case(0, 2, true, false, 1)]
    #[test_case(0, 2, true, false, 2)]
    #[test_case(0, 2, true, true, 0)]
    #[test_case(0, 2, true, true, 1)]
    #[test_case(0, 2, true, true, 2)]
    #[test_case(0, 3, false, false, 0)]
    #[test_case(0, 3, false, false, 1)]
    #[test_case(0, 3, false, false, 2)]
    #[test_case(0, 3, false, true, 0)]
    #[test_case(0, 3, false, true, 1)]
    #[test_case(0, 3, false, true, 2)]
    #[test_case(0, 3, true, false, 0)]
    #[test_case(0, 3, true, false, 1)]
    #[test_case(0, 3, true, false, 2)]
    #[test_case(0, 3, true, true, 0)]
    #[test_case(0, 3, true, true, 1)]
    #[test_case(0, 3, true, true, 2)]
    #[test_case(1, 0, false, false, 0)]
    #[test_case(1, 0, false, false, 1)]
    #[test_case(1, 0, false, false, 2)]
    #[test_case(1, 0, false, true, 0)]
    #[test_case(1, 0, false, true, 1)]
    #[test_case(1, 0, false, true, 2)]
    #[test_case(1, 0, true, false, 0)]
    #[test_case(1, 0, true, false, 1)]
    #[test_case(1, 0, true, false, 2)]
    #[test_case(1, 0, true, true, 0)]
    #[test_case(1, 0, true, true, 1)]
    #[test_case(1, 0, true, true, 2)]
    #[test_case(1, 1, false, false, 0)]
    #[test_case(1, 1, false, false, 1)]
    #[test_case(1, 1, false, false, 2)]
    #[test_case(1, 1, false, true, 0)]
    #[test_case(1, 1, false, true, 1)]
    #[test_case(1, 1, false, true, 2)]
    #[test_case(1, 1, true, false, 0)]
    #[test_case(1, 1, true, false, 1)]
    #[test_case(1, 1, true, false, 2)]
    #[test_case(1, 1, true, true, 0)]
    #[test_case(1, 1, true, true, 1)]
    #[test_case(1, 1, true, true, 2)]
    #[test_case(1, 2, false, false, 0)]
    #[test_case(1, 2, false, false, 1)]
    #[test_case(1, 2, false, false, 2)]
    #[test_case(1, 2, false, true, 0)]
    #[test_case(1, 2, false, true, 1)]
    #[test_case(1, 2, false, true, 2)]
    #[test_case(1, 2, true, false, 0)]
    #[test_case(1, 2, true, false, 1)]
    #[test_case(1, 2, true, false, 2)]
    #[test_case(1, 2, true, true, 0)]
    #[test_case(1, 2, true, true, 1)]
    #[test_case(1, 2, true, true, 2)]
    #[test_case(1, 3, false, false, 0)]
    #[test_case(1, 3, false, false, 1)]
    #[test_case(1, 3, false, false, 2)]
    #[test_case(1, 3, false, true, 0)]
    #[test_case(1, 3, false, true, 1)]
    #[test_case(1, 3, false, true, 2)]
    #[test_case(1, 3, true, false, 0)]
    #[test_case(1, 3, true, false, 1)]
    #[test_case(1, 3, true, false, 2)]
    #[test_case(1, 3, true, true, 0)]
    #[test_case(1, 3, true, true, 1)]
    #[test_case(1, 3, true, true, 2)]
    fn test_partial_absorb_with_redistribution_below_trove_debt(
        target_trove_yang_asset_amts_idx: usize,
        recipient_trove_yang_asset_amts_idx: usize,
        is_recovery_mode: bool,
        kill_absorber: bool,
        absorber_yin_idx: usize,
    ) {
        let classes = Option::Some(purger_utils::declare_contracts());

        let target_trove_yang_asset_amts: Span<u128> = *purger_utils::interesting_yang_amts_for_redistributed_trove()
            .at(target_trove_yang_asset_amts_idx);
        let recipient_trove_yang_asset_amts: Span<u128> = *purger_utils::interesting_yang_amts_for_recipient_trove()
            .at(recipient_trove_yang_asset_amts_idx);

        let mut interesting_thresholds = purger_utils::interesting_thresholds_for_absorption_below_trove_debt();
        let mut target_ltvs: Span<Span<Ray>> =
            purger_utils::ltvs_for_interesting_thresholds_for_absorption_below_trove_debt();
        for threshold in interesting_thresholds {
            // Use only the first value which guarantees the max absorption amount is less
            // than the trove's debt
            let mut target_ltvs_arr: Span<Ray> = *target_ltvs.pop_front().unwrap();
            let target_ltv: Ray = *target_ltvs_arr.pop_front().unwrap();

            let PurgerTestConfig {
                shrine, abbot, seer, absorber, purger, yangs, gates,
            } = purger_utils::purger_deploy(classes);

            let mut spy = spy_events();

            let target_trove_owner: ContractAddress = purger_utils::TARGET_TROVE_OWNER;
            common::fund_user(target_trove_owner, yangs, target_trove_yang_asset_amts);
            let initial_trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
            let target_trove: u64 = common::open_trove_helper(
                abbot, target_trove_owner, yangs, target_trove_yang_asset_amts, gates, initial_trove_debt,
            );

            // Accrue some interest
            common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);

            // Create a whale trove if we are not testing recovery mode
            // Otherwise, Shrine will enter recovery mode when lowering prices below.
            if !is_recovery_mode {
                purger_utils::create_whale_trove(abbot, yangs, gates);
            }

            let target_trove_start_health: Health = shrine.get_trove_health(target_trove);
            let accrued_interest: Wad = target_trove_start_health.debt - initial_trove_debt;
            // Sanity check that some interest has accrued
            assert(accrued_interest.is_non_zero(), 'no interest accrued');

            purger_utils::set_thresholds(shrine, yangs, *threshold);

            // Make the target trove absorbable
            purger_utils::lower_prices_to_raise_trove_ltv(
                shrine, seer, yangs, target_trove_start_health.value, target_trove_start_health.debt, target_ltv,
            );

            // sanity check
            assert(!(is_recovery_mode ^ shrine.is_recovery_mode()), 'wrong recovery mode status');

            let target_trove_start_health: Health = shrine.get_trove_health(target_trove);

            purger_utils::assert_trove_is_absorbable(shrine, purger, target_trove, target_trove_start_health);

            let (_, max_close_amt, _) = purger.preview_absorb(target_trove).expect('Should be absorbable');

            // sanity check
            assert(max_close_amt < target_trove_start_health.debt, 'close amt ge trove debt #1');

            let caller: ContractAddress = common::NON_ZERO_ADDR;

            let before_caller_asset_bals: Span<Span<u128>> = common::get_token_balances(yangs, array![caller].span());
            let before_absorber_asset_bals: Span<Span<u128>> = common::get_token_balances(
                yangs, array![absorber.contract_address].span(),
            );

            let recipient_trove_owner: ContractAddress = absorber_utils::PROVIDER_1;

            // Provide the minimum to absorber.
            // The actual amount will be provided after
            // recovery mode adjustment is made.
            let minimum_operational_shares: Wad = (absorber_contract::INITIAL_SHARES
                + absorber_contract::MINIMUM_RECIPIENT_SHARES)
                .into();
            let recipient_trove: u64 = absorber_utils::provide_to_absorber(
                shrine,
                abbot,
                absorber,
                recipient_trove_owner,
                yangs,
                recipient_trove_yang_asset_amts,
                gates,
                minimum_operational_shares,
            );
            start_cheat_caller_address(abbot.contract_address, recipient_trove_owner);
            abbot.forge(recipient_trove, max_close_amt, Zero::zero());

            let mut target_trove_updated_start_health: Health = shrine.get_trove_health(target_trove);

            // Preview absorption again based on adjustments for recovery mode
            let (penalty, max_close_amt, expected_compensation_value) = purger
                .preview_absorb(target_trove)
                .expect('Should be absorbable');

            // sanity check
            assert(max_close_amt < target_trove_start_health.debt, 'close amt ge trove debt #2');

            let before_recipient_trove_health: Health = shrine.get_trove_health(recipient_trove);

            let shrine_health: Health = shrine.get_shrine_health();
            let before_total_debt: Wad = shrine_health.debt;
            let before_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();

            // Fund absorber based on adjusted max close amount
            // after recovery mode has been set up
            let mut absorber_start_yin: Wad = if absorber_yin_idx == 0 {
                // Fund the absorber with 1/3 of the max close amount
                (max_close_amt.into() / 3_u128).into()
            } else if absorber_yin_idx == 1 {
                minimum_operational_shares
            } else {
                max_close_amt - 1_u128.into()
            };

            let close_amt = absorber_start_yin;
            // Deduct the minimum operational shares from the amount to be provided to
            // the Absorber so that the Absorber's yin balance matches the close amount.
            absorber_start_yin -= minimum_operational_shares;

            if absorber_start_yin.is_non_zero() {
                start_cheat_caller_address(absorber.contract_address, recipient_trove_owner);
                absorber.provide(absorber_start_yin);
                stop_cheat_caller_address(absorber.contract_address);
            }

            assert(shrine.get_yin(absorber.contract_address) < max_close_amt, 'not less than close amount');
            assert(shrine.get_yin(absorber.contract_address) == close_amt, 'absorber has close amount');

            if kill_absorber {
                absorber_utils::kill_absorber(absorber);
                assert(!absorber.get_live(), 'sanity check');
            }

            start_cheat_caller_address(purger.contract_address, caller);
            let compensation: Span<AssetBalance> = purger.absorb(target_trove);

            // Assert that total debt includes accrued interest on liquidated trove
            let shrine_health: Health = shrine.get_shrine_health();
            let after_total_debt: Wad = shrine_health.debt;
            assert(after_total_debt == before_total_debt + accrued_interest - close_amt, 'wrong total debt');

            // Check absorption occured
            assert(absorber.get_absorptions_count() == 1, 'wrong absorptions count');

            // Check trove debt, value and LTV
            let target_trove_after_health: Health = shrine.get_trove_health(target_trove);

            let expected_liquidated_value: Wad = wadray::rmul_wr(max_close_amt, RAY_ONE.into() + penalty);
            let expected_after_value: Wad = target_trove_updated_start_health.value
                - expected_compensation_value
                - expected_liquidated_value;
            assert(target_trove_after_health.debt.is_non_zero(), 'debt should not be 0');

            let expected_after_debt: Wad = target_trove_updated_start_health.debt - max_close_amt;
            assert(target_trove_after_health.debt == expected_after_debt, 'wrong debt after liquidation');

            assert(target_trove_after_health.value.is_non_zero(), 'value should not be 0');

            common::assert_equalish(
                target_trove_after_health.value,
                expected_after_value,
                (WAD_ONE / 10).into(),
                'wrong value after liquidation',
            );

            purger_utils::assert_ltv_at_safety_margin(
                target_trove_updated_start_health.threshold,
                target_trove_after_health.ltv,
                // relax error margin due to liquidated trove
                // having more value from the transfer of error
                // back to the gates
                Option::Some((RAY_PERCENT * 2).into()),
            );

            // Check that caller has received compensation
            let expected_compensation_amts: Span<u128> = purger_utils::get_expected_compensation_assets(
                target_trove_yang_asset_amts, target_trove_updated_start_health.value, expected_compensation_value,
            );
            let expected_compensation: Span<AssetBalance> = common::combine_assets_and_amts(
                yangs, expected_compensation_amts,
            );
            purger_utils::assert_received_assets(
                before_caller_asset_bals,
                common::get_token_balances(yangs, array![caller].span()),
                expected_compensation,
                10_u128, // error margin
                'wrong caller asset balance',
            );

            common::assert_asset_balances_equalish(
                compensation, expected_compensation, 10_u128, // error margin
                'wrong freed asset amount',
            );

            // Check absorber yin balance is wiped out
            assert(shrine.get_yin(absorber.contract_address).is_zero(), 'wrong absorber yin balance');

            // Check that absorber has received proportionate share of collateral
            let (expected_freed_pct, expected_freed_amts) = purger_utils::get_expected_liquidation_assets(
                target_trove_yang_asset_amts,
                target_trove_updated_start_health,
                close_amt,
                penalty,
                Option::Some(expected_compensation_value),
            );
            let expected_freed_assets: Span<AssetBalance> = common::combine_assets_and_amts(yangs, expected_freed_amts);
            purger_utils::assert_received_assets(
                before_absorber_asset_bals,
                common::get_token_balances(yangs, array![absorber.contract_address].span()),
                expected_freed_assets,
                1000_u128, // error margin
                'wrong absorber asset balance',
            );

            // Check redistribution occured
            assert(shrine.get_redistributions_count() == 1, 'wrong redistributions count');

            // Check recipient trove's debt
            let after_recipient_trove_health = shrine.get_trove_health(recipient_trove);
            let expected_redistributed_amt: Wad = max_close_amt - close_amt;

            let expected_redistribution_id = 1;

            // Check if the redistribution was exceptional for all yangs
            // i.e. all value went to initial yangs and all debt went to troves' deficit
            let yang1_redistribution: Wad = shrine.get_redistribution_for_yang(*yangs[0], expected_redistribution_id);
            let yang2_redistribution: Wad = shrine.get_redistribution_for_yang(*yangs[1], expected_redistribution_id);
            let is_full_exceptional_redistribution: bool = yang1_redistribution.is_zero()
                && yang2_redistribution.is_zero();

            if is_full_exceptional_redistribution {
                let after_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();
                let expected_protocol_owned_troves_debt = before_protocol_owned_troves_debt
                    + expected_redistributed_amt;
                assert_eq!(
                    after_protocol_owned_troves_debt, expected_protocol_owned_troves_debt, "wrong troves deficit",
                );
            } else {
                // Check recipient trove's value and debt
                if absorber_yin_idx == 2 {
                    // Loss of precision because redistributed debt is too small
                    assert(
                        after_recipient_trove_health.debt == before_recipient_trove_health.debt,
                        'wrong recipient trove debt',
                    );
                } else {
                    // Relax the assertion because exceptional redistribution may
                    // be triggered
                    assert(
                        after_recipient_trove_health.debt > before_recipient_trove_health.debt,
                        'wrong recipient trove debt',
                    );
                }
                let error_margin: Wad = 1000000000000_u128.into();
                assert(
                    after_recipient_trove_health.value > before_recipient_trove_health.value - error_margin,
                    'wrong recipient trove value',
                );
            }

            // Check remainder yang assets for redistributed trove is correct
            let expected_remainder_pct: Ray = wadray::rdiv_ww(
                expected_after_value, target_trove_updated_start_health.value,
            );
            let mut expected_remainder_trove_yang_asset_amts = common::scale_span_by_pct(
                target_trove_yang_asset_amts, expected_remainder_pct,
            );

            let mut yangs_copy = yangs;
            let mut gates_copy = gates;
            for expected_asset_amt in expected_remainder_trove_yang_asset_amts.pop_front() {
                let gate: IGateDispatcher = *gates_copy.pop_front().unwrap();
                let remainder_trove_yang: Wad = shrine.get_deposit(*yangs_copy.pop_front().unwrap(), target_trove);
                let remainder_asset_amt: u128 = gate.convert_to_assets(remainder_trove_yang);

                let error_margin: u128 = 10_u128
                    .pow((IERC20Dispatcher { contract_address: gate.get_asset() }.decimals() / 2).into());
                common::assert_equalish(
                    remainder_asset_amt, *expected_asset_amt, error_margin, 'wrong remainder yang asset',
                );
            }

            // Check Purger events

            let mut purger_events = spy.get_events().emitted_by(purger.contract_address).events;
            let (_, raw_purged_event) = purger_events.pop_front().unwrap();
            let purged_event = purger_utils::deserialize_purged_event(raw_purged_event);

            common::assert_asset_balances_equalish(
                purged_event.freed_assets, expected_freed_assets, 1000_u128, 'wrong freed assets for event',
            );
            assert(purged_event.trove_id == target_trove, 'wrong Purged trove ID');
            assert(purged_event.purge_amt == close_amt, 'wrong Purged amt');
            common::assert_equalish(
                purged_event.percentage_freed, expected_freed_pct, 1000000_u128.into(), 'wrong Purged freed pct',
            );
            assert(purged_event.funder == absorber.contract_address, 'wrong Purged funder');
            assert(purged_event.recipient == absorber.contract_address, 'wrong Purged recipient');

            let expected_events = array![
                (
                    purger.contract_address,
                    purger_contract::Event::Compensate(purger_contract::Compensate { recipient: caller, compensation }),
                ),
            ];
            spy.assert_emitted(@expected_events);

            // Check Shrine event
            let expected_events = array![
                (
                    shrine.contract_address,
                    shrine_contract::Event::TroveRedistributed(
                        shrine_contract::TroveRedistributed {
                            redistribution_id: expected_redistribution_id,
                            trove_id: target_trove,
                            debt: expected_redistributed_amt,
                        },
                    ),
                ),
            ];

            spy.assert_emitted(@expected_events);

            shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
        };
    }


    // Note that the absorber has zero shares in this test because no provider has
    // provided yin yet.
    #[test]
    #[test_case(0, true)]
    #[test_case(0, false)]
    #[test_case(1, true)]
    #[test_case(1, false)]
    #[test_case(2, true)]
    #[test_case(2, false)]
    #[test_case(3, true)]
    #[test_case(3, false)]
    fn test_absorb_full_redistribution(recipient_trove_yang_asset_amts_idx: usize, kill_absorber: bool) {
        let classes = Option::Some(purger_utils::declare_contracts());

        let recipient_trove_yang_asset_amts: Span<u128> = *purger_utils::interesting_yang_amts_for_recipient_trove()
            .at(recipient_trove_yang_asset_amts_idx);

        let target_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_redistributed_trove();
        let absorber_yin_cases: Span<Wad> = purger_utils::inoperational_absorber_yin_cases();

        for target_trove_yang_asset_amts in target_trove_yang_asset_amts_cases {
            for absorber_start_yin in absorber_yin_cases {
                let PurgerTestConfig {
                    shrine, abbot, seer, absorber, purger, yangs, gates,
                } = purger_utils::purger_deploy(classes);

                let mut spy = spy_events();

                start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
                shrine.set_debt_ceiling((2000000 * WAD_ONE).into());
                stop_cheat_caller_address(shrine.contract_address);

                let initial_trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
                let target_trove_owner: ContractAddress = purger_utils::TARGET_TROVE_OWNER;
                common::fund_user(target_trove_owner, yangs, *target_trove_yang_asset_amts);
                let target_trove: u64 = common::open_trove_helper(
                    abbot,
                    target_trove_owner,
                    yangs,
                    *target_trove_yang_asset_amts,
                    gates,
                    purger_utils::TARGET_TROVE_YIN.into(),
                );

                let recipient_trove_owner: ContractAddress = absorber_utils::PROVIDER_1;
                let recipient_trove: u64 = absorber_utils::provide_to_absorber(
                    shrine,
                    abbot,
                    absorber,
                    recipient_trove_owner,
                    yangs,
                    recipient_trove_yang_asset_amts,
                    gates,
                    *absorber_start_yin,
                );

                // Accrue some interest
                common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);

                let target_trove_start_health: Health = shrine.get_trove_health(target_trove);
                let accrued_interest: Wad = target_trove_start_health.debt - initial_trove_debt;
                // Sanity check that some interest has accrued
                assert(accrued_interest.is_non_zero(), 'no interest accrued');

                let shrine_health: Health = shrine.get_shrine_health();
                let before_total_debt: Wad = shrine_health.debt;

                let target_ltv: Ray = (purger_contract::ABSORPTION_THRESHOLD + 1).into();
                purger_utils::lower_prices_to_raise_trove_ltv(
                    shrine, seer, yangs, target_trove_start_health.value, target_trove_start_health.debt, target_ltv,
                );

                let target_trove_updated_start_health: Health = shrine.get_trove_health(target_trove);

                let before_recipient_trove_health: Health = shrine.get_trove_health(recipient_trove);

                let before_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();

                purger_utils::assert_trove_is_absorbable(
                    shrine, purger, target_trove, target_trove_updated_start_health,
                );

                let caller: ContractAddress = common::NON_ZERO_ADDR;
                let before_caller_asset_bals: Span<Span<u128>> = common::get_token_balances(
                    yangs, array![caller].span(),
                );

                if kill_absorber {
                    absorber_utils::kill_absorber(absorber);
                    assert(!absorber.get_live(), 'sanity check');
                }

                let (_, _, expected_compensation_value) = purger
                    .preview_absorb(target_trove)
                    .expect('Should be absorbable');

                start_cheat_caller_address(purger.contract_address, caller);
                let compensation: Span<AssetBalance> = purger.absorb(target_trove);

                // Assert that total debt includes accrued interest on liquidated
                // trove
                let after_total_debt: Wad = shrine.get_shrine_health().debt;
                assert(after_total_debt == before_total_debt + accrued_interest, 'wrong total debt');

                // Check that caller has received compensation
                let expected_compensation_amts: Span<u128> = purger_utils::get_expected_compensation_assets(
                    *target_trove_yang_asset_amts, target_trove_updated_start_health.value, expected_compensation_value,
                );
                let expected_compensation: Span<AssetBalance> = common::combine_assets_and_amts(
                    yangs, expected_compensation_amts,
                );
                purger_utils::assert_received_assets(
                    before_caller_asset_bals,
                    common::get_token_balances(yangs, array![caller].span()),
                    expected_compensation,
                    10_u128, // error margin
                    'wrong caller asset balance',
                );

                common::assert_asset_balances_equalish(
                    compensation, expected_compensation, 10_u128, // error margin
                    'wrong freed asset amount',
                );

                let target_trove_after_health: Health = shrine.get_trove_health(target_trove);
                assert(target_trove_after_health.is_healthy(), 'should be healthy');
                assert(target_trove_after_health.ltv.is_zero(), 'LTV should be 0');
                assert(target_trove_after_health.value.is_zero(), 'value should be 0');
                assert(target_trove_after_health.debt.is_zero(), 'debt should be 0');

                // Check no absorption occured
                assert(absorber.get_absorptions_count() == 0, 'wrong absorptions count');

                // Check redistribution occured
                assert(shrine.get_redistributions_count() == 1, 'wrong redistributions count');

                let expected_redistribution_id = 1;

                // Check if the redistribution was exceptional for all yangs
                // i.e. all value went to initial yangs and all debt went to
                // troves' deficit
                let yang1_redistribution: Wad = shrine
                    .get_redistribution_for_yang(*yangs[0], expected_redistribution_id);
                let yang2_redistribution: Wad = shrine
                    .get_redistribution_for_yang(*yangs[1], expected_redistribution_id);
                let is_full_exceptional_redistribution: bool = yang1_redistribution.is_zero()
                    && yang2_redistribution.is_zero();

                if is_full_exceptional_redistribution {
                    let after_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();
                    let expected_protocol_owned_troves_debt = before_protocol_owned_troves_debt
                        + target_trove_start_health.debt;
                    assert_eq!(
                        after_protocol_owned_troves_debt, expected_protocol_owned_troves_debt, "wrong troves deficit",
                    );
                } else {
                    // Check recipient trove's value and debt
                    let after_recipient_trove_health = shrine.get_trove_health(recipient_trove);
                    assert(
                        after_recipient_trove_health.debt > before_recipient_trove_health.debt,
                        'wrong recipient trove debt',
                    );

                    assert(
                        after_recipient_trove_health.value > before_recipient_trove_health.value,
                        'wrong recipient trove value',
                    );
                }

                // Check Purger events
                let purger_events = spy.get_events().emitted_by(purger.contract_address).events;

                common::assert_event_not_emitted_by_name(purger_events.span(), selector!("Purged"));

                let expected_events = array![
                    (
                        purger.contract_address,
                        purger_contract::Event::Compensate(
                            purger_contract::Compensate { recipient: caller, compensation },
                        ),
                    ),
                ];
                spy.assert_emitted(@expected_events);

                // Check Shrine event
                let expected_events = array![
                    (
                        shrine.contract_address,
                        shrine_contract::Event::TroveRedistributed(
                            shrine_contract::TroveRedistributed {
                                redistribution_id: expected_redistribution_id,
                                trove_id: target_trove,
                                debt: target_trove_updated_start_health.debt,
                            },
                        ),
                    ),
                ];

                spy.assert_emitted(@expected_events);

                shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
            };
        };
    }

    // This test parametrizes over thresholds (by setting all yangs thresholds to the given value)
    // and the LTV at liquidation, and checks for the following for thresholds up to 78.74%:
    // 1. LTV has decreased to the target safety margin
    // 2. trove's debt is reduced by the close amount, which is less than the trove's debt
    #[test]
    #[test_case(0, 0, true, true)]
    #[test_case(0, 0, true, false)]
    #[test_case(0, 0, false, false)]
    #[test_case(0, 0, false, true)]
    #[test_case(1, 1, true, true)]
    #[test_case(1, 1, true, false)]
    #[test_case(1, 1, false, false)]
    #[test_case(1, 1, false, true)]
    #[test_case(2, 2, true, true)]
    #[test_case(2, 2, true, false)]
    #[test_case(2, 2, false, false)]
    #[test_case(2, 2, false, true)]
    #[test_case(3, 3, true, true)]
    #[test_case(3, 3, true, false)]
    #[test_case(3, 3, false, false)]
    #[test_case(3, 3, false, true)]
    fn test_absorb_less_than_trove_debt(
        threshold_idx: usize, target_ltvs_idx: usize, is_recovery_mode: bool, kill_absorber: bool,
    ) {
        let classes = Option::Some(purger_utils::declare_contracts());

        let threshold: Ray = *purger_utils::interesting_thresholds_for_absorption_below_trove_debt().at(threshold_idx);
        let mut target_ltvs: Span<Ray> =
            *purger_utils::ltvs_for_interesting_thresholds_for_absorption_below_trove_debt()
            .at(target_ltvs_idx);

        for target_ltv in target_ltvs {
            let PurgerTestConfig {
                shrine, abbot, seer, absorber, purger, yangs, gates,
            } = purger_utils::purger_deploy(classes);
            let mut spy = spy_events();

            // Set thresholds to provided value
            purger_utils::set_thresholds(shrine, yangs, threshold);

            let trove_debt: Wad = (purger_utils::TARGET_TROVE_YIN * 5).into();
            let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, trove_debt);

            // Accrue some interest
            common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);

            let target_trove_start_health: Health = shrine.get_trove_health(target_trove);

            // Fund the absorber with twice the target trove's debt
            let absorber_start_yin: Wad = (target_trove_start_health.debt.into() * 2_u128).into();
            purger_utils::funded_absorber(shrine, abbot, absorber, yangs, gates, absorber_start_yin);

            // sanity check
            assert(shrine.get_yin(absorber.contract_address) > target_trove_start_health.debt, 'not full absorption');

            // Make the target trove absorbable
            purger_utils::lower_prices_to_raise_trove_ltv(
                shrine, seer, yangs, target_trove_start_health.value, target_trove_start_health.debt, *target_ltv,
            );

            if is_recovery_mode {
                purger_utils::trigger_recovery_mode(shrine, seer, yangs, common::RecoveryModeSetupType::ExceedsBuffer);
            } else {
                assert(!shrine.is_recovery_mode(), 'recovery mode');
            }

            let mut target_trove_updated_start_health: Health = shrine.get_trove_health(target_trove);

            purger_utils::assert_trove_is_absorbable(shrine, purger, target_trove, target_trove_updated_start_health);

            if kill_absorber {
                absorber_utils::kill_absorber(absorber);
                assert(!absorber.get_live(), 'sanity check');
            }

            let (penalty, max_close_amt, expected_compensation_value) = purger
                .preview_absorb(target_trove)
                .expect('Should be absorbable');

            if !is_recovery_mode {
                assert(max_close_amt < target_trove_updated_start_health.debt, 'close amount == debt');
            }

            let caller: ContractAddress = common::NON_ZERO_ADDR;
            start_cheat_caller_address(purger.contract_address, caller);
            let compensation: Span<AssetBalance> = purger.absorb(target_trove);

            // Check that LTV is close to safety margin
            let target_trove_after_health: Health = shrine.get_trove_health(target_trove);
            assert(
                target_trove_after_health.debt == target_trove_updated_start_health.debt - max_close_amt,
                'wrong debt after liquidation',
            );

            // Perform this check only if close amount is less than
            // trove's debt. Close amount may be equal to trove's debt
            // after recovery mode is triggered.
            if max_close_amt != target_trove_updated_start_health.debt {
                purger_utils::assert_ltv_at_safety_margin(
                    target_trove_updated_start_health.threshold, target_trove_after_health.ltv, Option::None,
                );
            }

            let (expected_freed_pct, expected_freed_amts) = purger_utils::get_expected_liquidation_assets(
                purger_utils::target_trove_yang_asset_amts(),
                target_trove_updated_start_health,
                max_close_amt,
                penalty,
                Option::Some(expected_compensation_value),
            );
            let expected_freed_assets: Span<AssetBalance> = common::combine_assets_and_amts(yangs, expected_freed_amts);

            let mut purger_events = spy.get_events().emitted_by(purger.contract_address).events;

            let (_, raw_purged_event) = purger_events.pop_front().unwrap();
            let purged_event = purger_utils::deserialize_purged_event(raw_purged_event);

            common::assert_asset_balances_equalish(
                purged_event.freed_assets, expected_freed_assets, 1000_u128, 'wrong freed assets for event',
            );
            assert(purged_event.trove_id == target_trove, 'wrong Purged trove ID');
            assert(purged_event.purge_amt == max_close_amt, 'wrong Purged amt');
            common::assert_equalish(
                purged_event.percentage_freed, expected_freed_pct, 1000000_u128.into(), 'wrong Purged freed pct',
            );
            assert(purged_event.funder == absorber.contract_address, 'wrong Purged funder');
            assert(purged_event.recipient == absorber.contract_address, 'wrong Purged recipient');

            let expected_events = array![
                (
                    purger.contract_address,
                    purger_contract::Event::Compensate(purger_contract::Compensate { recipient: caller, compensation }),
                ),
            ];
            spy.assert_emitted(@expected_events);

            shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
        };
    }

    // This test parametrizes over thresholds (by setting all yangs thresholds to the given value)
    // and the LTV at liquidation, and checks that the trove's debt is absorbed in full for thresholds
    // from 78.74% onwards.
    #[test]
    #[test_case(0, 0, 0, false, false)]
    #[test_case(0, 0, 0, false, true)]
    #[test_case(0, 0, 0, true, false)]
    #[test_case(0, 0, 0, true, true)]
    #[test_case(1, 1, 1, false, false)]
    #[test_case(1, 1, 1, false, true)]
    #[test_case(1, 1, 1, true, false)]
    #[test_case(1, 1, 1, true, true)]
    #[test_case(2, 2, 2, false, false)]
    #[test_case(2, 2, 2, false, true)]
    #[test_case(2, 2, 2, true, false)]
    #[test_case(2, 2, 2, true, true)]
    #[test_case(3, 3, 3, false, false)]
    #[test_case(3, 3, 3, false, true)]
    #[test_case(3, 3, 3, true, false)]
    #[test_case(3, 3, 3, true, true)]
    #[test_case(4, 4, 4, false, false)]
    #[test_case(4, 4, 4, false, true)]
    #[test_case(4, 4, 4, true, false)]
    #[test_case(4, 4, 4, true, true)]
    #[test_case(5, 5, 5, false, false)]
    #[test_case(5, 5, 5, false, true)]
    #[test_case(5, 5, 5, true, false)]
    #[test_case(5, 5, 5, true, true)]
    fn test_absorb_trove_debt(
        threshold_idx: usize,
        target_ltvs_idx: usize,
        expected_penalty_idx: usize,
        is_recovery_mode: bool,
        kill_absorber: bool,
    ) {
        let classes = Option::Some(purger_utils::declare_contracts());

        let threshold: Ray = *purger_utils::interesting_thresholds_for_absorption_entire_trove_debt().at(threshold_idx);
        let mut target_ltvs: Span<Ray> =
            *purger_utils::ltvs_for_interesting_thresholds_for_absorption_entire_trove_debt()
            .at(target_ltvs_idx);
        let expected_penalty: Ray = *purger_utils::absorb_trove_debt_test_expected_penalties().at(expected_penalty_idx);

        let ninety_nine_pct: Ray = (RAY_ONE - RAY_PERCENT).into();
        for target_ltv in target_ltvs.pop_front() {
            let PurgerTestConfig {
                shrine, abbot, seer, absorber, purger, yangs, gates,
            } = purger_utils::purger_deploy(classes);
            let mut spy = spy_events();

            // Set thresholds to provided value
            purger_utils::set_thresholds(shrine, yangs, threshold);

            let trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
            let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, trove_debt);

            // Accrue some interest
            common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);

            let target_trove_start_health: Health = shrine.get_trove_health(target_trove);

            // Fund the absorber with twice the target trove's debt
            let absorber_start_yin: Wad = (target_trove_start_health.debt.into() * 2_u128).into();
            purger_utils::funded_absorber(shrine, abbot, absorber, yangs, gates, absorber_start_yin);

            // sanity check
            assert(shrine.get_yin(absorber.contract_address) > target_trove_start_health.debt, 'not full absorption');

            // Make the target trove absorbable
            purger_utils::lower_prices_to_raise_trove_ltv(
                shrine, seer, yangs, target_trove_start_health.value, target_trove_start_health.debt, *target_ltv,
            );

            let mut target_trove_updated_start_health: Health = shrine.get_trove_health(target_trove);

            if is_recovery_mode {
                purger_utils::trigger_recovery_mode(shrine, seer, yangs, common::RecoveryModeSetupType::ExceedsBuffer);
                target_trove_updated_start_health = shrine.get_trove_health(target_trove);
            } else {
                assert(!shrine.is_recovery_mode(), 'recovery mode');
            }

            purger_utils::assert_trove_is_absorbable(shrine, purger, target_trove, target_trove_updated_start_health);

            if kill_absorber {
                absorber_utils::kill_absorber(absorber);
                assert(!absorber.get_live(), 'sanity check');
            }

            let (penalty, max_close_amt, expected_compensation_value) = purger
                .preview_absorb(target_trove)
                .expect('Should be absorbable');
            assert(max_close_amt == target_trove_updated_start_health.debt, 'close amount != debt');
            if *target_ltv >= ninety_nine_pct {
                assert(penalty.is_zero(), 'wrong penalty');
            } else {
                let error_margin: Ray = (RAY_PERCENT / 10).into(); // 0.1%
                if is_recovery_mode {
                    if expected_penalty.is_zero() {
                        assert_eq!(penalty, expected_penalty, "wrong rm penalty #1");
                    } else {
                        assert(penalty < expected_penalty - error_margin, 'wrong rm penalty #2');
                    }
                } else {
                    common::assert_equalish(penalty, expected_penalty, error_margin, 'wrong penalty');
                }
            }

            let caller: ContractAddress = common::NON_ZERO_ADDR;
            start_cheat_caller_address(purger.contract_address, caller);
            let compensation: Span<AssetBalance> = purger.absorb(target_trove);

            let target_trove_after_health: Health = shrine.get_trove_health(target_trove);
            assert(target_trove_after_health.ltv.is_zero(), 'wrong LTV after liquidation');
            assert(target_trove_after_health.value.is_zero(), 'wrong value after liquidation');
            assert(target_trove_after_health.debt.is_zero(), 'wrong debt after liquidation');

            let target_trove_yang_asset_amts: Span<u128> = purger_utils::target_trove_yang_asset_amts();
            let (_, expected_freed_asset_amts) = purger_utils::get_expected_liquidation_assets(
                target_trove_yang_asset_amts,
                target_trove_updated_start_health,
                max_close_amt,
                penalty,
                Option::Some(expected_compensation_value),
            );

            let expected_freed_assets: Span<AssetBalance> = common::combine_assets_and_amts(
                yangs, expected_freed_asset_amts,
            );

            let mut purger_events = spy.get_events().emitted_by(purger.contract_address).events;

            let (_, raw_purged_event) = purger_events.pop_front().unwrap();
            let purged_event = purger_utils::deserialize_purged_event(raw_purged_event);

            assert(purged_event.trove_id == target_trove, 'wrong Purged trove ID');
            assert(purged_event.purge_amt == max_close_amt, 'wrong Purged amt');
            assert(purged_event.percentage_freed == RAY_ONE.into(), 'wrong Purged freed pct');
            assert(purged_event.funder == absorber.contract_address, 'wrong Purged funder');
            assert(purged_event.recipient == absorber.contract_address, 'wrong Purged recipient');
            common::assert_asset_balances_equalish(
                purged_event.freed_assets, expected_freed_assets, 100000_u128, 'wrong freed assets for event',
            );

            let expected_events = array![
                (
                    purger.contract_address,
                    purger_contract::Event::Compensate(purger_contract::Compensate { recipient: caller, compensation }),
                ),
            ];
            spy.assert_emitted(@expected_events);

            shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
        };
    }

    #[test]
    #[should_panic(expected: 'PU: Not absorbable')]
    fn test_absorb_trove_healthy_fail() {
        let PurgerTestConfig {
            shrine, abbot, absorber, purger, yangs, gates, ..,
        } = purger_utils::purger_deploy_with_searcher(purger_utils::SEARCHER_YIN.into(), Option::None);

        let trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
        let healthy_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, trove_debt);

        purger_utils::funded_absorber(shrine, abbot, absorber, yangs, gates, trove_debt);

        purger_utils::assert_trove_is_healthy(shrine, purger, healthy_trove, shrine.get_trove_health(healthy_trove));

        start_cheat_caller_address(purger.contract_address, common::NON_ZERO_ADDR);
        purger.absorb(healthy_trove);
    }

    #[test]
    #[should_panic(expected: 'PU: Not absorbable')]
    fn test_absorb_below_absorbable_ltv_fail() {
        let PurgerTestConfig {
            shrine, abbot, seer, absorber, purger, yangs, gates,
        } = purger_utils::purger_deploy_with_searcher(purger_utils::SEARCHER_YIN.into(), Option::None);

        purger_utils::create_whale_trove(abbot, yangs, gates);

        let trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
        let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, trove_debt);
        purger_utils::funded_absorber(shrine, abbot, absorber, yangs, gates, trove_debt);

        let target_trove_health: Health = shrine.get_trove_health(target_trove);
        let target_ltv: Ray = target_trove_health.threshold + RAY_PERCENT.into();
        purger_utils::lower_prices_to_raise_trove_ltv(
            shrine, seer, yangs, target_trove_health.value, target_trove_health.debt, target_ltv,
        );

        let updated_target_trove_health: Health = shrine.get_trove_health(target_trove);
        purger_utils::assert_trove_is_liquidatable(shrine, purger, target_trove, updated_target_trove_health);
        purger_utils::assert_trove_is_not_absorbable(purger, target_trove);

        start_cheat_caller_address(purger.contract_address, common::NON_ZERO_ADDR);
        purger.absorb(target_trove);
    }

    // For thresholds < 90%, check that the LTV at which the trove is absorbable minus
    // 0.01% is not absorbable.
    #[test]
    fn test_absorb_marginally_below_absorbable_ltv_not_absorbable() {
        let classes = Option::Some(purger_utils::declare_contracts());

        let (mut thresholds, mut target_ltvs) = purger_utils::interesting_thresholds_and_ltvs_below_absorption_ltv();

        for threshold in thresholds {
            let searcher_start_yin: Wad = purger_utils::SEARCHER_YIN.into();
            let PurgerTestConfig {
                shrine, abbot, seer, absorber, purger, yangs, gates,
            } = purger_utils::purger_deploy_with_searcher(searcher_start_yin, classes);

            purger_utils::create_whale_trove(abbot, yangs, gates);

            // Set thresholds to provided value
            purger_utils::set_thresholds(shrine, yangs, *threshold);

            let trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
            let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, trove_debt);

            // Accrue some interest
            common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);

            let target_trove_start_health: Health = shrine.get_trove_health(target_trove);

            // Fund the absorber with twice the target trove's debt
            let absorber_start_yin: Wad = (target_trove_start_health.debt.into() * 2_u128).into();
            purger_utils::funded_absorber(shrine, abbot, absorber, yangs, gates, absorber_start_yin);

            // Adjust the trove to the target LTV
            purger_utils::lower_prices_to_raise_trove_ltv(
                shrine,
                seer,
                yangs,
                target_trove_start_health.value,
                target_trove_start_health.debt,
                *target_ltvs.pop_front().unwrap(),
            );

            let updated_target_trove_start_health: Health = shrine.get_trove_health(target_trove);
            purger_utils::assert_trove_is_liquidatable(shrine, purger, target_trove, updated_target_trove_start_health);
            purger_utils::assert_trove_is_not_absorbable(purger, target_trove);
        };
    }

    #[test]
    fn test_liquidate_suspended_yang() {
        let PurgerTestConfig {
            shrine, abbot, purger, yangs, gates, ..,
        } = purger_utils::purger_deploy_with_searcher(purger_utils::SEARCHER_YIN.into(), Option::None);

        // user 1 opens a trove with ETH and BTC that is close to liquidation
        // `funded_healthy_trove` supplies 2 ETH and 0.5 BTC totalling $9000 in value, so we
        // create $6000 of debt to ensure the trove is closer to liquidation
        let trove_debt: Wad = (6000 * WAD_ONE).into();
        let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, trove_debt);

        // Suspend BTC
        let btc: ContractAddress = *yangs[1];
        let current_timestamp: u64 = get_block_timestamp();

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.suspend_yang(btc);
        stop_cheat_caller_address(shrine.contract_address);

        // The trove has $6000 in debt and $9000 in collateral. BTC's value must decrease
        let target_trove_start_health: Health = shrine.get_trove_health(target_trove);
        assert(target_trove_start_health.is_healthy(), 'should still be healthy');

        let eth_threshold: Ray = shrine_utils::YANG1_THRESHOLD.into();
        let btc_threshold: Ray = shrine_utils::YANG2_THRESHOLD.into();

        let (eth_price, _, _) = shrine.get_current_yang_price(*yangs[0]);
        let (btc_price, _, _) = shrine.get_current_yang_price(*yangs[1]);

        let eth_value: Wad = eth_price * shrine.get_deposit(*yangs[0], target_trove);
        let btc_value: Wad = btc_price * shrine.get_deposit(*yangs[1], target_trove);

        // These represent the percentages of the total value of the trove each
        // of the yangs respectively make up
        let eth_weight: Ray = wadray::rdiv_ww(eth_value, target_trove_start_health.value);
        let btc_weight: Ray = wadray::rdiv_ww(btc_value, target_trove_start_health.value);

        // We need to decrease BTC's threshold until the trove threshold equals `ltv`
        // we derive the decrease factor from the following equation:
        //
        // NOTE: decrease factor is the value which, if we multiply BTC's threshold by it, will give us
        // the threshold BTC must have in order for the trove's threshold to equal its LTV
        //
        // (eth_value / total_value) * eth_threshold + (btc_value / total_value) * btc_threshold * decrease_factor = ltv
        // eth_weight * eth_threshold + btc_weight * btc_threshold * decrease_factor = ltv
        // btc_weight * btc_threshold * decrease_factor = ltv - eth_weight * eth_threshold
        // decrease_factor = (ltv - eth_weight * eth_threshold) / (btc_weight * btc_threshold)
        let btc_threshold_decrease_factor: Ray = (target_trove_start_health.ltv - eth_weight * eth_threshold)
            / (btc_weight * btc_threshold);
        let ts_diff: u64 = shrine_contract::SUSPENSION_GRACE_PERIOD
            - scale_u128_by_ray(shrine_contract::SUSPENSION_GRACE_PERIOD.into(), btc_threshold_decrease_factor)
                .try_into()
                .unwrap();

        shrine_utils::advance_prices_periodically(shrine, yangs, ts_diff);

        // Adding one to offset any precision loss
        let new_timestamp: u64 = current_timestamp + ts_diff + 1;
        start_cheat_block_timestamp_global(new_timestamp);

        assert(!shrine.is_healthy(target_trove), 'should be unhealthy');

        // Liquidate the trove
        let searcher = purger_utils::SEARCHER;
        start_cheat_caller_address(purger.contract_address, searcher);
        purger.liquidate(target_trove, target_trove_start_health.debt, searcher);

        // Sanity checks
        let target_trove_after_health: Health = shrine.get_trove_health(target_trove);

        assert(target_trove_after_health.debt < target_trove_start_health.debt, 'trove not correctly liquidated');

        assert(
            shrine_utils::yin(shrine.contract_address)
                .balance_of(searcher)
                .try_into()
                .unwrap() < purger_utils::SEARCHER_YIN,
            'searcher yin not used',
        );

        purger_utils::assert_ltv_at_safety_margin(
            target_trove_after_health.threshold, target_trove_after_health.ltv, Option::None,
        );
    }

    #[test]
    #[test_case((50 * RAY_PERCENT).into(), true, true)]
    #[test_case((50 * RAY_PERCENT).into(), true, false)]
    #[test_case((50 * RAY_PERCENT).into(), false, true)]
    #[test_case((50 * RAY_PERCENT).into(), false, false)]
    // The minimum LTV for absorption at 1% threshold is approximately 1.097%, so it is rounded
    // up to 1.1% for convenience to ensure the target trove is absorbable after adjusting the
    // threshold to the desired value.
    #[test_case((RAY_PERCENT + RAY_PERCENT / 10).into(), true, true)]
    #[test_case((RAY_PERCENT + RAY_PERCENT / 10).into(), true, false)]
    #[test_case((RAY_PERCENT + RAY_PERCENT / 10).into(), false, true)]
    #[test_case((RAY_PERCENT + RAY_PERCENT / 10).into(), false, false)]
    fn test_liquidate_suspended_yang_threshold_near_zero(
        starting_ltv: Ray, liquidate_via_absorption: bool, is_recovery_mode: bool,
    ) {
        let PurgerTestConfig {
            shrine, abbot, seer, absorber, purger, yangs, gates,
        } = purger_utils::purger_deploy_with_searcher(purger_utils::SEARCHER_YIN.into(), Option::None);

        // We also parametrize the test with the desired threshold for liquidation
        let mut desired_threshold_params: Span<Ray> = array![
            RAY_PERCENT.into(),
            (RAY_PERCENT / 4).into(),
            // This is the smallest possible desired threshold that
            // doesn't result in advancing the time enough to make
            // the suspension permanent
            (RAY_ONE + 1).into() / (RAY_ONE * shrine_contract::SUSPENSION_GRACE_PERIOD.into()).into(),
        ]
            .span();

        let eth: ContractAddress = *yangs[0];
        let eth_gate: IGateDispatcher = *gates[0];
        let eth_amt: u128 = WAD_ONE;
        let eth_threshold: Ray = shrine_utils::YANG1_THRESHOLD.into();

        let target_user: ContractAddress = purger_utils::TARGET_TROVE_OWNER;
        common::fund_user(target_user, array![eth].span(), array![10 * eth_amt].span());

        // Have the searcher provide half of his yin to the absorber
        let searcher = purger_utils::SEARCHER;
        let searcher_yin: Wad = (purger_utils::SEARCHER_YIN / 2).into();
        let yin_erc20 = shrine_utils::yin(shrine.contract_address);

        start_cheat_caller_address(shrine.contract_address, searcher);
        yin_erc20.approve(absorber.contract_address, searcher_yin.into());
        stop_cheat_caller_address(shrine.contract_address);

        start_cheat_caller_address(absorber.contract_address, searcher);
        absorber.provide(searcher_yin);
        stop_cheat_caller_address(absorber.contract_address);

        // Create a whale trove to prevent recovery mode from being triggered due to
        // the lowered threshold from suspension
        purger_utils::create_whale_trove(abbot, yangs, gates);

        for desired_threshold in desired_threshold_params {
            let (eth_price, _, _) = shrine.get_current_yang_price(eth);
            let forge_amt: Wad = wadray::rmul_wr(eth_amt.into() * eth_price, starting_ltv);
            let target_trove: u64 = common::open_trove_helper(
                abbot, target_user, array![eth].span(), array![eth_amt].span(), array![eth_gate].span(), forge_amt,
            );

            // Suspend ETH
            start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
            shrine.suspend_yang(eth);
            stop_cheat_caller_address(shrine.contract_address);

            // Advance the time stamp such that the ETH threshold falls to `desired_threshold`
            let decrease_factor: Ray = *desired_threshold / eth_threshold;
            let ts_diff: u64 = shrine_contract::SUSPENSION_GRACE_PERIOD
                - scale_u128_by_ray(shrine_contract::SUSPENSION_GRACE_PERIOD.into(), decrease_factor)
                    .try_into()
                    .unwrap();

            shrine_utils::advance_prices_periodically(shrine, yangs, ts_diff);

            // Check that the threshold has decreased to the desired value
            // The trove's threshold is equivalent to ETH's threshold since it
            // has deposited only ETH.
            let threshold_before_liquidation = shrine.get_trove_health(target_trove).threshold;

            common::assert_equalish(
                threshold_before_liquidation,
                *desired_threshold,
                // 0.0000001 = 10^-7 (ray). Precision
                // is limited by the precision of timestamps,
                // which is only in seconds
                100000000000000000000_u128.into(),
                'wrong eth threshold',
            );

            // We want to compare the yin balance of the liquidator
            // before and after the liquidation. In the case of absorption
            // we check the absorber's balance, and in the case of
            // searcher liquidation we check the searcher's balance.
            let before_liquidation_yin_balance: u256 = if liquidate_via_absorption {
                yin_erc20.balance_of(absorber.contract_address)
            } else {
                yin_erc20.balance_of(searcher)
            };

            let in_recovery_mode: bool = shrine.is_recovery_mode();
            if is_recovery_mode {
                if !in_recovery_mode {
                    purger_utils::trigger_recovery_mode(
                        shrine, seer, yangs, common::RecoveryModeSetupType::ExceedsBuffer,
                    );
                }
            } else {
                assert(!in_recovery_mode, 'in recovery mode');
            }

            // Liquidate the trove
            start_cheat_caller_address(purger.contract_address, searcher);

            if liquidate_via_absorption {
                purger.absorb(target_trove);
            } else {
                // Get the updated debt with accrued interest
                let before_liquidation_health: Health = shrine.get_trove_health(target_trove);
                purger.liquidate(target_trove, before_liquidation_health.debt, searcher);
            }

            // Sanity checks
            let target_trove_after_health: Health = shrine.get_trove_health(target_trove);

            assert(target_trove_after_health.debt < forge_amt, 'trove not correctly liquidated');

            // Checking that the liquidator's yin balance has decreased
            // after liquidation
            if liquidate_via_absorption {
                assert(
                    yin_erc20.balance_of(absorber.contract_address) < before_liquidation_yin_balance,
                    'absorber yin not used',
                );
            } else {
                assert(yin_erc20.balance_of(searcher) < before_liquidation_yin_balance, 'searcher yin not used');
            }

            start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
            shrine.unsuspend_yang(eth);
            stop_cheat_caller_address(shrine.contract_address);
        };
    }

    #[derive(Copy, Drop, PartialEq)]
    enum AbsorbType {
        Full,
        Partial,
        None,
    }

    #[test]
    #[test_case(name: "full_1", AbsorbType::Full, true)]
    #[test_case(name: "full_2", AbsorbType::Full, false)]
    #[test_case(name: "partial_1", AbsorbType::Partial, true)]
    #[test_case(name: "partial_2", AbsorbType::Partial, false)]
    #[test_case(name: "none_1", AbsorbType::None, true)]
    #[test_case(name: "none_2", AbsorbType::None, false)]
    fn test_absorb_low_thresholds(absorb_type: AbsorbType, is_recovery_mode: bool) {
        let classes = Option::Some(purger_utils::declare_contracts());

        let searcher = purger_utils::SEARCHER;
        let searcher_start_yin: Wad = (purger_utils::SEARCHER_YIN * 6).into();

        let minimum_operational_shares: Wad = (absorber_contract::INITIAL_SHARES
            + absorber_contract::MINIMUM_RECIPIENT_SHARES)
            .into();

        // Parameters
        let thresholds_param: Span<Ray> = array![Zero::zero(), RAY_PERCENT.into()].span();

        for threshold in thresholds_param {
            let target_ltvs_param: Span<Ray> = array![*threshold + 1_u128.into(), *threshold + (RAY_ONE / 2).into()]
                .span();

            for target_ltv in target_ltvs_param {
                let PurgerTestConfig {
                    shrine, abbot, absorber, purger, yangs, gates, ..,
                } = purger_utils::purger_deploy_with_searcher(searcher_start_yin, classes);

                start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
                shrine.set_debt_ceiling((10000000 * WAD_ONE).into());
                stop_cheat_caller_address(shrine.contract_address);

                // Create whale trove to either:
                // - mint enough debt to trigger recovery mode before thresholds are set to a very low
                // value; or - to prevent recovery mode from being triggered
                let whale_trove_owner: ContractAddress = purger_utils::TARGET_TROVE_OWNER;
                let whale_trove: u64 = purger_utils::create_whale_trove(abbot, yangs, gates);

                // Approve absorber for maximum yin
                start_cheat_caller_address(shrine.contract_address, searcher);
                let yin_erc20 = shrine_utils::yin(shrine.contract_address);
                yin_erc20.approve(absorber.contract_address, Bounded::MAX);

                stop_cheat_caller_address(shrine.contract_address);

                // Calculating the `trove_debt` necessary to achieve
                // the `target_ltv`
                let target_trove_yang_amts: Span<Wad> = array![
                    (*gates[0]).convert_to_yang(purger_utils::TARGET_TROVE_ETH_DEPOSIT_AMT),
                    (*gates[1]).convert_to_yang(purger_utils::TARGET_TROVE_WBTC_DEPOSIT_AMT),
                ]
                    .span();

                let trove_value: Wad = purger_utils::get_sum_of_value(shrine, yangs, target_trove_yang_amts);

                // In case of rounding down to zero, set to 1 wei.
                let trove_debt: Wad = max(
                    wadray::rmul_wr(trove_value, *target_ltv) + (100 * WAD_ONE).into(), 1_u128.into(),
                );

                // We skip test cases of partial liquidations where
                // the trove debt is less than the minimum shares required for the
                // absorber to be operational.
                if absorb_type == AbsorbType::Partial
                    && trove_debt <= (absorber_contract::INITIAL_SHARES + absorber_contract::MINIMUM_RECIPIENT_SHARES)
                        .into() {
                    continue;
                }

                // Resetting the thresholds to reasonable values
                // to allow for creating troves at higher LTVs
                purger_utils::set_thresholds(shrine, yangs, (80 * RAY_PERCENT).into());

                // Creating the trove to be liquidated
                let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, trove_debt);

                // Now, the searcher deposits some yin into the absorber
                // The amount depends on whether we want a full or partial absorption, or
                // a full redistribution

                start_cheat_caller_address(absorber.contract_address, searcher);

                match absorb_type {
                    AbsorbType::Full => { absorber.provide(max(trove_debt, minimum_operational_shares)); },
                    AbsorbType::Partial => {
                        // We provide *at least* the minimum shares
                        absorber.provide(max((trove_debt.into() / 2_u128).into(), minimum_operational_shares));
                    },
                    AbsorbType::None => {},
                }

                stop_cheat_caller_address(absorber.contract_address);

                if is_recovery_mode {
                    // Mint the desired threshold + 1% worth of the max forge amount of the whale trove
                    // to guarantee that the whale trove will exceed its threshold when thresholds are
                    // lowered in the next step
                    let max_forge_amt: Wad = shrine.get_max_forge(whale_trove);
                    let forge_amt: Wad = wadray::rmul_wr(max_forge_amt, *threshold + RAY_PERCENT.into());

                    start_cheat_caller_address(abbot.contract_address, whale_trove_owner);
                    abbot.forge(whale_trove, forge_amt, Zero::zero());
                    stop_cheat_caller_address(abbot.contract_address);
                }

                // Setting the threshold to the desired value
                // the target trove is now absorbable
                purger_utils::set_thresholds(shrine, yangs, *threshold);

                let target_trove_start_health: Health = shrine.get_trove_health(target_trove);
                if is_recovery_mode && (*threshold).is_non_zero() {
                    assert(shrine.is_recovery_mode(), 'not recovery mode');
                } else if (*threshold).is_non_zero() {
                    // skip zero threshold because recovery mode
                    // is unavoidable
                    assert(!shrine.is_recovery_mode(), 'recovery mode');
                }

                let (penalty, max_close_amt, expected_compensation_value) = purger
                    .preview_absorb(target_trove)
                    .expect('Should be absorbable');

                start_cheat_caller_address(purger.contract_address, searcher);

                let absorber_eth_bal_before_absorb: u128 = IERC20Dispatcher { contract_address: *yangs[0] }
                    .balance_of(absorber.contract_address)
                    .try_into()
                    .unwrap();
                let absorber_wbtc_bal_before_absorb: u128 = IERC20Dispatcher { contract_address: *yangs[1] }
                    .balance_of(absorber.contract_address)
                    .try_into()
                    .unwrap();

                let absorber_yin_bal_before_absorb: Wad = yin_erc20
                    .balance_of(absorber.contract_address)
                    .try_into()
                    .unwrap();

                let compensation: Span<AssetBalance> = purger.absorb(target_trove);

                // Checking that the compensation is correct
                let actual_eth_comp: AssetBalance = *compensation[0];
                let actual_wbtc_comp: AssetBalance = *compensation[1];

                let expected_compensation_pct: Ray = wadray::rdiv_ww(
                    purger_contract::COMPENSATION_CAP.into(), target_trove_start_health.value,
                );

                let expected_eth_comp: u128 = scale_u128_by_ray(
                    purger_utils::TARGET_TROVE_ETH_DEPOSIT_AMT, expected_compensation_pct,
                );

                let expected_wbtc_comp: u128 = scale_u128_by_ray(
                    purger_utils::TARGET_TROVE_WBTC_DEPOSIT_AMT, expected_compensation_pct,
                );

                common::assert_equalish(expected_eth_comp, actual_eth_comp.amount, 1_u128, 'wrong eth compensation');

                common::assert_equalish(expected_wbtc_comp, actual_wbtc_comp.amount, 1_u128, 'wrong wbtc compensation');

                let actual_compensation_value: Wad = purger_utils::get_sum_of_value(
                    shrine,
                    yangs,
                    array![
                        (*gates[0]).convert_to_yang(actual_eth_comp.amount),
                        (*gates[1]).convert_to_yang(actual_wbtc_comp.amount),
                    ]
                        .span(),
                );

                common::assert_equalish(
                    expected_compensation_value,
                    actual_compensation_value,
                    10000000000000000_u128.into(),
                    'wrong compensation value',
                );

                // If the trove wasn't fully liquidated, check
                // that it is healthy
                if max_close_amt < trove_debt {
                    assert(shrine.is_healthy(target_trove), 'trove should be healthy');
                }

                // Checking that the absorbed assets are equal in value to the
                // debt liquidated, plus the penalty
                if absorb_type != AbsorbType::None {
                    // We subtract the absorber balance before the liquidation
                    //  in order to avoid including any leftover
                    // absorbed assets from previous liquidations
                    // in the calculation for the value of the
                    // absorption that *just* occured

                    let absorbed_eth: Wad = common::get_erc20_bal_as_yang(
                        *gates[0], *yangs[0], absorber.contract_address,
                    )
                        - (*gates[0]).convert_to_yang(absorber_eth_bal_before_absorb);
                    let absorbed_wbtc: Wad = common::get_erc20_bal_as_yang(
                        *gates[1], *yangs[1], absorber.contract_address,
                    )
                        - (*gates[1]).convert_to_yang(absorber_wbtc_bal_before_absorb);

                    let (current_eth_yang_price, _, _) = shrine.get_current_yang_price(*yangs[0]);
                    let (current_wbtc_yang_price, _, _) = shrine.get_current_yang_price(*yangs[1]);

                    let absorber_eth_value: Wad = absorbed_eth * current_eth_yang_price;
                    let absorber_wbtc_value: Wad = absorbed_wbtc * current_wbtc_yang_price;

                    let absorbed_assets_value = absorber_eth_value + absorber_wbtc_value;

                    let max_absorb_amt = min(max_close_amt, absorber_yin_bal_before_absorb);

                    let expected_absorbed_value: Wad = wadray::rmul_wr(max_absorb_amt, (RAY_ONE.into() + penalty));

                    common::assert_equalish(
                        absorbed_assets_value,
                        expected_absorbed_value,
                        (2 * WAD_ONE).into(),
                        'wrong absorbed assets value',
                    );
                }
            };
        };
    }
}
