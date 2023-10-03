mod TestPurger {
    use starknet::ContractAddress;
    use starknet::testing::set_contract_address;

    use opus::core::absorber::Absorber;
    use opus::core::purger::Purger;
    use opus::core::roles::PurgerRoles;
    use opus::core::shrine::Shrine;

    use opus::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::interfaces::IAbsorber::{IAbsorberDispatcher, IAbsorberDispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::IPurger::{IPurgerDispatcher, IPurgerDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::types::AssetBalance;
    use opus::utils::wadray;
    use opus::utils::wadray::{BoundedWad, Ray, RayZeroable, RAY_ONE, RAY_PERCENT, Wad, WAD_ONE};

    use opus::tests::absorber::utils::AbsorberUtils;
    use opus::tests::common;
    use opus::tests::external::utils::PragmaUtils;
    use opus::tests::flashmint::utils::FlashmintUtils;
    use opus::tests::purger::flash_liquidator::{
        IFlashLiquidatorDispatcher, IFlashLiquidatorDispatcherTrait
    };
    use opus::tests::purger::utils::PurgerUtils;
    use opus::tests::shrine::utils::ShrineUtils;

    use debug::PrintTrait;

    //
    // Tests - Setup
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_purger_setup() {
        let (_, _, _, _, purger, _, _) = PurgerUtils::purger_deploy();
        let purger_ac = IAccessControlDispatcher { contract_address: purger.contract_address };
        assert(
            purger_ac.get_roles(PurgerUtils::admin()) == PurgerRoles::default_admin_role(),
            'wrong role for admin'
        );

        let mut expected_events: Span<Purger::Event> = array![
            Purger::Event::PenaltyScalarUpdated(
                Purger::PenaltyScalarUpdated { new_scalar: RAY_ONE.into(), }
            ),
        ]
            .span();
        common::assert_events_emitted(purger.contract_address, expected_events, Option::None);
    }

    //
    // Tests - Setters
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_set_penalty_scalar_pass() {
        let (shrine, abbot, mock_pragma, _, purger, yangs, gates) = PurgerUtils::purger_deploy();
        let yang_pair_ids = PragmaUtils::yang_pair_ids();

        PurgerUtils::create_whale_trove(abbot, yangs, gates);

        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        // Set thresholds to 91% so we can check the scalar is applied to the penalty
        let threshold: Ray = (91 * RAY_PERCENT).into();
        PurgerUtils::set_thresholds(shrine, yangs, threshold);

        let (_, _, value, debt) = shrine.get_trove_info(target_trove);
        let target_ltv: Ray = threshold + RAY_PERCENT.into(); // 92%
        PurgerUtils::adjust_prices_for_trove_ltv(
            shrine, mock_pragma, yangs, yang_pair_ids, value, debt, target_ltv
        );

        // sanity check that LTV is at the target liquidation LTV
        let (_, ltv, _, _) = shrine.get_trove_info(target_trove);
        let error_margin: Ray = 2000000_u128.into();
        common::assert_equalish(ltv, target_ltv, error_margin, 'LTV sanity check');

        common::drop_all_events(purger.contract_address);

        let mut expected_events: Array<Purger::Event> = ArrayTrait::new();

        // Set scalar to 1
        set_contract_address(PurgerUtils::admin());
        let penalty_scalar: Ray = RAY_ONE.into();
        purger.set_penalty_scalar(penalty_scalar);

        assert(purger.get_penalty_scalar() == penalty_scalar, 'wrong penalty scalar #1');

        let (penalty, _, _) = purger.preview_absorb(target_trove);
        let expected_penalty: Ray = 41000000000000000000000000_u128.into(); // 4.1%
        let error_margin: Ray = (RAY_PERCENT / 100).into(); // 0.01%
        common::assert_equalish(penalty, expected_penalty, error_margin, 'wrong scalar penalty #1');

        expected_events
            .append(
                Purger::Event::PenaltyScalarUpdated(
                    Purger::PenaltyScalarUpdated { new_scalar: penalty_scalar, }
                )
            );

        // Set scalar to 0.97
        let penalty_scalar: Ray = Purger::MIN_PENALTY_SCALAR.into();
        purger.set_penalty_scalar(penalty_scalar);

        assert(purger.get_penalty_scalar() == penalty_scalar, 'wrong penalty scalar #2');

        let (penalty, _, _) = purger.preview_absorb(target_trove);
        let expected_penalty: Ray = 10700000000000000000000000_u128.into(); // 1.07%
        common::assert_equalish(penalty, expected_penalty, error_margin, 'wrong scalar penalty #2');

        expected_events
            .append(
                Purger::Event::PenaltyScalarUpdated(
                    Purger::PenaltyScalarUpdated { new_scalar: penalty_scalar, }
                )
            );

        // Set scalar to 1.06
        let penalty_scalar: Ray = Purger::MAX_PENALTY_SCALAR.into();
        purger.set_penalty_scalar(penalty_scalar);

        assert(purger.get_penalty_scalar() == penalty_scalar, 'wrong penalty scalar #3');

        let (penalty, _, _) = purger.preview_absorb(target_trove);
        let expected_penalty: Ray = 54300000000000000000000000_u128.into(); // 5.43%
        common::assert_equalish(penalty, expected_penalty, error_margin, 'wrong scalar penalty #3');

        expected_events
            .append(
                Purger::Event::PenaltyScalarUpdated(
                    Purger::PenaltyScalarUpdated { new_scalar: penalty_scalar, }
                )
            );

        common::assert_events_emitted(
            purger.contract_address, expected_events.span(), Option::None
        );
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_penalty_scalar_lower_bound() {
        let (shrine, abbot, mock_pragma, _, purger, yangs, gates) = PurgerUtils::purger_deploy();

        PurgerUtils::create_whale_trove(abbot, yangs, gates);

        let yang_pair_ids = PragmaUtils::yang_pair_ids();

        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        // Set thresholds to 90% so we can check the scalar is not applied to the penalty
        let threshold: Ray = (90 * RAY_PERCENT).into();
        PurgerUtils::set_thresholds(shrine, yangs, threshold);

        let (_, _, value, debt) = shrine.get_trove_info(target_trove);
        // 91%; Note that if a penalty scalar is applied, then the trove would be absorbable
        // at this LTV because the penalty would be the maximum possible penalty. On the other
        // hand, if a penalty scalar is not applied, then the maximum possible penalty will be
        // reached from 92.09% onwards, so the trove would not be absorbable at this LTV
        let target_ltv: Ray = 910000000000000000000000000_u128.into();
        PurgerUtils::adjust_prices_for_trove_ltv(
            shrine, mock_pragma, yangs, yang_pair_ids, value, debt, target_ltv
        );

        let (trove_threshold, ltv, _, _) = shrine.get_trove_info(target_trove);
        // sanity check that threshold is correct
        assert(trove_threshold == threshold, 'threshold sanity check');

        // sanity check that LTV is at the target liquidation LTV
        let error_margin: Ray = 100000000_u128.into();
        common::assert_equalish(ltv, target_ltv, error_margin, 'LTV sanity check');

        let (penalty, _, _) = purger.preview_absorb(target_trove);
        let expected_penalty: Ray = RayZeroable::zero();
        assert(penalty.is_zero(), 'should not be absorbable #1');

        // Set scalar to 1.06 and check the trove is still not absorbable.
        set_contract_address(PurgerUtils::admin());
        let penalty_scalar: Ray = Purger::MAX_PENALTY_SCALAR.into();
        purger.set_penalty_scalar(penalty_scalar);

        let (penalty, _, _) = purger.preview_absorb(target_trove);
        assert(penalty.is_zero(), 'should not be absorbable #2');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Invalid scalar', 'ENTRYPOINT_FAILED'))]
    fn test_set_penalty_scalar_too_low_fail() {
        let (_, _, _, _, purger, _, _) = PurgerUtils::purger_deploy();

        set_contract_address(PurgerUtils::admin());
        purger.set_penalty_scalar((Purger::MIN_PENALTY_SCALAR - 1).into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Invalid scalar', 'ENTRYPOINT_FAILED'))]
    fn test_set_penalty_scalar_too_high_fail() {
        let (_, _, _, _, purger, _, _) = PurgerUtils::purger_deploy();

        set_contract_address(PurgerUtils::admin());
        purger.set_penalty_scalar((Purger::MAX_PENALTY_SCALAR + 1).into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_penalty_scalar_unauthorized_fail() {
        let (_, _, _, _, purger, _, _) = PurgerUtils::purger_deploy();

        set_contract_address(common::badguy());
        purger.set_penalty_scalar(RAY_ONE.into());
    }

    //
    // Tests - Liquidate
    //

    // This test fixes the trove's debt to 1,000 in order to test the ground truth values of the
    // penalty and close amount when LTV is at threshold. The error margin is relaxed because the
    // `adjust_prices_for_trove_ltv` may not put the trove in the exact LTV as the threshold.
    #[test]
    #[available_gas(20000000000)]
    fn test_preview_liquidate_parametrized() {
        let yang_pair_ids = PragmaUtils::yang_pair_ids();

        let mut thresholds: Span<Ray> = PurgerUtils::interesting_thresholds_for_liquidation();

        let trove_debt: Wad = (WAD_ONE * 1000).into();
        let mut expected_max_close_amts: Span<Wad> = array![
            284822000000000000000_u128.into(), // 284.822 (70% threshold)
            386997000000000000000_u128.into(), // 386.997 (80% threshold)
            603509000000000000000_u128.into(), // 603.509 (90% threshold)
            908381000000000000000_u128.into(), // 908.381 (96% threshold)
            992098000000000000000_u128.into(), // 992.098 (97% threshold)
            trove_debt, // (99% threshold)
        ]
            .span();

        let mut expected_penalty: Span<Ray> = array![
            (3 * RAY_PERCENT).into(), // 3% (70% threshold)
            (3 * RAY_PERCENT).into(), // 3% (80% threshold)
            (3 * RAY_PERCENT).into(), // 3% (90% threshold)
            (3 * RAY_PERCENT).into(), // 3% (96% threshold)
            (3 * RAY_PERCENT).into(), // 3% (97% threshold)
            10101000000000000000000000_u128.into(), // 1.0101% (99% threshold)
        ]
            .span();

        loop {
            match thresholds.pop_front() {
                Option::Some(threshold) => {
                    let (shrine, abbot, mock_pragma, absorber, purger, yangs, gates) =
                        PurgerUtils::purger_deploy();

                    PurgerUtils::set_thresholds(shrine, yangs, *threshold);
                    PurgerUtils::create_whale_trove(abbot, yangs, gates);

                    let target_trove: u64 = PurgerUtils::funded_healthy_trove(
                        abbot, yangs, gates, trove_debt
                    );

                    let (_, _, value, before_debt) = shrine.get_trove_info(target_trove);
                    PurgerUtils::adjust_prices_for_trove_ltv(
                        shrine, mock_pragma, yangs, yang_pair_ids, value, before_debt, *threshold
                    );

                    let (_, ltv, _, _) = shrine.get_trove_info(target_trove);
                    PurgerUtils::assert_trove_is_liquidatable(shrine, purger, target_trove, ltv);

                    let (penalty, max_close_amt) = purger.preview_liquidate(target_trove);

                    let expected_penalty = *expected_penalty.pop_front().unwrap();
                    common::assert_equalish(
                        penalty, expected_penalty, (RAY_ONE / 10).into(), 'wrong penalty'
                    );

                    let expected_max_close_amt = *expected_max_close_amts.pop_front().unwrap();
                    common::assert_equalish(
                        max_close_amt,
                        expected_max_close_amt,
                        (WAD_ONE * 2).into(),
                        'wrong max close amt'
                    );
                },
                Option::None => { break; },
            };
        };
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_liquidate_pass() {
        let searcher_start_yin: Wad = PurgerUtils::SEARCHER_YIN.into();
        let (shrine, abbot, mock_pragma, _, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            searcher_start_yin
        );

        PurgerUtils::create_whale_trove(abbot, yangs, gates);

        let initial_trove_debt: Wad = PurgerUtils::TARGET_TROVE_YIN.into();
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, initial_trove_debt
        );
        let yang_pair_ids = PragmaUtils::yang_pair_ids();

        // Accrue some interest
        common::advance_intervals(500);

        let before_total_debt: Wad = shrine.get_total_debt();
        let (threshold, _, value, debt) = shrine.get_trove_info(target_trove);
        let accrued_interest: Wad = debt - initial_trove_debt;
        // Sanity check that some interest has accrued
        assert(accrued_interest.is_non_zero(), 'no interest accrued');

        let target_ltv: Ray = (threshold.val + 1).into();
        PurgerUtils::adjust_prices_for_trove_ltv(
            shrine, mock_pragma, yangs, yang_pair_ids, value, debt, target_ltv
        );

        // Sanity check that LTV is at the target liquidation LTV
        let (_, ltv, before_value, before_debt) = shrine.get_trove_info(target_trove);
        PurgerUtils::assert_trove_is_liquidatable(shrine, purger, target_trove, ltv);

        let (penalty, max_close_amt) = purger.preview_liquidate(target_trove);
        let searcher: ContractAddress = PurgerUtils::searcher();

        let before_searcher_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, array![searcher].span()
        );

        set_contract_address(searcher);
        let freed_assets: Span<AssetBalance> = purger
            .liquidate(target_trove, BoundedWad::max(), searcher);

        // Assert that total debt includes accrued interest on liquidated trove
        let after_total_debt: Wad = shrine.get_total_debt();
        assert(
            after_total_debt == before_total_debt + accrued_interest - max_close_amt,
            'wrong total debt'
        );

        // Check that LTV is close to safety margin
        let (_, after_ltv, _, after_debt) = shrine.get_trove_info(target_trove);
        assert(after_debt == before_debt - max_close_amt, 'wrong debt after liquidation');

        PurgerUtils::assert_ltv_at_safety_margin(threshold, after_ltv);

        // Check searcher yin balance
        assert(
            shrine.get_yin(searcher) == searcher_start_yin - max_close_amt,
            'wrong searcher yin balance'
        );

        let (expected_freed_pct, expected_freed_amts) =
            PurgerUtils::get_expected_liquidation_assets(
            PurgerUtils::target_trove_yang_asset_amts(),
            before_value,
            max_close_amt,
            penalty,
            Option::None
        );
        let expected_freed_assets: Span<AssetBalance> = common::combine_assets_and_amts(
            yangs, expected_freed_amts
        );

        // Check that searcher has received collateral
        PurgerUtils::assert_received_assets(
            before_searcher_asset_bals,
            common::get_token_balances(yangs, array![searcher].span()),
            expected_freed_assets,
            10_u128, // error margin
            'wrong searcher asset balance',
        );

        common::assert_asset_balances_equalish(
            freed_assets, expected_freed_assets, 10_u128, // error margin
             'wrong freed asset amount'
        );

        let mut expected_events: Span<Purger::Event> = array![
            Purger::Event::Purged(
                Purger::Purged {
                    trove_id: target_trove,
                    purge_amt: max_close_amt,
                    percentage_freed: expected_freed_pct,
                    funder: searcher,
                    recipient: searcher,
                    freed_assets: freed_assets
                }
            ),
        ]
            .span();
        common::assert_events_emitted(purger.contract_address, expected_events, Option::None);

        ShrineUtils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_liquidate_with_flashmint_pass() {
        let (shrine, abbot, mock_pragma, _, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );

        PurgerUtils::create_whale_trove(abbot, yangs, gates);

        let yang_pair_ids = PragmaUtils::yang_pair_ids();

        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );
        let flashmint = FlashmintUtils::flashmint_deploy(shrine.contract_address);
        let flash_liquidator = PurgerUtils::flash_liquidator_deploy(
            shrine.contract_address,
            abbot.contract_address,
            flashmint.contract_address,
            purger.contract_address
        );

        // Fund flash liquidator contract with some collateral to open a trove
        // but not draw any debt
        common::fund_user(
            flash_liquidator.contract_address, yangs, AbsorberUtils::provider_asset_amts()
        );

        // Accrue some interest
        common::advance_intervals(500);

        let (threshold, _, value, debt) = shrine.get_trove_info(target_trove);
        let target_ltv: Ray = (threshold.val + 1).into();
        PurgerUtils::adjust_prices_for_trove_ltv(
            shrine, mock_pragma, yangs, yang_pair_ids, value, debt, target_ltv
        );

        // Sanity check that LTV is at the target liquidation LTV
        let (_, ltv, before_value, before_debt) = shrine.get_trove_info(target_trove);
        PurgerUtils::assert_trove_is_liquidatable(shrine, purger, target_trove, ltv);
        let (_, max_close_amt) = purger.preview_liquidate(target_trove);

        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);
        flash_liquidator.flash_liquidate(target_trove, yangs, gates);

        // Check that LTV is close to safety margin
        let (_, after_ltv, _, after_debt) = shrine.get_trove_info(target_trove);
        assert(after_debt == before_debt - max_close_amt, 'wrong debt after liquidation');

        PurgerUtils::assert_ltv_at_safety_margin(threshold, after_ltv);

        ShrineUtils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
    }

    // This test parametrizes over thresholds (by setting all yangs thresholds to the given value)
    // and the LTV at liquidation, and checks for the following
    // 1. LTV has decreased
    // 2. trove's debt is reduced by the close amount
    // 3. If it is not a full liquidation, then the post-liquidation LTV is at the target safety margin
    #[test]
    #[available_gas(20000000000000)]
    fn test_liquidate_parametrized() {
        let yang_pair_ids = PragmaUtils::yang_pair_ids();

        let mut thresholds: Span<Ray> = PurgerUtils::interesting_thresholds_for_liquidation();

        let num_thresholds: usize = thresholds.len();
        let mut safe_ltv_count: usize = 0;

        loop {
            match thresholds.pop_front() {
                Option::Some(threshold) => {
                    let mut target_ltvs: Span<Ray> = array![
                        (*threshold.val + 1).into(), //just above threshold
                        *threshold + RAY_PERCENT.into(), // 1% above threshold
                        // halfway between threshold and 100%
                        *threshold + ((RAY_ONE.into() - *threshold).val / 2).into(),
                        (RAY_ONE - RAY_PERCENT).into(), // 99%
                        (RAY_ONE + RAY_PERCENT).into() // 101%
                    ]
                        .span();

                    // Assert that we hit the branch for safety margin check at least once per threshold
                    let mut safety_margin_achieved: bool = false;

                    // Inner loop iterating over LTVs at liquidation
                    loop {
                        match target_ltvs.pop_front() {
                            Option::Some(target_ltv) => {
                                let searcher_start_yin: Wad = PurgerUtils::SEARCHER_YIN.into();
                                let (shrine, abbot, mock_pragma, _, purger, yangs, gates) =
                                    PurgerUtils::purger_deploy_with_searcher(
                                    searcher_start_yin
                                );

                                // Set thresholds to provided value
                                PurgerUtils::set_thresholds(shrine, yangs, *threshold);

                                PurgerUtils::create_whale_trove(abbot, yangs, gates);

                                let trove_debt: Wad = PurgerUtils::TARGET_TROVE_YIN.into();
                                let target_trove: u64 = PurgerUtils::funded_healthy_trove(
                                    abbot, yangs, gates, trove_debt
                                );

                                // Accrue some interest
                                common::advance_intervals(500);

                                let (_, _, value, before_debt) = shrine
                                    .get_trove_info(target_trove);
                                PurgerUtils::adjust_prices_for_trove_ltv(
                                    shrine,
                                    mock_pragma,
                                    yangs,
                                    yang_pair_ids,
                                    value,
                                    before_debt,
                                    *target_ltv
                                );
                                let (_, _, before_value, _) = shrine.get_trove_info(target_trove);

                                let (penalty, max_close_amt) = purger
                                    .preview_liquidate(target_trove);

                                let searcher: ContractAddress = PurgerUtils::searcher();
                                set_contract_address(searcher);
                                let freed_assets: Span<AssetBalance> = purger
                                    .liquidate(target_trove, BoundedWad::max(), searcher);

                                // Check that LTV is close to safety margin
                                let (_, after_ltv, _, after_debt) = shrine
                                    .get_trove_info(target_trove);

                                let is_fully_liquidated: bool = before_debt == max_close_amt;
                                if !is_fully_liquidated {
                                    PurgerUtils::assert_ltv_at_safety_margin(*threshold, after_ltv);

                                    assert(
                                        after_debt == before_debt - max_close_amt,
                                        'wrong debt after liquidation'
                                    );

                                    if !safety_margin_achieved {
                                        safe_ltv_count += 1;
                                        safety_margin_achieved = true;
                                    }
                                } else {
                                    assert(after_debt.is_zero(), 'should be 0 debt');
                                }

                                let (expected_freed_pct, _) =
                                    PurgerUtils::get_expected_liquidation_assets(
                                    PurgerUtils::target_trove_yang_asset_amts(),
                                    before_value,
                                    max_close_amt,
                                    penalty,
                                    Option::None,
                                );

                                let mut expected_events: Span<Purger::Event> = array![
                                    Purger::Event::Purged(
                                        Purger::Purged {
                                            trove_id: target_trove,
                                            purge_amt: max_close_amt,
                                            percentage_freed: expected_freed_pct,
                                            funder: searcher,
                                            recipient: searcher,
                                            freed_assets: freed_assets
                                        }
                                    ),
                                ]
                                    .span();
                                common::assert_events_emitted(
                                    purger.contract_address, expected_events, Option::None
                                );

                                ShrineUtils::assert_shrine_invariants(
                                    shrine, yangs, abbot.get_troves_count()
                                );
                            },
                            Option::None => { break; },
                        };
                    };
                },
                Option::None => { break; },
            };
        };

        // We should hit the branch to check the post-liquidation LTV is at the expected safety margin
        // at least once per threshold, based on the target LTV that is just above the threshold.
        // This assertion provides this assurance.
        // Offset 1 for the 99% threshold where close amount is always equal to trove's debt
        assert(safe_ltv_count == num_thresholds - 1, 'at least one per threshold');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not liquidatable', 'ENTRYPOINT_FAILED'))]
    fn test_liquidate_trove_healthy_fail() {
        let (shrine, abbot, _, _, purger, yangs, gates) = PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let healthy_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        PurgerUtils::assert_trove_is_healthy(shrine, purger, healthy_trove);

        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);
        purger.liquidate(healthy_trove, BoundedWad::max(), searcher);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not liquidatable', 'ENTRYPOINT_FAILED'))]
    fn test_liquidate_trove_healthy_high_threshold_fail() {
        let (shrine, abbot, _, _, purger, yangs, gates) = PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let healthy_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        let threshold: Ray = (95 * RAY_PERCENT).into();
        PurgerUtils::set_thresholds(shrine, yangs, threshold);
        let max_forge_amt: Wad = shrine.get_max_forge(healthy_trove);

        let healthy_trove_owner: ContractAddress = PurgerUtils::target_trove_owner();
        set_contract_address(healthy_trove_owner);
        abbot.forge(healthy_trove, max_forge_amt, 0_u128.into());

        // Sanity check that LTV is above absorption threshold and safe
        let (_, ltv, _, _) = shrine.get_trove_info(healthy_trove);
        assert(ltv > Purger::ABSORPTION_THRESHOLD.into(), 'too low');
        PurgerUtils::assert_trove_is_healthy(shrine, purger, healthy_trove);

        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);
        purger.liquidate(healthy_trove, BoundedWad::max(), searcher);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(
        expected: ('SH: Insufficient yin balance', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED')
    )]
    fn test_liquidate_insufficient_yin_fail() {
        let target_trove_yin: Wad = PurgerUtils::TARGET_TROVE_YIN.into();
        let searcher_yin: Wad = (target_trove_yin.val / 10).into();

        let (shrine, abbot, mock_pragma, _, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            searcher_yin
        );
        let yang_pair_ids = PragmaUtils::yang_pair_ids();
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, target_trove_yin
        );

        let (threshold, _, value, debt) = shrine.get_trove_info(target_trove);

        let target_ltv: Ray = (threshold.val + 1).into();
        PurgerUtils::adjust_prices_for_trove_ltv(
            shrine, mock_pragma, yangs, yang_pair_ids, value, debt, target_ltv
        );

        // Sanity check that LTV is at the target liquidation LTV
        let (_, ltv, _, _) = shrine.get_trove_info(target_trove);
        PurgerUtils::assert_trove_is_liquidatable(shrine, purger, target_trove, ltv);

        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);
        purger.liquidate(target_trove, BoundedWad::max(), searcher);
    }

    //
    // Tests - Absorb
    //

    // This test fixes the trove's debt to 1,000 in order to test the ground truth values of the
    // penalty and close amount when LTV is at threshold. The error margin is relaxed because the
    // `adjust_prices_for_trove_ltv` may not put the trove in the exact LTV as the threshold.
    #[test]
    #[available_gas(20000000000000000)]
    fn test_preview_absorb_below_trove_debt_parametrized() {
        let yang_pair_ids = PragmaUtils::yang_pair_ids();

        let mut interesting_thresholds =
            PurgerUtils::interesting_thresholds_for_absorption_below_trove_debt();
        let mut target_ltvs: Span<Span<Ray>> =
            PurgerUtils::ltvs_for_interesting_thresholds_for_absorption_below_trove_debt();

        let trove_debt: Wad = (WAD_ONE * 1000).into();
        let expected_penalty: Ray = Purger::MAX_PENALTY.into();

        let mut expected_max_close_amts: Span<Wad> = array![
            593187000000000000000_u128.into(), // 593.187 (65% threshold, 71.18% LTV)
            696105000000000000000_u128.into(), // 696.105 (70% threshold, 76.65% LTV)
            842762000000000000000_u128.into(), // 842.762 (75% threshold, 82.13% LTV)
            999945000000000000000_u128.into(), // 999.945 (78.74% threshold, 86.2203% LTV)
        ]
            .span();

        loop {
            match interesting_thresholds.pop_front() {
                Option::Some(threshold) => {
                    let mut target_ltv_arr = *target_ltvs.pop_front().unwrap();
                    let target_ltv = *target_ltv_arr.pop_front().unwrap();

                    let (shrine, abbot, mock_pragma, absorber, purger, yangs, gates) =
                        PurgerUtils::purger_deploy();

                    let target_trove: u64 = PurgerUtils::funded_healthy_trove(
                        abbot, yangs, gates, trove_debt
                    );

                    let whale_trove: u64 = PurgerUtils::create_whale_trove(abbot, yangs, gates);

                    PurgerUtils::funded_absorber(
                        shrine, abbot, absorber, yangs, gates, (trove_debt.val * 2).into()
                    );
                    PurgerUtils::set_thresholds(shrine, yangs, *threshold);

                    let (_, _, start_value, before_debt) = shrine.get_trove_info(target_trove);

                    // Make the target trove absorbable
                    PurgerUtils::adjust_prices_for_trove_ltv(
                        shrine,
                        mock_pragma,
                        yangs,
                        yang_pair_ids,
                        start_value,
                        before_debt,
                        target_ltv
                    );

                    let (_, ltv, _, _) = shrine.get_trove_info(target_trove);

                    PurgerUtils::assert_trove_is_absorbable(shrine, purger, target_trove, ltv);

                    let (penalty, max_close_amt, _) = purger.preview_absorb(target_trove);

                    common::assert_equalish(
                        penalty,
                        expected_penalty,
                        (RAY_PERCENT / 10).into(), // 0.1%
                        'wrong penalty'
                    );

                    let expected_max_close_amt = *expected_max_close_amts.pop_front().unwrap();
                    common::assert_equalish(
                        max_close_amt,
                        expected_max_close_amt,
                        (WAD_ONE / 10).into(),
                        'wrong max close amt'
                    );
                },
                Option::None => { break; },
            };
        };
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_full_absorb_pass() {
        let (shrine, abbot, mock_pragma, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let initial_trove_debt: Wad = PurgerUtils::TARGET_TROVE_YIN.into();
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, initial_trove_debt
        );
        let yang_pair_ids = PragmaUtils::yang_pair_ids();

        // Accrue some interest
        common::advance_intervals(500);

        let (threshold, _, start_value, before_debt) = shrine.get_trove_info(target_trove);
        let accrued_interest: Wad = before_debt - initial_trove_debt;
        // Sanity check that some interest has accrued
        assert(accrued_interest.is_non_zero(), 'no interest accrued');

        // Fund the absorber with twice the target trove's debt
        let absorber_start_yin: Wad = (before_debt.val * 2).into();
        PurgerUtils::funded_absorber(shrine, abbot, absorber, yangs, gates, absorber_start_yin);

        // sanity check
        assert(shrine.get_yin(absorber.contract_address) > before_debt, 'not full absorption');

        let before_total_debt: Wad = shrine.get_total_debt();

        // Make the target trove absorbable
        let target_ltv: Ray = (Purger::ABSORPTION_THRESHOLD + 1).into();
        PurgerUtils::adjust_prices_for_trove_ltv(
            shrine, mock_pragma, yangs, yang_pair_ids, start_value, before_debt, target_ltv
        );
        let (_, ltv, before_value, _) = shrine.get_trove_info(target_trove);
        PurgerUtils::assert_trove_is_absorbable(shrine, purger, target_trove, ltv);

        let (penalty, max_close_amt, expected_compensation_value) = purger
            .preview_absorb(target_trove);
        let caller: ContractAddress = PurgerUtils::random_user();

        let before_caller_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, array![caller].span()
        );
        let before_absorber_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, array![absorber.contract_address].span()
        );

        common::drop_all_events(purger.contract_address);

        set_contract_address(caller);
        let compensation: Span<AssetBalance> = purger.absorb(target_trove);

        // Assert that total debt includes accrued interest on liquidated trove
        let after_total_debt: Wad = shrine.get_total_debt();
        assert(
            after_total_debt == before_total_debt + accrued_interest - max_close_amt,
            'wrong total debt'
        );

        // Check absorption occured
        assert(absorber.get_absorptions_count() == 1, 'wrong absorptions count');

        // Check trove debt and LTV
        let (_, after_ltv, _, after_debt) = shrine.get_trove_info(target_trove);
        assert(after_debt == before_debt - max_close_amt, 'wrong debt after liquidation');

        let is_fully_absorbed: bool = after_debt.is_zero();
        if !is_fully_absorbed {
            PurgerUtils::assert_ltv_at_safety_margin(threshold, after_ltv);
        }

        // Check that caller has received compensation
        let target_trove_yang_asset_amts: Span<u128> = PurgerUtils::target_trove_yang_asset_amts();
        let expected_compensation_amts: Span<u128> = PurgerUtils::get_expected_compensation_assets(
            target_trove_yang_asset_amts, before_value, expected_compensation_value
        );
        let expected_compensation: Span<AssetBalance> = common::combine_assets_and_amts(
            yangs, expected_compensation_amts
        );
        PurgerUtils::assert_received_assets(
            before_caller_asset_bals,
            common::get_token_balances(yangs, array![caller].span()),
            expected_compensation,
            10_u128, // error margin
            'wrong caller asset balance',
        );

        common::assert_asset_balances_equalish(
            compensation, expected_compensation, 10_u128, // error margin
             'wrong freed asset amount'
        );

        // Check absorber yin balance
        assert(
            shrine.get_yin(absorber.contract_address) == absorber_start_yin - max_close_amt,
            'wrong absorber yin balance'
        );

        // Check that absorber has received collateral
        let (_, expected_freed_asset_amts) = PurgerUtils::get_expected_liquidation_assets(
            target_trove_yang_asset_amts,
            before_value,
            max_close_amt,
            penalty,
            Option::Some(expected_compensation_value)
        );

        let expected_freed_assets: Span<AssetBalance> = common::combine_assets_and_amts(
            yangs, expected_freed_asset_amts,
        );
        PurgerUtils::assert_received_assets(
            before_absorber_asset_bals,
            common::get_token_balances(yangs, array![absorber.contract_address].span()),
            expected_freed_assets,
            10_u128, // error margin
            'wrong absorber asset balance',
        );

        let purged_event: Purger::Purged = common::pop_event_with_indexed_keys(
            purger.contract_address
        )
            .unwrap();
        common::assert_asset_balances_equalish(
            purged_event.freed_assets,
            expected_freed_assets,
            10_u128,
            'wrong freed assets for event'
        );
        assert(purged_event.trove_id == target_trove, 'wrong Purged trove ID');
        assert(purged_event.purge_amt == max_close_amt, 'wrong Purged amt');
        assert(purged_event.percentage_freed == RAY_ONE.into(), 'wrong Purged freed pct');
        assert(purged_event.funder == absorber.contract_address, 'wrong Purged funder');
        assert(purged_event.recipient == absorber.contract_address, 'wrong Purged recipient');

        let compensate_event: Purger::Compensate = common::pop_event_with_indexed_keys(
            purger.contract_address
        )
            .unwrap();
        assert(
            compensate_event == Purger::Compensate { recipient: caller, compensation },
            'wrong Compensate event'
        );

        ShrineUtils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_partial_absorb_with_redistribution_entire_trove_debt_parametrized() {
        let mut target_trove_yang_asset_amts_cases =
            PurgerUtils::interesting_yang_amts_for_redistributed_trove();
        let yang_pair_ids = PragmaUtils::yang_pair_ids();
        loop {
            match target_trove_yang_asset_amts_cases.pop_front() {
                Option::Some(target_trove_yang_asset_amts) => {
                    let mut recipient_trove_yang_asset_amts_cases =
                        PurgerUtils::interesting_yang_amts_for_recipient_trove();
                    loop {
                        match recipient_trove_yang_asset_amts_cases.pop_front() {
                            Option::Some(yang_asset_amts) => {
                                let initial_trove_debt: Wad = PurgerUtils::TARGET_TROVE_YIN.into();
                                let mut absorber_yin_cases: Span<Wad> =
                                    PurgerUtils::generate_operational_absorber_yin_cases(
                                    initial_trove_debt
                                );

                                match absorber_yin_cases.pop_front() {
                                    Option::Some(absorber_start_yin) => {
                                        let (
                                            shrine,
                                            abbot,
                                            mock_pragma,
                                            absorber,
                                            purger,
                                            yangs,
                                            gates
                                        ) =
                                            PurgerUtils::purger_deploy();
                                        let initial_trove_debt: Wad = PurgerUtils::TARGET_TROVE_YIN
                                            .into();
                                        let target_trove_owner: ContractAddress =
                                            PurgerUtils::target_trove_owner();
                                        common::fund_user(
                                            target_trove_owner, yangs, *target_trove_yang_asset_amts
                                        );
                                        let target_trove: u64 = common::open_trove_helper(
                                            abbot,
                                            target_trove_owner,
                                            yangs,
                                            *target_trove_yang_asset_amts,
                                            gates,
                                            initial_trove_debt
                                        );

                                        // Skip interest accrual to facilitate parametrization of
                                        // absorber's yin balance based on target trove's debt
                                        //common::advance_intervals(500);

                                        let (_, _, start_value, before_debt) = shrine
                                            .get_trove_info(target_trove);

                                        let recipient_trove_owner: ContractAddress =
                                            AbsorberUtils::provider_1();
                                        let recipient_trove: u64 =
                                            AbsorberUtils::provide_to_absorber(
                                            shrine,
                                            abbot,
                                            absorber,
                                            recipient_trove_owner,
                                            yangs,
                                            *yang_asset_amts,
                                            gates,
                                            *absorber_start_yin,
                                        );
                                        let before_total_debt: Wad = shrine.get_total_debt();

                                        // Make the target trove absorbable
                                        let target_ltv: Ray = (Purger::ABSORPTION_THRESHOLD + 1)
                                            .into();
                                        PurgerUtils::adjust_prices_for_trove_ltv(
                                            shrine,
                                            mock_pragma,
                                            yangs,
                                            yang_pair_ids,
                                            start_value,
                                            before_debt,
                                            target_ltv
                                        );

                                        let (_, ltv, before_value, _) = shrine
                                            .get_trove_info(target_trove);
                                        let (_, _, recipient_trove_value, recipient_trove_debt) =
                                            shrine
                                            .get_trove_info(recipient_trove);

                                        PurgerUtils::assert_trove_is_absorbable(
                                            shrine, purger, target_trove, ltv
                                        );

                                        let (penalty, max_close_amt, expected_compensation_value) =
                                            purger
                                            .preview_absorb(target_trove);
                                        let close_amt: Wad = *absorber_start_yin;

                                        // Sanity check
                                        assert(
                                            shrine
                                                .get_yin(absorber.contract_address) < max_close_amt,
                                            'not less than close amount'
                                        );

                                        let caller: ContractAddress = PurgerUtils::random_user();

                                        let before_caller_asset_bals: Span<Span<u128>> =
                                            common::get_token_balances(
                                            yangs, array![caller].span()
                                        );
                                        let before_absorber_asset_bals: Span<Span<u128>> =
                                            common::get_token_balances(
                                            yangs, array![absorber.contract_address].span()
                                        );

                                        common::drop_all_events(purger.contract_address);
                                        common::drop_all_events(shrine.contract_address);

                                        set_contract_address(caller);
                                        let compensation: Span<AssetBalance> = purger
                                            .absorb(target_trove);

                                        let after_total_debt: Wad = shrine.get_total_debt();
                                        assert(
                                            after_total_debt == before_total_debt - close_amt,
                                            'wrong total debt'
                                        );

                                        // Check absorption occured
                                        assert(
                                            absorber.get_absorptions_count() == 1,
                                            'wrong absorptions count'
                                        );

                                        // Check trove debt, value and LTV
                                        let (_, _, after_value, after_debt) = shrine
                                            .get_trove_info(target_trove);
                                        assert(
                                            after_debt.is_zero(), 'wrong debt after liquidation'
                                        );
                                        assert(
                                            after_value.is_zero(), 'wrong value after liquidation'
                                        );

                                        // Check that caller has received compensation
                                        let expected_compensation_amts: Span<u128> =
                                            PurgerUtils::get_expected_compensation_assets(
                                            *target_trove_yang_asset_amts,
                                            before_value,
                                            expected_compensation_value
                                        );
                                        let expected_compensation: Span<AssetBalance> =
                                            common::combine_assets_and_amts(
                                            yangs, expected_compensation_amts
                                        );
                                        PurgerUtils::assert_received_assets(
                                            before_caller_asset_bals,
                                            common::get_token_balances(
                                                yangs, array![caller].span()
                                            ),
                                            expected_compensation,
                                            10_u128, // error margin
                                            'wrong caller asset balance',
                                        );

                                        common::assert_asset_balances_equalish(
                                            compensation,
                                            expected_compensation,
                                            10_u128, // error margin
                                            'wrong freed asset amount'
                                        );

                                        // Check absorber yin balance is wiped out
                                        assert(
                                            shrine.get_yin(absorber.contract_address).is_zero(),
                                            'wrong absorber yin balance'
                                        );

                                        // Check that absorber has received proportionate share of collateral
                                        let (expected_freed_pct, expected_freed_asset_amts) =
                                            PurgerUtils::get_expected_liquidation_assets(
                                            *target_trove_yang_asset_amts,
                                            before_value,
                                            close_amt,
                                            penalty,
                                            Option::Some(expected_compensation_value),
                                        );

                                        let expected_freed_assets: Span<AssetBalance> =
                                            common::combine_assets_and_amts(
                                            yangs, expected_freed_asset_amts
                                        );
                                        PurgerUtils::assert_received_assets(
                                            before_absorber_asset_bals,
                                            common::get_token_balances(
                                                yangs, array![absorber.contract_address].span()
                                            ),
                                            expected_freed_assets,
                                            100_u128, // error margin
                                            'wrong absorber asset balance',
                                        );

                                        // Check redistribution occured
                                        assert(
                                            shrine.get_redistributions_count() == 1,
                                            'wrong redistributions count'
                                        );

                                        // Check recipient trove's value and debt
                                        let (
                                            _,
                                            _,
                                            after_recipient_trove_value,
                                            after_recipient_trove_debt
                                        ) =
                                            shrine
                                            .get_trove_info(recipient_trove);
                                        let redistributed_amt: Wad = max_close_amt - close_amt;
                                        let expected_recipient_trove_debt: Wad =
                                            recipient_trove_debt
                                            + redistributed_amt;

                                        common::assert_equalish(
                                            after_recipient_trove_debt,
                                            expected_recipient_trove_debt,
                                            (WAD_ONE / 100).into(), // error margin
                                            'wrong recipient trove debt'
                                        );

                                        let redistributed_value: Wad = before_value
                                            - wadray::rmul_wr(close_amt, RAY_ONE.into() + penalty)
                                            - expected_compensation_value;
                                        let expected_recipient_trove_value: Wad =
                                            recipient_trove_value
                                            + redistributed_value;

                                        common::assert_equalish(
                                            after_recipient_trove_value,
                                            expected_recipient_trove_value,
                                            (WAD_ONE / 100).into(), // error margin
                                            'wrong recipient trove value'
                                        );

                                        // Check Purger events

                                        let purged_event: Purger::Purged =
                                            common::pop_event_with_indexed_keys(
                                            purger.contract_address
                                        )
                                            .unwrap();
                                        common::assert_asset_balances_equalish(
                                            purged_event.freed_assets,
                                            expected_freed_assets,
                                            1_u128,
                                            'wrong freed assets for event'
                                        );
                                        assert(
                                            purged_event.trove_id == target_trove,
                                            'wrong Purged trove ID'
                                        );
                                        assert(
                                            purged_event.purge_amt == close_amt, 'wrong Purged amt'
                                        );
                                        assert(
                                            purged_event.percentage_freed == expected_freed_pct,
                                            'wrong Purged freed pct'
                                        );
                                        assert(
                                            purged_event.funder == absorber.contract_address,
                                            'wrong Purged funder'
                                        );
                                        assert(
                                            purged_event.recipient == absorber.contract_address,
                                            'wrong Purged recipient'
                                        );

                                        let compensate_event: Purger::Compensate =
                                            common::pop_event_with_indexed_keys(
                                            purger.contract_address
                                        )
                                            .unwrap();
                                        assert(
                                            compensate_event == Purger::Compensate {
                                                recipient: caller, compensation
                                            },
                                            'wrong Compensate event'
                                        );

                                        // Check Shrine event
                                        let expected_redistribution_id = 1;
                                        let mut expected_events: Span<Shrine::Event> = array![
                                            Shrine::Event::TroveRedistributed(
                                                Shrine::TroveRedistributed {
                                                    redistribution_id: expected_redistribution_id,
                                                    trove_id: target_trove,
                                                    debt: redistributed_amt,
                                                }
                                            ),
                                        ]
                                            .span();
                                        common::assert_events_emitted(
                                            shrine.contract_address, expected_events, Option::None
                                        );

                                        ShrineUtils::assert_shrine_invariants(
                                            shrine, yangs, abbot.get_troves_count()
                                        );
                                    },
                                    Option::None => { break; },
                                };
                            },
                            Option::None => { break; },
                        };
                    };
                },
                Option::None => { break; },
            };
        };
    }

    #[test]
    #[available_gas(20000000000000000)]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized() {
        let mut target_trove_yang_asset_amts_cases =
            PurgerUtils::interesting_yang_amts_for_redistributed_trove();
        let yang_pair_ids = PragmaUtils::yang_pair_ids();
        loop {
            match target_trove_yang_asset_amts_cases.pop_front() {
                Option::Some(target_trove_yang_asset_amts) => {
                    let mut recipient_trove_yang_asset_amts_cases =
                        PurgerUtils::interesting_yang_amts_for_recipient_trove();
                    loop {
                        match recipient_trove_yang_asset_amts_cases.pop_front() {
                            Option::Some(yang_asset_amts) => {
                                let mut interesting_thresholds =
                                    PurgerUtils::interesting_thresholds_for_absorption_below_trove_debt();
                                let mut target_ltvs: Span<Span<Ray>> =
                                    PurgerUtils::ltvs_for_interesting_thresholds_for_absorption_below_trove_debt();
                                loop {
                                    match interesting_thresholds.pop_front() {
                                        Option::Some(threshold) => {
                                            // Use only the first value which guarantees the max absorption amount is less
                                            // than the trove's debt
                                            let mut target_ltvs_arr: Span<Ray> = *target_ltvs
                                                .pop_front()
                                                .unwrap();
                                            let target_ltv: Ray = *target_ltvs_arr
                                                .pop_front()
                                                .unwrap();

                                            let mut absorber_yin_idx: usize = 0;
                                            // Index 0 is a dummy value for the absorber yin
                                            // being a fraction of the trove's debt.
                                            // Index 1 is a dummy value for the lower bound
                                            // of the absorber's yin.
                                            // Index 2 is a dummy value for the trove's debt
                                            // minus the smallest unit of Wad (which would amount to
                                            // 1001 wei after including the initial amount in Absorber)
                                            let end_idx: usize = 3;

                                            loop {
                                                if absorber_yin_idx == end_idx {
                                                    break;
                                                }

                                                let (
                                                    shrine,
                                                    abbot,
                                                    mock_pragma,
                                                    absorber,
                                                    purger,
                                                    yangs,
                                                    gates
                                                ) =
                                                    PurgerUtils::purger_deploy();

                                                let target_trove_owner: ContractAddress =
                                                    PurgerUtils::target_trove_owner();
                                                common::fund_user(
                                                    target_trove_owner,
                                                    yangs,
                                                    *target_trove_yang_asset_amts
                                                );
                                                let initial_trove_debt: Wad =
                                                    PurgerUtils::TARGET_TROVE_YIN
                                                    .into();
                                                let target_trove: u64 = common::open_trove_helper(
                                                    abbot,
                                                    target_trove_owner,
                                                    yangs,
                                                    *target_trove_yang_asset_amts,
                                                    gates,
                                                    initial_trove_debt
                                                );

                                                // Accrue some interest
                                                common::advance_intervals(500);

                                                let whale_trove: u64 =
                                                    PurgerUtils::create_whale_trove(
                                                    abbot, yangs, gates
                                                );

                                                let (_, _, start_value, before_debt) = shrine
                                                    .get_trove_info(target_trove);
                                                let accrued_interest: Wad = before_debt
                                                    - initial_trove_debt;
                                                // Sanity check that some interest has accrued
                                                assert(
                                                    accrued_interest.is_non_zero(),
                                                    'no interest accrued'
                                                );

                                                PurgerUtils::set_thresholds(
                                                    shrine, yangs, *threshold
                                                );

                                                let (_, _, start_value, before_debt) = shrine
                                                    .get_trove_info(target_trove);

                                                // Make the target trove absorbable
                                                PurgerUtils::adjust_prices_for_trove_ltv(
                                                    shrine,
                                                    mock_pragma,
                                                    yangs,
                                                    yang_pair_ids,
                                                    start_value,
                                                    before_debt,
                                                    target_ltv
                                                );

                                                let (_, ltv, before_value, _) = shrine
                                                    .get_trove_info(target_trove);

                                                PurgerUtils::assert_trove_is_absorbable(
                                                    shrine, purger, target_trove, ltv
                                                );

                                                let (
                                                    penalty,
                                                    max_close_amt,
                                                    expected_compensation_value
                                                ) =
                                                    purger
                                                    .preview_absorb(target_trove);

                                                // sanity check
                                                assert(
                                                    max_close_amt < before_debt,
                                                    'close amt not below trove debt'
                                                );

                                                let caller: ContractAddress =
                                                    PurgerUtils::random_user();

                                                let before_caller_asset_bals: Span<Span<u128>> =
                                                    common::get_token_balances(
                                                    yangs, array![caller].span()
                                                );
                                                let before_absorber_asset_bals: Span<Span<u128>> =
                                                    common::get_token_balances(
                                                    yangs, array![absorber.contract_address].span()
                                                );

                                                let absorber_start_yin: Wad =
                                                    if absorber_yin_idx == 0 {
                                                    // Fund the absorber with 1/3 of the max close amount
                                                    (max_close_amt.val / 3).into()
                                                } else {
                                                    if absorber_yin_idx == 1 {
                                                        Absorber::MINIMUM_SHARES.into()
                                                    } else {
                                                        (max_close_amt.val - 1).into()
                                                    }
                                                };
                                                let close_amt = absorber_start_yin;
                                                let recipient_trove_owner: ContractAddress =
                                                    AbsorberUtils::provider_1();
                                                let recipient_trove: u64 =
                                                    AbsorberUtils::provide_to_absorber(
                                                    shrine,
                                                    abbot,
                                                    absorber,
                                                    recipient_trove_owner,
                                                    yangs,
                                                    *yang_asset_amts,
                                                    gates,
                                                    absorber_start_yin,
                                                );
                                                set_contract_address(target_trove_owner);
                                                abbot.close_trove(whale_trove);

                                                let (tmp_threshold, _, _, _) = shrine
                                                    .get_trove_info(target_trove);

                                                assert(
                                                    tmp_threshold == *threshold, 'in recovery mode'
                                                );

                                                let (
                                                    _,
                                                    _,
                                                    recipient_trove_value,
                                                    recipient_trove_debt
                                                ) =
                                                    shrine
                                                    .get_trove_info(recipient_trove);
                                                let before_total_debt: Wad = shrine
                                                    .get_total_debt();

                                                // sanity check
                                                assert(
                                                    shrine
                                                        .get_yin(
                                                            absorber.contract_address
                                                        ) < max_close_amt,
                                                    'not less than close amount'
                                                );

                                                common::drop_all_events(purger.contract_address);
                                                common::drop_all_events(shrine.contract_address);

                                                set_contract_address(caller);
                                                let compensation: Span<AssetBalance> = purger
                                                    .absorb(target_trove);

                                                // Assert that total debt includes accrued interest on liquidated trove
                                                let after_total_debt: Wad = shrine.get_total_debt();
                                                assert(
                                                    after_total_debt == before_total_debt
                                                        + accrued_interest
                                                        - close_amt,
                                                    'wrong total debt'
                                                );

                                                // Check absorption occured
                                                assert(
                                                    absorber.get_absorptions_count() == 1,
                                                    'wrong absorptions count'
                                                );

                                                // Check trove debt, value and LTV
                                                let (_, after_ltv, after_value, after_debt) = shrine
                                                    .get_trove_info(target_trove);

                                                let expected_redistributed_value: Wad =
                                                    wadray::rmul_wr(
                                                    max_close_amt, RAY_ONE.into() + penalty
                                                );
                                                let expected_after_value: Wad = before_value
                                                    - expected_compensation_value
                                                    - expected_redistributed_value;
                                                assert(
                                                    after_debt.is_non_zero(), 'debt should not be 0'
                                                );

                                                let expected_after_debt: Wad = before_debt
                                                    - max_close_amt;
                                                assert(
                                                    after_debt == expected_after_debt,
                                                    'wrong debt after liquidation'
                                                );

                                                assert(
                                                    after_value.is_non_zero(),
                                                    'value should not be 0'
                                                );
                                                common::assert_equalish(
                                                    after_value,
                                                    expected_after_value,
                                                    // (10 ** 15) error margin
                                                    1000000000000000_u128.into(),
                                                    'wrong value after liquidation'
                                                );

                                                PurgerUtils::assert_ltv_at_safety_margin(
                                                    *threshold, after_ltv
                                                );

                                                // Check that caller has received compensation
                                                let expected_compensation_amts: Span<u128> =
                                                    PurgerUtils::get_expected_compensation_assets(
                                                    *target_trove_yang_asset_amts,
                                                    before_value,
                                                    expected_compensation_value
                                                );
                                                let expected_compensation: Span<AssetBalance> =
                                                    common::combine_assets_and_amts(
                                                    yangs, expected_compensation_amts
                                                );
                                                PurgerUtils::assert_received_assets(
                                                    before_caller_asset_bals,
                                                    common::get_token_balances(
                                                        yangs, array![caller].span()
                                                    ),
                                                    expected_compensation,
                                                    10_u128, // error margin
                                                    'wrong caller asset balance'
                                                );

                                                common::assert_asset_balances_equalish(
                                                    compensation,
                                                    expected_compensation,
                                                    10_u128, // error margin
                                                    'wrong freed asset amount'
                                                );

                                                // Check absorber yin balance is wiped out
                                                assert(
                                                    shrine
                                                        .get_yin(absorber.contract_address)
                                                        .is_zero(),
                                                    'wrong absorber yin balance'
                                                );

                                                // Check that absorber has received proportionate share of collateral
                                                let (expected_freed_pct, expected_freed_amts) =
                                                    PurgerUtils::get_expected_liquidation_assets(
                                                    *target_trove_yang_asset_amts,
                                                    before_value,
                                                    close_amt,
                                                    penalty,
                                                    Option::Some(expected_compensation_value),
                                                );
                                                let expected_freed_assets: Span<AssetBalance> =
                                                    common::combine_assets_and_amts(
                                                    yangs, expected_freed_amts
                                                );
                                                PurgerUtils::assert_received_assets(
                                                    before_absorber_asset_bals,
                                                    common::get_token_balances(
                                                        yangs,
                                                        array![absorber.contract_address].span()
                                                    ),
                                                    expected_freed_assets,
                                                    100_u128, // error margin
                                                    'wrong absorber asset balance'
                                                );

                                                // Check redistribution occured
                                                assert(
                                                    shrine.get_redistributions_count() == 1,
                                                    'wrong redistributions count'
                                                );

                                                // Check recipient trove's debt
                                                let (
                                                    _,
                                                    _,
                                                    after_recipient_trove_value,
                                                    after_recipient_trove_debt
                                                ) =
                                                    shrine
                                                    .get_trove_info(recipient_trove);
                                                let expected_redistributed_amt: Wad = max_close_amt
                                                    - close_amt;
                                                let expected_recipient_trove_debt: Wad =
                                                    recipient_trove_debt
                                                    + expected_redistributed_amt;

                                                common::assert_equalish(
                                                    after_recipient_trove_debt,
                                                    expected_recipient_trove_debt,
                                                    (WAD_ONE / 100).into(), // error margin
                                                    'wrong recipient trove debt'
                                                );

                                                let redistributed_value: Wad = wadray::rmul_wr(
                                                    expected_redistributed_amt,
                                                    RAY_ONE.into() + penalty
                                                );
                                                let expected_recipient_trove_value: Wad =
                                                    recipient_trove_value
                                                    + redistributed_value;

                                                common::assert_equalish(
                                                    after_recipient_trove_value,
                                                    expected_recipient_trove_value,
                                                    (WAD_ONE / 100).into(), // error margin
                                                    'wrong recipient trove value'
                                                );

                                                // Check remainder yang assets for redistributed trove is correct
                                                let expected_remainder_pct: Ray = wadray::rdiv_ww(
                                                    expected_after_value, before_value
                                                );
                                                let mut expected_remainder_trove_yang_asset_amts =
                                                    common::scale_span_by_pct(
                                                    *target_trove_yang_asset_amts,
                                                    expected_remainder_pct
                                                );

                                                let mut yangs_copy = yangs;
                                                let mut gates_copy = gates;
                                                loop {
                                                    match expected_remainder_trove_yang_asset_amts
                                                        .pop_front() {
                                                        Option::Some(expected_asset_amt) => {
                                                            let gate: IGateDispatcher = *gates_copy
                                                                .pop_front()
                                                                .unwrap();
                                                            let remainder_trove_yang: Wad = shrine
                                                                .get_deposit(
                                                                    *yangs_copy
                                                                        .pop_front()
                                                                        .unwrap(),
                                                                    target_trove
                                                                );
                                                            let remainder_asset_amt: u128 = gate
                                                                .convert_to_assets(
                                                                    remainder_trove_yang
                                                                );
                                                            common::assert_equalish(
                                                                remainder_asset_amt,
                                                                *expected_asset_amt,
                                                                10000000_u128.into(),
                                                                'wrong remainder yang asset'
                                                            );
                                                        },
                                                        Option::None => { break; },
                                                    };
                                                };

                                                // Check Purger events

                                                let purged_event: Purger::Purged =
                                                    common::pop_event_with_indexed_keys(
                                                    purger.contract_address
                                                )
                                                    .unwrap();
                                                common::assert_asset_balances_equalish(
                                                    purged_event.freed_assets,
                                                    expected_freed_assets,
                                                    1000_u128,
                                                    'wrong freed assets for event'
                                                );
                                                assert(
                                                    purged_event.trove_id == target_trove,
                                                    'wrong Purged trove ID'
                                                );
                                                assert(
                                                    purged_event.purge_amt == close_amt,
                                                    'wrong Purged amt'
                                                );
                                                common::assert_equalish(
                                                    purged_event.percentage_freed,
                                                    expected_freed_pct,
                                                    1000000_u128.into(),
                                                    'wrong Purged freed pct'
                                                );
                                                assert(
                                                    purged_event
                                                        .funder == absorber
                                                        .contract_address,
                                                    'wrong Purged funder'
                                                );
                                                assert(
                                                    purged_event
                                                        .recipient == absorber
                                                        .contract_address,
                                                    'wrong Purged recipient'
                                                );

                                                let compensate_event: Purger::Compensate =
                                                    common::pop_event_with_indexed_keys(
                                                    purger.contract_address
                                                )
                                                    .unwrap();
                                                assert(
                                                    compensate_event == Purger::Compensate {
                                                        recipient: caller, compensation
                                                    },
                                                    'wrong Compensate event'
                                                );

                                                // Check Shrine event
                                                let expected_redistribution_id = 1;
                                                let mut expected_events: Span<Shrine::Event> =
                                                    array![
                                                    Shrine::Event::TroveRedistributed(
                                                        Shrine::TroveRedistributed {
                                                            redistribution_id: expected_redistribution_id,
                                                            trove_id: target_trove,
                                                            debt: expected_redistributed_amt,
                                                        }
                                                    ),
                                                ]
                                                    .span();
                                                common::assert_events_emitted(
                                                    shrine.contract_address,
                                                    expected_events,
                                                    Option::None
                                                );

                                                ShrineUtils::assert_shrine_invariants(
                                                    shrine, yangs, abbot.get_troves_count(),
                                                );

                                                absorber_yin_idx += 1;
                                            };
                                        },
                                        Option::None => { break; },
                                    };
                                };
                            },
                            Option::None => { break; },
                        };
                    };
                },
                Option::None => { break; },
            };
        };
    }

    // Note that the absorber also zero shares in this test because no provider has
    // provided yin yet.
    #[test]
    #[available_gas(20000000000000)]
    fn test_absorb_full_redistribution_parametrized() {
        let mut target_trove_yang_asset_amts_cases =
            PurgerUtils::interesting_yang_amts_for_redistributed_trove();
        let yang_pair_ids = PragmaUtils::yang_pair_ids();
        loop {
            match target_trove_yang_asset_amts_cases.pop_front() {
                Option::Some(target_trove_yang_asset_amts) => {
                    let mut recipient_trove_yang_asset_amts_cases =
                        PurgerUtils::interesting_yang_amts_for_recipient_trove();
                    loop {
                        match recipient_trove_yang_asset_amts_cases.pop_front() {
                            Option::Some(yang_asset_amts) => {
                                let mut absorber_yin_cases: Span<Wad> =
                                    PurgerUtils::inoperational_absorber_yin_cases();
                                loop {
                                    match absorber_yin_cases.pop_front() {
                                        Option::Some(absorber_start_yin) => {
                                            let (
                                                shrine,
                                                abbot,
                                                mock_pragma,
                                                absorber,
                                                purger,
                                                yangs,
                                                gates
                                            ) =
                                                PurgerUtils::purger_deploy();
                                            let initial_trove_debt: Wad =
                                                PurgerUtils::TARGET_TROVE_YIN
                                                .into();
                                            let target_trove_owner: ContractAddress =
                                                PurgerUtils::target_trove_owner();
                                            common::fund_user(
                                                target_trove_owner,
                                                yangs,
                                                *target_trove_yang_asset_amts
                                            );
                                            let target_trove: u64 = common::open_trove_helper(
                                                abbot,
                                                target_trove_owner,
                                                yangs,
                                                *target_trove_yang_asset_amts,
                                                gates,
                                                PurgerUtils::TARGET_TROVE_YIN.into()
                                            );

                                            // Accrue some interest
                                            common::advance_intervals(500);

                                            let (
                                                _,
                                                _,
                                                before_target_trove_value,
                                                before_target_trove_debt
                                            ) =
                                                shrine
                                                .get_trove_info(target_trove);
                                            let accrued_interest: Wad = before_target_trove_debt
                                                - initial_trove_debt;
                                            // Sanity check that some interest has accrued
                                            assert(
                                                accrued_interest.is_non_zero(),
                                                'no interest accrued'
                                            );

                                            let recipient_trove_owner: ContractAddress =
                                                AbsorberUtils::provider_1();
                                            let recipient_trove: u64 =
                                                AbsorberUtils::provide_to_absorber(
                                                shrine,
                                                abbot,
                                                absorber,
                                                recipient_trove_owner,
                                                yangs,
                                                *yang_asset_amts,
                                                gates,
                                                *absorber_start_yin,
                                            );

                                            let before_total_debt: Wad = shrine.get_total_debt();

                                            let target_ltv: Ray = (Purger::ABSORPTION_THRESHOLD + 1)
                                                .into();
                                            PurgerUtils::adjust_prices_for_trove_ltv(
                                                shrine,
                                                mock_pragma,
                                                yangs,
                                                yang_pair_ids,
                                                before_target_trove_value,
                                                before_target_trove_debt,
                                                target_ltv
                                            );

                                            let (_, ltv, before_value, _) = shrine
                                                .get_trove_info(target_trove);
                                            let (
                                                _,
                                                _,
                                                before_recipient_trove_value,
                                                before_recipient_trove_debt
                                            ) =
                                                shrine
                                                .get_trove_info(recipient_trove);

                                            PurgerUtils::assert_trove_is_absorbable(
                                                shrine, purger, target_trove, ltv
                                            );

                                            let caller: ContractAddress =
                                                PurgerUtils::random_user();
                                            let before_caller_asset_bals: Span<Span<u128>> =
                                                common::get_token_balances(
                                                yangs, array![caller].span()
                                            );
                                            let (_, _, expected_compensation_value) = purger
                                                .preview_absorb(target_trove);

                                            common::drop_all_events(purger.contract_address);

                                            set_contract_address(caller);
                                            let compensation: Span<AssetBalance> = purger
                                                .absorb(target_trove);

                                            // Assert that total debt includes accrued interest on liquidated trove
                                            let after_total_debt: Wad = shrine.get_total_debt();
                                            assert(
                                                after_total_debt == before_total_debt
                                                    + accrued_interest,
                                                'wrong total debt'
                                            );

                                            // Check that caller has received compensation
                                            let expected_compensation_amts: Span<u128> =
                                                PurgerUtils::get_expected_compensation_assets(
                                                *target_trove_yang_asset_amts,
                                                before_value,
                                                expected_compensation_value
                                            );
                                            let expected_compensation: Span<AssetBalance> =
                                                common::combine_assets_and_amts(
                                                yangs, expected_compensation_amts
                                            );
                                            PurgerUtils::assert_received_assets(
                                                before_caller_asset_bals,
                                                common::get_token_balances(
                                                    yangs, array![caller].span()
                                                ),
                                                expected_compensation,
                                                10_u128, // error margin
                                                'wrong caller asset balance',
                                            );

                                            common::assert_asset_balances_equalish(
                                                compensation,
                                                expected_compensation,
                                                10_u128, // error margin
                                                'wrong freed asset amount'
                                            );

                                            let (
                                                _,
                                                ltv,
                                                after_target_trove_value,
                                                after_target_trove_debt
                                            ) =
                                                shrine
                                                .get_trove_info(target_trove);
                                            assert(
                                                shrine.is_healthy(target_trove), 'should be healthy'
                                            );
                                            assert(ltv.is_zero(), 'LTV should be 0');
                                            assert(
                                                after_target_trove_value.is_zero(),
                                                'value should be 0'
                                            );
                                            assert(
                                                after_target_trove_debt.is_zero(),
                                                'debt should be 0'
                                            );

                                            // Check no absorption occured
                                            assert(
                                                absorber.get_absorptions_count() == 0,
                                                'wrong absorptions count'
                                            );

                                            // Check redistribution occured
                                            assert(
                                                shrine.get_redistributions_count() == 1,
                                                'wrong redistributions count'
                                            );

                                            // Check recipient trove's value and debt
                                            let (
                                                _,
                                                _,
                                                after_recipient_trove_value,
                                                after_recipient_trove_debt
                                            ) =
                                                shrine
                                                .get_trove_info(recipient_trove);
                                            let expected_recipient_trove_debt: Wad =
                                                before_recipient_trove_debt
                                                + before_target_trove_debt;

                                            common::assert_equalish(
                                                after_recipient_trove_debt,
                                                expected_recipient_trove_debt,
                                                (WAD_ONE / 100).into(), // error margin
                                                'wrong recipient trove debt'
                                            );

                                            let redistributed_value: Wad = before_value
                                                - expected_compensation_value;
                                            let expected_recipient_trove_value: Wad =
                                                before_recipient_trove_value
                                                + redistributed_value;
                                            common::assert_equalish(
                                                after_recipient_trove_value,
                                                expected_recipient_trove_value,
                                                (WAD_ONE / 100).into(), // error margin
                                                'wrong recipient trove value'
                                            );

                                            // Check Purger events

                                            // Note that this indirectly asserts that `Purged` 
                                            // is not emitted if it does not revert because 
                                            // `Purged` would have been emitted before `Compensate`
                                            let compensate_event: Purger::Compensate =
                                                common::pop_event_with_indexed_keys(
                                                purger.contract_address
                                            )
                                                .unwrap();
                                            assert(
                                                compensate_event == Purger::Compensate {
                                                    recipient: caller, compensation
                                                },
                                                'wrong Compensate event'
                                            );

                                            // Check Shrine event
                                            let expected_redistribution_id = 1;
                                            let mut expected_events: Span<Shrine::Event> = array![
                                                Shrine::Event::TroveRedistributed(
                                                    Shrine::TroveRedistributed {
                                                        redistribution_id: expected_redistribution_id,
                                                        trove_id: target_trove,
                                                        debt: before_target_trove_debt,
                                                    }
                                                ),
                                            ]
                                                .span();
                                            common::assert_events_emitted(
                                                shrine.contract_address,
                                                expected_events,
                                                Option::None
                                            );

                                            ShrineUtils::assert_shrine_invariants(
                                                shrine, yangs, abbot.get_troves_count(),
                                            );
                                        },
                                        Option::None => { break; },
                                    };
                                };
                            },
                            Option::None => { break; },
                        };
                    };
                },
                Option::None => { break; },
            };
        };
    }

    // This test parametrizes over thresholds (by setting all yangs thresholds to the given value)
    // and the LTV at liquidation, and checks for the following for thresholds up to 78.74%:
    // 1. LTV has decreased to the target safety margin
    // 2. trove's debt is reduced by the close amount, which is less than the trove's debt
    #[test]
    #[available_gas(20000000000)]
    fn test_absorb_less_than_trove_debt_parametrized() {
        let yang_pair_ids = PragmaUtils::yang_pair_ids();

        let mut thresholds: Span<Ray> =
            PurgerUtils::interesting_thresholds_for_absorption_below_trove_debt();
        let mut target_ltvs_by_threshold: Span<Span<Ray>> =
            PurgerUtils::ltvs_for_interesting_thresholds_for_absorption_below_trove_debt();

        loop {
            match thresholds.pop_front() {
                Option::Some(threshold) => {
                    let mut target_ltvs: Span<Ray> = *target_ltvs_by_threshold.pop_front().unwrap();

                    // Inner loop iterating over LTVs at liquidation
                    loop {
                        match target_ltvs.pop_front() {
                            Option::Some(target_ltv) => {
                                let searcher_start_yin: Wad = PurgerUtils::SEARCHER_YIN.into();
                                let (shrine, abbot, mock_pragma, absorber, purger, yangs, gates) =
                                    PurgerUtils::purger_deploy_with_searcher(
                                    searcher_start_yin
                                );

                                // Set thresholds to provided value
                                PurgerUtils::set_thresholds(shrine, yangs, *threshold);

                                PurgerUtils::create_whale_trove(abbot, yangs, gates);

                                let trove_debt: Wad = PurgerUtils::TARGET_TROVE_YIN.into();
                                let target_trove: u64 = PurgerUtils::funded_healthy_trove(
                                    abbot, yangs, gates, trove_debt
                                );

                                // Accrue some interest
                                common::advance_intervals(500);

                                let (_, _, start_value, before_debt) = shrine
                                    .get_trove_info(target_trove);

                                // Fund the absorber with twice the target trove's debt
                                let absorber_start_yin: Wad = (before_debt.val * 2).into();
                                PurgerUtils::funded_absorber(
                                    shrine, abbot, absorber, yangs, gates, absorber_start_yin
                                );

                                // sanity check
                                assert(
                                    shrine.get_yin(absorber.contract_address) > before_debt,
                                    'not full absorption'
                                );

                                // Make the target trove absorbable
                                PurgerUtils::adjust_prices_for_trove_ltv(
                                    shrine,
                                    mock_pragma,
                                    yangs,
                                    yang_pair_ids,
                                    start_value,
                                    before_debt,
                                    *target_ltv
                                );
                                let (_, ltv, before_value, _) = shrine.get_trove_info(target_trove);

                                PurgerUtils::assert_trove_is_absorbable(
                                    shrine, purger, target_trove, ltv
                                );

                                let (penalty, max_close_amt, expected_compensation_value) = purger
                                    .preview_absorb(target_trove);
                                assert(max_close_amt < before_debt, 'close amount == debt');

                                common::drop_all_events(purger.contract_address);

                                let caller: ContractAddress = PurgerUtils::random_user();
                                set_contract_address(caller);
                                let compensation: Span<AssetBalance> = purger.absorb(target_trove);

                                // Check that LTV is close to safety margin
                                let (_, after_ltv, _, after_debt) = shrine
                                    .get_trove_info(target_trove);
                                assert(
                                    after_debt == before_debt - max_close_amt,
                                    'wrong debt after liquidation'
                                );

                                PurgerUtils::assert_ltv_at_safety_margin(*threshold, after_ltv);

                                let (expected_freed_pct, expected_freed_amts) =
                                    PurgerUtils::get_expected_liquidation_assets(
                                    PurgerUtils::target_trove_yang_asset_amts(),
                                    before_value,
                                    max_close_amt,
                                    penalty,
                                    Option::Some(expected_compensation_value)
                                );
                                let expected_freed_assets: Span<AssetBalance> =
                                    common::combine_assets_and_amts(
                                    yangs, expected_freed_amts
                                );

                                let purged_event: Purger::Purged =
                                    common::pop_event_with_indexed_keys(
                                    purger.contract_address
                                )
                                    .unwrap();
                                common::assert_asset_balances_equalish(
                                    purged_event.freed_assets,
                                    expected_freed_assets,
                                    1000_u128,
                                    'wrong freed assets for event'
                                );
                                assert(
                                    purged_event.trove_id == target_trove, 'wrong Purged trove ID'
                                );
                                assert(purged_event.purge_amt == max_close_amt, 'wrong Purged amt');
                                common::assert_equalish(
                                    purged_event.percentage_freed,
                                    expected_freed_pct,
                                    1000000_u128.into(),
                                    'wrong Purged freed pct'
                                );
                                assert(
                                    purged_event.funder == absorber.contract_address,
                                    'wrong Purged funder'
                                );
                                assert(
                                    purged_event.recipient == absorber.contract_address,
                                    'wrong Purged recipient'
                                );

                                let compensate_event: Purger::Compensate =
                                    common::pop_event_with_indexed_keys(
                                    purger.contract_address
                                )
                                    .unwrap();
                                assert(
                                    compensate_event == Purger::Compensate {
                                        recipient: caller, compensation
                                    },
                                    'wrong Compensate event'
                                );

                                ShrineUtils::assert_shrine_invariants(
                                    shrine, yangs, abbot.get_troves_count()
                                );
                            },
                            Option::None => { break; },
                        };
                    };
                },
                Option::None => { break; },
            };
        };
    }

    // This test parametrizes over thresholds (by setting all yangs thresholds to the given value)
    // and the LTV at liquidation, and checks that the trove's debt is absorbed in full for thresholds
    // from 78.74% onwards.
    #[test]
    #[available_gas(20000000000000)]
    fn test_absorb_trove_debt_parametrized() {
        let yang_pair_ids = PragmaUtils::yang_pair_ids();

        let mut thresholds: Span<Ray> =
            PurgerUtils::interesting_thresholds_for_absorption_entire_trove_debt();
        let mut target_ltvs_by_threshold: Span<Span<Ray>> =
            PurgerUtils::ltvs_for_interesting_thresholds_for_absorption_entire_trove_debt();

        // This array should match `target_ltvs_by_threshold`. However, since only the first
        // LTV in the inner span of `target_ltvs_by_threshold` has a non-zero penalty, and the
        // penalty will be zero from the seocnd LTV of 99% (Ray) onwards, we flatten
        // the array to be concise.
        let ninety_nine_pct: Ray = (RAY_ONE - RAY_PERCENT).into();
        let mut expected_penalties: Span<Ray> = array![
            // First threshold of 78.75% (Ray)
            124889600000000000000000000_u128.into(), // 12.48896% (Ray); 86.23% LTV
            // Second threshold of 80% (Ray)
            116217800000000000000000000_u128.into(), // 11.62178% (Ray); 86.9% LTV
            // Third threshold of 90% (Ray)
            53196900000000000000000000_u128.into(), // 5.31969% (Ray); 92.1% LTV
            // Fourth threshold of 96% (Ray)
            10141202000000000000000000_u128.into(), // 1.0104102; (96 + 1 wei)% LTV
            // Fifth threshold of 97% (Ray)
            RayZeroable::zero(), // Dummy value since all target LTVs do not have a penalty
            // Sixth threshold of 99% (Ray)
            RayZeroable::zero(), // Dummy value since all target LTVs do not have a penalty
        ]
            .span();

        loop {
            match thresholds.pop_front() {
                Option::Some(threshold) => {
                    let mut target_ltvs: Span<Ray> = *target_ltvs_by_threshold.pop_front().unwrap();
                    let expected_penalty: Ray = *expected_penalties.pop_front().unwrap();
                    // Inner loop iterating over LTVs at liquidation
                    loop {
                        match target_ltvs.pop_front() {
                            Option::Some(target_ltv) => {
                                let searcher_start_yin: Wad = PurgerUtils::SEARCHER_YIN.into();
                                let (shrine, abbot, mock_pragma, absorber, purger, yangs, gates) =
                                    PurgerUtils::purger_deploy_with_searcher(
                                    searcher_start_yin
                                );

                                // Set thresholds to provided value
                                PurgerUtils::set_thresholds(shrine, yangs, *threshold);

                                let trove_debt: Wad = PurgerUtils::TARGET_TROVE_YIN.into();
                                let target_trove: u64 = PurgerUtils::funded_healthy_trove(
                                    abbot, yangs, gates, trove_debt
                                );

                                // Accrue some interest
                                common::advance_intervals(500);

                                let (_, _, start_value, before_debt) = shrine
                                    .get_trove_info(target_trove);

                                // Fund the absorber with twice the target trove's debt
                                let absorber_start_yin: Wad = (before_debt.val * 2).into();
                                PurgerUtils::funded_absorber(
                                    shrine, abbot, absorber, yangs, gates, absorber_start_yin
                                );

                                // sanity check
                                assert(
                                    shrine.get_yin(absorber.contract_address) > before_debt,
                                    'not full absorption'
                                );

                                // Make the target trove absorbable
                                PurgerUtils::adjust_prices_for_trove_ltv(
                                    shrine,
                                    mock_pragma,
                                    yangs,
                                    yang_pair_ids,
                                    start_value,
                                    before_debt,
                                    *target_ltv
                                );

                                let (_, ltv, before_value, _) = shrine.get_trove_info(target_trove);
                                PurgerUtils::assert_trove_is_absorbable(
                                    shrine, purger, target_trove, ltv
                                );

                                let (penalty, max_close_amt, expected_compensation_value) = purger
                                    .preview_absorb(target_trove);
                                assert(max_close_amt == before_debt, 'close amount != debt');
                                if *target_ltv >= ninety_nine_pct {
                                    assert(penalty.is_zero(), 'wrong penalty');
                                } else {
                                    common::assert_equalish(
                                        penalty,
                                        expected_penalty,
                                        (RAY_PERCENT / 10).into(), // 0.1%
                                        'wrong penalty'
                                    )
                                }

                                common::drop_all_events(purger.contract_address);

                                let caller: ContractAddress = PurgerUtils::random_user();
                                set_contract_address(caller);
                                let compensation: Span<AssetBalance> = purger.absorb(target_trove);

                                // Check that LTV is close to safety margin
                                let (_, after_ltv, after_value, after_debt) = shrine
                                    .get_trove_info(target_trove);
                                assert(after_ltv.is_zero(), 'wrong debt after liquidation');
                                assert(after_value.is_zero(), 'wrong debt after liquidation');
                                assert(after_debt.is_zero(), 'wrong debt after liquidation');

                                let target_trove_yang_asset_amts: Span<u128> =
                                    PurgerUtils::target_trove_yang_asset_amts();
                                let (_, expected_freed_asset_amts) =
                                    PurgerUtils::get_expected_liquidation_assets(
                                    target_trove_yang_asset_amts,
                                    before_value,
                                    max_close_amt,
                                    penalty,
                                    Option::Some(expected_compensation_value)
                                );

                                let expected_freed_assets: Span<AssetBalance> =
                                    common::combine_assets_and_amts(
                                    yangs, expected_freed_asset_amts,
                                );

                                let purged_event: Purger::Purged =
                                    common::pop_event_with_indexed_keys(
                                    purger.contract_address
                                )
                                    .unwrap();
                                assert(
                                    purged_event.trove_id == target_trove, 'wrong Purged trove ID'
                                );
                                assert(purged_event.purge_amt == max_close_amt, 'wrong Purged amt');
                                assert(
                                    purged_event.percentage_freed == RAY_ONE.into(),
                                    'wrong Purged freed pct'
                                );
                                assert(
                                    purged_event.funder == absorber.contract_address,
                                    'wrong Purged funder'
                                );
                                assert(
                                    purged_event.recipient == absorber.contract_address,
                                    'wrong Purged recipient'
                                );
                                common::assert_asset_balances_equalish(
                                    purged_event.freed_assets,
                                    expected_freed_assets,
                                    100000_u128,
                                    'wrong freed assets for event'
                                );

                                let compensate_event: Purger::Compensate =
                                    common::pop_event_with_indexed_keys(
                                    purger.contract_address
                                )
                                    .unwrap();
                                assert(
                                    compensate_event == Purger::Compensate {
                                        recipient: caller, compensation
                                    },
                                    'wrong Compensate event'
                                );

                                ShrineUtils::assert_shrine_invariants(
                                    shrine, yangs, abbot.get_troves_count()
                                );
                            },
                            Option::None => { break; },
                        };
                    };
                },
                Option::None => { break; },
            };
        };
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not absorbable', 'ENTRYPOINT_FAILED'))]
    fn test_absorb_trove_healthy_fail() {
        let (shrine, abbot, _, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );

        let trove_debt: Wad = PurgerUtils::TARGET_TROVE_YIN.into();
        let healthy_trove: u64 = PurgerUtils::funded_healthy_trove(abbot, yangs, gates, trove_debt);

        PurgerUtils::funded_absorber(shrine, abbot, absorber, yangs, gates, trove_debt);

        PurgerUtils::assert_trove_is_healthy(shrine, purger, healthy_trove);

        set_contract_address(PurgerUtils::random_user());
        purger.absorb(healthy_trove);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not absorbable', 'ENTRYPOINT_FAILED'))]
    fn test_absorb_below_absorbable_ltv_fail() {
        let (shrine, abbot, mock_pragma, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let yang_pair_ids = PragmaUtils::yang_pair_ids();

        PurgerUtils::create_whale_trove(abbot, yangs, gates);

        let trove_debt: Wad = PurgerUtils::TARGET_TROVE_YIN.into();
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(abbot, yangs, gates, trove_debt);
        PurgerUtils::funded_absorber(shrine, abbot, absorber, yangs, gates, trove_debt);

        let (threshold, _, value, debt) = shrine.get_trove_info(target_trove);
        let target_ltv: Ray = threshold + RAY_PERCENT.into();
        PurgerUtils::adjust_prices_for_trove_ltv(
            shrine, mock_pragma, yangs, yang_pair_ids, value, debt, target_ltv
        );

        let (_, new_ltv, value, _) = shrine.get_trove_info(target_trove);

        PurgerUtils::assert_trove_is_liquidatable(shrine, purger, target_trove, new_ltv);
        PurgerUtils::assert_trove_is_not_absorbable(purger, target_trove);

        set_contract_address(PurgerUtils::random_user());
        purger.absorb(target_trove);
    }

    // For thresholds < 90%, check that the LTV at which the trove is absorbable minus
    // 0.01% is not absorbable.
    #[test]
    #[available_gas(20000000000)]
    fn test_absorb_marginally_below_absorbable_ltv_not_absorbable() {
        let yang_pair_ids = PragmaUtils::yang_pair_ids();

        let (mut thresholds, mut target_ltvs) =
            PurgerUtils::interesting_thresholds_and_ltvs_below_absorption_ltv();

        loop {
            match thresholds.pop_front() {
                Option::Some(threshold) => {
                    let searcher_start_yin: Wad = PurgerUtils::SEARCHER_YIN.into();
                    let (shrine, abbot, mock_pragma, absorber, purger, yangs, gates) =
                        PurgerUtils::purger_deploy_with_searcher(
                        searcher_start_yin
                    );

                    PurgerUtils::create_whale_trove(abbot, yangs, gates);

                    // Set thresholds to provided value
                    PurgerUtils::set_thresholds(shrine, yangs, *threshold);

                    let trove_debt: Wad = PurgerUtils::TARGET_TROVE_YIN.into();
                    let target_trove: u64 = PurgerUtils::funded_healthy_trove(
                        abbot, yangs, gates, trove_debt
                    );

                    // Accrue some interest
                    common::advance_intervals(500);

                    let (_, _, start_value, before_debt) = shrine.get_trove_info(target_trove);

                    // Fund the absorber with twice the target trove's debt
                    let absorber_start_yin: Wad = (before_debt.val * 2).into();
                    PurgerUtils::funded_absorber(
                        shrine, abbot, absorber, yangs, gates, absorber_start_yin
                    );

                    // Adjust the trove to the target LTV
                    PurgerUtils::adjust_prices_for_trove_ltv(
                        shrine,
                        mock_pragma,
                        yangs,
                        yang_pair_ids,
                        start_value,
                        before_debt,
                        *target_ltvs.pop_front().unwrap()
                    );

                    let (_, ltv, _, _) = shrine.get_trove_info(target_trove);
                    PurgerUtils::assert_trove_is_liquidatable(shrine, purger, target_trove, ltv);
                    PurgerUtils::assert_trove_is_not_absorbable(purger, target_trove);
                },
                Option::None => { break; },
            };
        };
    }
}
