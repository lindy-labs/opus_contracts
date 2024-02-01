mod test_shrine_redistribution {
    use debug::PrintTrait;
    use opus::core::shrine::shrine as shrine_contract;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::{Health, YangBalance};
    use snforge_std::{
        declare, ContractClass, ContractClassTrait, start_prank, CheatTarget, spy_events, SpyOn, EventSpy,
        EventAssertions
    };
    use starknet::ContractAddress;
    use wadray::{Ray, RayZeroable, RAY_ONE, RAY_PERCENT, SignedWad, Wad, WadZeroable, WAD_ONE};

    //
    // Setup
    //

    const TROVE2_YANG1_DEPOSIT: u128 = 2370000000000000000; // 2.37 (Wad)
    const TROVE2_YANG2_DEPOSIT: u128 = 8310000000000000000; // 8.31 (Wad)
    const TROVE2_YANG3_DEPOSIT: u128 = 1320000000000000000; // 1.32 (Wad)
    const TROVE2_FORGE_AMT: u128 = 3456000000000000000000; // 3_456 (Wad)

    const TROVE3_YANG1_DEPOSIT: u128 = 4950000000000000000; // 4.95 (Wad)
    const TROVE3_YANG2_DEPOSIT: u128 = 6500000000000000000; // 6.5 (Wad)
    const TROVE3_YANG3_DEPOSIT: u128 = 2111000000000000000; // 2.111 (Wad)
    const TROVE3_FORGE_AMT: u128 = 2222000000000000000000; // 2_222 (Wad)

    fn setup_trove1(shrine: IShrineDispatcher) {
        let yang1_addr = shrine_utils::yang1_addr();
        let yang2_addr = shrine_utils::yang2_addr();

        let trove1_owner = common::trove1_owner_addr();
        shrine.deposit(yang1_addr, common::TROVE_1, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, common::TROVE_1, shrine_utils::TROVE1_YANG2_DEPOSIT.into());
        shrine.forge(trove1_owner, common::TROVE_1, shrine_utils::TROVE1_FORGE_AMT.into(), 0_u128.into());
    }

    fn setup_trove2(shrine: IShrineDispatcher) {
        let yang1_addr = shrine_utils::yang1_addr();
        let yang2_addr = shrine_utils::yang2_addr();

        let trove2_owner = common::trove2_owner_addr();
        shrine.deposit(yang1_addr, common::TROVE_2, TROVE2_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, common::TROVE_2, TROVE2_YANG2_DEPOSIT.into());
        shrine.forge(trove2_owner, common::TROVE_2, TROVE2_FORGE_AMT.into(), 0_u128.into());
    }

    fn setup_trove3(shrine: IShrineDispatcher) {
        let yang1_addr = shrine_utils::yang1_addr();
        let yang2_addr = shrine_utils::yang2_addr();

        let trove3_owner = shrine_utils::common::trove3_owner_addr();
        shrine.deposit(yang1_addr, common::TROVE_3, TROVE3_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, common::TROVE_3, TROVE3_YANG2_DEPOSIT.into());
        shrine.forge(trove3_owner, common::TROVE_3, TROVE3_FORGE_AMT.into(), 0_u128.into());
    }

    // Helper function to set up three troves
    // - Trove 1 deposits and forges the amounts specified in `src/tests/shrine/utils.cairo`
    // - Troves 2 and 3 deposits and forges the amounts specified in this file
    fn redistribution_setup(shrine_class: Option<ContractClass>) -> IShrineDispatcher {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(shrine_class);

        start_prank(CheatTarget::All, shrine_utils::admin());
        setup_trove1(shrine);
        setup_trove2(shrine);
        setup_trove3(shrine);

        shrine
    }

    // Returns a tuple of arrays which are the expected values from redistributing a trove
    // - value liquidated for each yang
    // - unit debt after redistributing debt for each yang
    // - expected amount of yangs remaining after redistribution
    // - total error from all yangs added to the budget as deficit
    // Note that once the remaining redistribution value falls below the threshold, an early
    // return will be performed, so yangs with dust value of debt will not be included.
    fn preview_trove_redistribution(
        shrine: IShrineDispatcher, mut yang_addrs: Span<ContractAddress>, trove: u64
    ) -> (Span<Wad>, Span<Wad>, Span<Wad>, Wad) {
        let trove_health: Health = shrine.get_trove_health(trove);

        let mut trove_yang_values: Array<Wad> = ArrayTrait::new();
        let mut expected_unit_debts: Array<Wad> = ArrayTrait::new();
        let mut expected_remaining_yangs: Array<Wad> = ArrayTrait::new();
        let mut cumulative_redistributed_debt: Wad = WadZeroable::zero();
        let mut cumulative_error = WadZeroable::zero();

        loop {
            match yang_addrs.pop_front() {
                Option::Some(yang) => {
                    // Calculate value liquidated for each yang
                    let deposited = shrine.get_deposit(*yang, trove);
                    let (yang_price, _, _) = shrine.get_current_yang_price(*yang);
                    let yang_value = yang_price * deposited;

                    trove_yang_values.append(yang_price * deposited);

                    // Calculate redistributed unit debt and error after redistributing debt
                    // for each yang
                    let mut expected_yang_debt = wadray::rmul_rw(
                        wadray::rdiv_ww(yang_value, trove_health.value), trove_health.debt,
                    );
                    cumulative_redistributed_debt += expected_yang_debt;
                    let remainder = trove_health.debt - cumulative_redistributed_debt;
                    if remainder < shrine_contract::ROUNDING_THRESHOLD.into() {
                        expected_yang_debt += remainder;
                        cumulative_redistributed_debt += remainder;
                    }

                    let expected_remaining_yang = shrine.get_yang_total(*yang)
                        - deposited
                        - shrine.get_initial_yang_amt(*yang);
                    let expected_unit_debt = expected_yang_debt / expected_remaining_yang;
                    expected_remaining_yangs.append(expected_remaining_yang);
                    expected_unit_debts.append(expected_unit_debt);

                    let actual_redistributed_debt = expected_unit_debt * expected_remaining_yang;
                    let expected_error = expected_yang_debt - actual_redistributed_debt;

                    cumulative_error += expected_error;

                    if remainder < shrine_contract::ROUNDING_THRESHOLD.into() {
                        break;
                    }
                },
                Option::None => { break; }
            };
        };
        (trove_yang_values.span(), expected_unit_debts.span(), expected_remaining_yangs.span(), cumulative_error)
    }

    // Returns a tuple of
    // 1. the expected debt for the recipient trove from the redistribution
    // 2. the amount of redistributed debt based on unit debt per yang
    fn assert_redistribution_is_correct(
        shrine: IShrineDispatcher,
        mut yangs: Span<ContractAddress>,
        mut expected_remaining_yangs: Span<Wad>,
        mut recipient_trove_yangs: Span<Wad>,
        redistributed_trove_id: u64,
        redistributed_trove_debt: Wad,
        redistributed_trove_value: Wad,
        mut redistributed_trove_yang_values: Span<Wad>,
        expected_redistribution_id: u32,
    ) -> (Wad, Wad) {
        let mut expected_recipient_trove_debt_increment = WadZeroable::zero();
        let mut cumulative_redistributed_debt = WadZeroable::zero();

        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    assert(shrine.get_deposit(*yang, redistributed_trove_id).is_zero(), 'deposit should be 0');

                    let recipient_trove_yang_deposit = *recipient_trove_yangs.pop_front().unwrap();
                    let remaining_yang = *expected_remaining_yangs.pop_front().unwrap();

                    // Calculate the amount of debt redistributed for the yang, checking for
                    // rounding threshold,
                    let mut expected_yang_debt = wadray::rmul_rw(
                        wadray::rdiv_ww(
                            *redistributed_trove_yang_values.pop_front().unwrap(), redistributed_trove_value
                        ),
                        redistributed_trove_debt
                    );
                    // Use a temporary variable for cumulative redistributed debt to check for rounding
                    let tmp_cumulative_redistributed_debt = cumulative_redistributed_debt + expected_yang_debt;
                    let remainder = redistributed_trove_debt - tmp_cumulative_redistributed_debt;
                    if remainder < shrine_contract::ROUNDING_THRESHOLD.into() {
                        expected_yang_debt += remainder;
                    }

                    let expected_unit_debt = expected_yang_debt / remaining_yang;
                    let redistribution_unit_debt: Wad = shrine
                        .get_redistribution_for_yang(*yang, expected_redistribution_id);

                    common::assert_equalish(
                        expected_unit_debt, redistribution_unit_debt, 2_u128.into(), 'wrong unit debt'
                    );

                    expected_recipient_trove_debt_increment += recipient_trove_yang_deposit * expected_unit_debt;

                    // Calculate cumulative redistributed debt for subsequent check
                    let expected_cumulative_increment = remaining_yang * expected_unit_debt;
                    cumulative_redistributed_debt += expected_cumulative_increment;
                    let expected_error = expected_yang_debt - expected_cumulative_increment;
                    cumulative_redistributed_debt += expected_error;
                },
                Option::None => { break; }
            };
        };
        (expected_recipient_trove_debt_increment, cumulative_redistributed_debt)
    }

    //
    // Tests
    //

    #[test]
    fn test_shrine_one_redistribution() {
        let shrine: IShrineDispatcher = redistribution_setup(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));
        let before_trove2_health: Health = shrine.get_trove_health(common::TROVE_2);

        // Note order is reversed to match `yangs`
        let mut trove2_yang_deposits: Array<Wad> = array![TROVE2_YANG2_DEPOSIT.into(), TROVE2_YANG1_DEPOSIT.into()];
        let mut trove2_yang_deposits = trove2_yang_deposits.span();

        let redistributed_trove: u64 = common::TROVE_1;
        let recipient_trove: u64 = common::TROVE_2;
        let yangs: Span<ContractAddress> = shrine_utils::two_yang_addrs_reversed();
        let (trove1_yang_values, _, expected_remaining_yangs, _) = preview_trove_redistribution(
            shrine, yangs, redistributed_trove
        );

        // Simulate purge with 0 yin to update the trove's debt
        start_prank(CheatTarget::All, shrine_utils::admin());
        let trove1_owner = common::trove1_owner_addr();
        let trove1_health: Health = shrine.get_trove_health(redistributed_trove);
        shrine.melt(trove1_owner, redistributed_trove, WadZeroable::zero());

        assert(shrine.get_redistributions_count() == 0, 'wrong start state');
        shrine.redistribute(redistributed_trove, trove1_health.debt, RAY_ONE.into());

        let unpulled_debt: Wad = shrine.get_redistributed_debt_for_trove(redistributed_trove);
        assert(unpulled_debt.is_zero(), 'should be zero');

        let expected_redistribution_id: u32 = 1;
        assert(shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count');

        let (expected_trove2_debt_increment, cumulative_redistributed_debt) = assert_redistribution_is_correct(
            shrine,
            yangs,
            expected_remaining_yangs,
            trove2_yang_deposits,
            redistributed_trove,
            trove1_health.debt,
            trove1_health.value,
            trove1_yang_values,
            expected_redistribution_id,
        );

        let expected_trove2_debt = before_trove2_health.debt + expected_trove2_debt_increment;

        // Check invariant of [(yang1_total * yang1_unit_debt + error) + ... (yang2 ...) + rounding]
        // is equal to redistributed trove's debt
        assert(cumulative_redistributed_debt == trove1_health.debt, 'wrong redistributed debt');

        let after_trove2_health: Health = shrine.get_trove_health(recipient_trove);

        assert(after_trove2_health.debt == expected_trove2_debt, 'wrong debt after redistribution');

        assert(shrine.get_trove_redistribution_id(recipient_trove) == 0, 'wrong redistribution id');

        let unpulled_debt: Wad = shrine.get_redistributed_debt_for_trove(recipient_trove);
        assert(unpulled_debt == expected_trove2_debt_increment, 'wrong attributed debt');

        // Trigger an update in trove 2 with an empty melt
        shrine.melt(trove1_owner, recipient_trove, WadZeroable::zero());
        assert(shrine.get_trove_redistribution_id(recipient_trove) == expected_redistribution_id, 'wrong id');

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::TroveRedistributed(
                    shrine_contract::TroveRedistributed {
                        redistribution_id: expected_redistribution_id,
                        trove_id: redistributed_trove,
                        debt: trove1_health.debt,
                    }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);

        shrine_utils::assert_shrine_invariants(shrine, yangs, 3);
    }

    #[test]
    fn test_shrine_two_redistributions() {
        let shrine: IShrineDispatcher = redistribution_setup(Option::None);

        let redistributed_trove1: u64 = common::TROVE_1;
        let redistributed_trove2: u64 = common::TROVE_2;
        let recipient_trove: u64 = common::TROVE_3;

        let yangs: Span<ContractAddress> = shrine_utils::two_yang_addrs_reversed();
        let (_, _, _, expected_redistributed_trove1_errors) = preview_trove_redistribution(
            shrine, yangs, redistributed_trove1
        );
        let before_troves_deficit: SignedWad = shrine.get_total_troves_deficit();
        let before_budget: SignedWad = shrine.get_budget();

        // Perform first redistribution - covered by previous test
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.melt(common::trove1_owner_addr(), redistributed_trove1, WadZeroable::zero());

        let redistributed_trove1_health: Health = shrine.get_trove_health(redistributed_trove1);
        let redistributed_trove2_start_health = shrine.get_trove_health(redistributed_trove2);
        shrine.redistribute(redistributed_trove1, redistributed_trove1_health.debt, RAY_ONE.into());

        let intermediate_troves_deficit: SignedWad = shrine.get_total_troves_deficit();
        let intermediate_budget: SignedWad = shrine.get_budget();
        assert_eq!(
            intermediate_troves_deficit,
            before_troves_deficit - expected_redistributed_trove1_errors.into(),
            "wrong troves deficit #1"
        );
        assert_eq!(intermediate_budget, before_budget - expected_redistributed_trove1_errors.into(), "wrong budget #1");

        let before_recipient_trove_health: Health = shrine.get_trove_health(recipient_trove);

        let (mut redistributed_trove2_yang_values, _, expected_remaining_yangs, expected_redistributed_trove2_errors) =
            preview_trove_redistribution(
            shrine, yangs, redistributed_trove2
        );

        // Perform second redistribution
        shrine.melt(common::trove2_owner_addr(), redistributed_trove2, WadZeroable::zero());
        let redistributed_trove2_health: Health = shrine.get_trove_health(redistributed_trove2);

        shrine.redistribute(redistributed_trove2, redistributed_trove2_health.debt, RAY_ONE.into());

        let after_troves_deficit: SignedWad = shrine.get_total_troves_deficit();
        let after_budget: SignedWad = shrine.get_budget();
        let error_margin = SignedWad { val: 10_u128, sign: false };
        common::assert_equalish(
            after_troves_deficit,
            intermediate_troves_deficit - expected_redistributed_trove2_errors.into(),
            error_margin,
            'wrong troves deficit #2'
        );
        common::assert_equalish(
            after_budget,
            intermediate_budget - expected_redistributed_trove2_errors.into(),
            error_margin,
            'wrong budget #2'
        );

        let unpulled_debt: Wad = shrine.get_redistributed_debt_for_trove(redistributed_trove2);
        assert(unpulled_debt.is_zero(), 'should be zero');

        let expected_redistribution_id: u32 = 2;
        assert(shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count');

        let (expected_recipient_trove_debt_increment, cumulative_redistributed_debt) = assert_redistribution_is_correct(
            shrine,
            yangs,
            expected_remaining_yangs,
            expected_remaining_yangs, // Trove 3 is the only remaining trove
            redistributed_trove2,
            redistributed_trove2_health.debt,
            redistributed_trove2_health.value,
            redistributed_trove2_yang_values,
            expected_redistribution_id,
        );

        let expected_recipient_trove_debt = before_recipient_trove_health.debt
            + expected_recipient_trove_debt_increment;

        // Check invariant of [(yang1_total * yang1_unit_debt + error) + ... (yang2 ...) + rounding]
        // is equal to redistributed trove's debt
        assert(redistributed_trove2_health.debt == cumulative_redistributed_debt, 'wrong redistributed debt');

        let after_recipient_trove_health: Health = shrine.get_trove_health(recipient_trove);
        common::assert_equalish(
            after_recipient_trove_health.debt,
            expected_recipient_trove_debt,
            10_u128.into(),
            'wrong debt after redistribution'
        );

        assert(shrine.get_trove_redistribution_id(recipient_trove) == 0, 'wrong redistribution id');

        let unpulled_debt: Wad = shrine.get_redistributed_debt_for_trove(recipient_trove);
        let expected_recipient_trove_debt_total_increment = redistributed_trove1_health.debt
            + redistributed_trove2_start_health.debt
            - expected_redistributed_trove1_errors
            - expected_redistributed_trove2_errors;
        common::assert_equalish(
            unpulled_debt, expected_recipient_trove_debt_total_increment, 10_u128.into(), 'wrong attributed debt'
        );

        // Trigger an update in trove 3 with an empty melt
        shrine.melt(common::trove2_owner_addr(), recipient_trove, WadZeroable::zero());
        assert(shrine.get_trove_redistribution_id(recipient_trove) == expected_redistribution_id, 'wrong id');

        shrine_utils::assert_shrine_invariants(shrine, yangs, 3);
    }

    // Parametrized test to check that partial redistribution of a trove results in the correct
    // value and debt for the redistributed trove.
    #[test]
    fn test_shrine_redistribution_parametrized() {
        let shrine_class = shrine_utils::declare_shrine();

        let mut percentages: Array<Ray> = array![
            (15 * RAY_PERCENT).into(), (99 * RAY_PERCENT).into(), (100 * RAY_PERCENT).into(), RayZeroable::zero(),
        ];

        let mut pct_value_to_redistribute_arr = percentages.span();
        let mut pct_debt_to_redistribute_arr = percentages.span();

        let mut salt: felt252 = 0;
        loop {
            match pct_value_to_redistribute_arr.pop_front() {
                Option::Some(pct_value_to_redistribute) => {
                    loop {
                        match pct_debt_to_redistribute_arr.pop_front() {
                            Option::Some(pct_debt_to_redistribute) => {
                                let shrine: IShrineDispatcher = redistribution_setup(Option::Some(shrine_class));
                                let mut spy = spy_events(SpyOn::One(shrine.contract_address));

                                let yangs: Span<ContractAddress> = shrine_utils::two_yang_addrs_reversed();
                                let redistributed_trove = common::TROVE_1;

                                // Simulate purge with 0 yin to update the trove's debt
                                start_prank(CheatTarget::All, shrine_utils::admin());
                                let trove1_owner = common::trove1_owner_addr();
                                let before_redistributed_trove_health: Health = shrine
                                    .get_trove_health(redistributed_trove);
                                shrine.melt(trove1_owner, redistributed_trove, WadZeroable::zero());

                                assert(shrine.get_redistributions_count() == 0, 'wrong start state');
                                let debt_to_redistribute: Wad = wadray::rmul_wr(
                                    before_redistributed_trove_health.debt, *pct_debt_to_redistribute
                                );
                                shrine
                                    .redistribute(
                                        redistributed_trove, debt_to_redistribute, *pct_value_to_redistribute
                                    );

                                let after_redistributed_trove_health: Health = shrine
                                    .get_trove_health(redistributed_trove);
                                assert(
                                    after_redistributed_trove_health.debt == before_redistributed_trove_health.debt
                                        - debt_to_redistribute,
                                    'wrong redistributed trove debt'
                                );

                                let expected_redistribution_id: u32 = 1;

                                let expected_events = array![
                                    (
                                        shrine.contract_address,
                                        shrine_contract::Event::TroveRedistributed(
                                            shrine_contract::TroveRedistributed {
                                                redistribution_id: expected_redistribution_id,
                                                trove_id: redistributed_trove,
                                                debt: debt_to_redistribute,
                                            }
                                        )
                                    ),
                                ];

                                spy.assert_emitted(@expected_events);

                                shrine_utils::assert_shrine_invariants(shrine, yangs, 3);
                                // We are unable to test the trove value in a sensible way here because
                                // the yang price has not been updated to reflect any rebasing of the
                                // asset amount per yang wad. Instead, refer to the tests for purger
                                // for assertions on the redistributed trove's value.
                                salt += 1;
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
    fn test_shrine_redistribute_dust_yang_rounding() {
        // Manually set up troves so that the redistributed trove has a dust amount of one yang
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        start_prank(CheatTarget::All, shrine_utils::admin());
        setup_trove1(shrine);
        setup_trove3(shrine);

        let yang1_addr = shrine_utils::yang1_addr();
        let yang2_addr = shrine_utils::yang2_addr();

        let trove2_owner = common::trove2_owner_addr();
        let redistributed_trove = common::TROVE_2;
        let trove2_yang1_amt: Wad = 1000000000000000000000_u128.into(); // 1E-15 (Wad)
        let trove2_yang2_amt: Wad = 1000_u128.into(); // 1_000 (Wad)
        shrine.deposit(yang1_addr, redistributed_trove, trove2_yang1_amt);
        shrine.deposit(yang2_addr, redistributed_trove, trove2_yang2_amt);
        shrine.forge(trove2_owner, redistributed_trove, TROVE2_FORGE_AMT.into(), 0_u128.into());

        // Get information before redistribution
        let trove2_health: Health = shrine.get_trove_health(redistributed_trove);

        // Sanity check that the amount of debt attributed to YANG_2 falls below the threshold
        let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr);
        let expected_yang2_redistributed_value = trove2_yang2_amt * yang2_price;

        let trove2_yang2_debt = wadray::rmul_rw(
            wadray::rdiv_ww(expected_yang2_redistributed_value, trove2_health.value), trove2_health.debt
        );
        assert(trove2_yang2_debt < shrine_contract::ROUNDING_THRESHOLD.into(), 'not below rounding threshold');

        // Redistribute trove 2
        shrine.melt(trove2_owner, redistributed_trove, WadZeroable::zero());
        shrine.redistribute(redistributed_trove, trove2_health.debt, RAY_ONE.into());

        let unpulled_debt: Wad = shrine.get_redistributed_debt_for_trove(redistributed_trove);
        assert(unpulled_debt.is_zero(), 'should be zero');

        // Check that yang 1 unit debt is zero
        let expected_redistribution_id: u32 = 1;
        assert(shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count');
        assert(
            shrine.get_redistribution_for_yang(yang2_addr, expected_redistribution_id).is_zero(), 'should be skipped'
        );

        // Check trove 2 has no yang 1, and some amount of yang 2.
        assert(shrine.get_deposit(yang1_addr, redistributed_trove).is_zero(), 'yang 1 should be zero');
        assert(shrine.get_deposit(yang2_addr, redistributed_trove).is_non_zero(), 'yang 2 should not be zero');

        // Check that all of trove 2's debt was distributed to yang 1
        let expected_remaining_yang1: Wad = (shrine_utils::TROVE1_YANG1_DEPOSIT + TROVE3_YANG1_DEPOSIT).into();
        let expected_unit_debt_for_yang2 = trove2_health.debt / expected_remaining_yang1;
        assert(
            shrine.get_redistribution_for_yang(yang1_addr, expected_redistribution_id) == expected_unit_debt_for_yang2,
            'wrong unit debt'
        );

        shrine_utils::assert_shrine_invariants(shrine, shrine_utils::two_yang_addrs(), 3);
    }

    #[test]
    fn test_exceptional_redistributions() {
        let shrine_class = shrine_utils::declare_shrine();

        let mut pct_value_to_redistribute_arr: Span<Ray> = array![
            RAY_PERCENT.into(), (50 * RAY_PERCENT).into(), (RAY_ONE - 1).into(), RAY_ONE.into(),
        ]
            .span();

        loop {
            match pct_value_to_redistribute_arr.pop_front() {
                Option::Some(pct_value_to_redistribute) => {
                    let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::Some(shrine_class));
                    let mut spy = spy_events(SpyOn::One(shrine.contract_address));

                    // Manually set up troves so that the redistributed trove (trove 1) uses all three yangs
                    // while the recipient troves (trove 2 and 3) uses only yang 2.
                    let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs_reversed();
                    let yang1_addr = *yangs.at(2);
                    let yang2_addr = *yangs.at(1);
                    let yang3_addr = *yangs.at(0);

                    let trove1_owner = common::trove1_owner_addr();
                    let redistributed_trove: u64 = common::TROVE_1;

                    start_prank(CheatTarget::All, shrine_utils::admin());
                    let redistributed_trove_debt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
                    shrine.deposit(yang1_addr, redistributed_trove, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
                    shrine.deposit(yang2_addr, redistributed_trove, shrine_utils::TROVE1_YANG2_DEPOSIT.into());
                    shrine.deposit(yang3_addr, redistributed_trove, shrine_utils::TROVE1_YANG3_DEPOSIT.into());
                    shrine.forge(trove1_owner, redistributed_trove, redistributed_trove_debt, 0_u128.into());

                    let trove2_owner = common::trove2_owner_addr();
                    let recipient_trove1: u64 = common::TROVE_2;
                    shrine.deposit(yang2_addr, recipient_trove1, TROVE2_YANG2_DEPOSIT.into());
                    shrine.forge(trove2_owner, recipient_trove1, TROVE2_FORGE_AMT.into(), 0_u128.into());

                    let trove3_owner = common::trove3_owner_addr();
                    let recipient_trove2: u64 = common::TROVE_3;
                    shrine.deposit(yang2_addr, recipient_trove2, TROVE3_YANG2_DEPOSIT.into());
                    shrine.forge(trove3_owner, recipient_trove2, TROVE3_FORGE_AMT.into(), 0_u128.into());

                    let before_redistributed_trove_health: Health = shrine.get_trove_health(redistributed_trove);
                    let expected_redistributed_value: Wad = wadray::rmul_wr(
                        before_redistributed_trove_health.value, *pct_value_to_redistribute
                    );

                    let before_recipient_trove1_health: Health = shrine.get_trove_health(recipient_trove1);
                    let before_recipient_trove2_health: Health = shrine.get_trove_health(recipient_trove2);

                    let before_redistributed_trove_yang1_amt: Wad = wadray::rmul_wr(
                        shrine.get_deposit(yang1_addr, redistributed_trove), *pct_value_to_redistribute
                    );
                    let before_redistributed_trove_yang2_amt: Wad = wadray::rmul_wr(
                        shrine.get_deposit(yang2_addr, redistributed_trove), *pct_value_to_redistribute
                    );
                    let before_redistributed_trove_yang3_amt: Wad = wadray::rmul_wr(
                        shrine.get_deposit(yang3_addr, redistributed_trove), *pct_value_to_redistribute
                    );

                    let before_yang1_total: Wad = shrine.get_yang_total(yang1_addr);
                    let before_yang2_total: Wad = shrine.get_yang_total(yang2_addr);
                    let before_yang3_total: Wad = shrine.get_yang_total(yang3_addr);

                    let before_yang1_initial_amt: Wad = shrine.get_initial_yang_amt(yang1_addr);
                    let before_yang2_initial_amt: Wad = shrine.get_initial_yang_amt(yang2_addr);
                    let before_yang3_initial_amt: Wad = shrine.get_initial_yang_amt(yang3_addr);

                    let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr);
                    let redistributed_trove_yang2_value: Wad = wadray::rmul_wr(
                        shrine.get_deposit(yang2_addr, redistributed_trove), *pct_value_to_redistribute
                    )
                        * yang2_price;
                    let expected_redistributed_trove_yang2_debt: Wad = (redistributed_trove_yang2_value
                        / expected_redistributed_value)
                        * before_redistributed_trove_health.debt;

                    let before_budget: SignedWad = shrine.get_budget();
                    let before_troves_deficit: SignedWad = shrine.get_total_troves_deficit();

                    // Simulate purge with 0 yin to update the trove's debt
                    shrine.melt(trove1_owner, redistributed_trove, WadZeroable::zero());
                    shrine
                        .redistribute(
                            redistributed_trove, before_redistributed_trove_health.debt, *pct_value_to_redistribute
                        );
                    let expected_redistribution_id: u32 = 1;
                    assert(
                        shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count'
                    );

                    // Check redistributions attributed to recipient troves
                    let recipient_troves_yang2_amt: Wad = (TROVE2_YANG2_DEPOSIT + TROVE3_YANG2_DEPOSIT).into();

                    let expected_recipient_trove1_attr_debt: Wad = expected_redistributed_trove_yang2_debt
                        * (TROVE2_YANG2_DEPOSIT.into() / recipient_troves_yang2_amt);
                    let expected_recipient_trove2_attr_debt: Wad = expected_redistributed_trove_yang2_debt
                        * (TROVE3_YANG2_DEPOSIT.into() / recipient_troves_yang2_amt);

                    let recipient_trove1_attr_debt: Wad = shrine.get_redistributed_debt_for_trove(recipient_trove1);
                    common::assert_equalish(
                        recipient_trove1_attr_debt,
                        expected_recipient_trove1_attr_debt,
                        (WAD_ONE / 100).into(),
                        'wrong attributed debt #1'
                    );

                    let recipient_trove2_attr_debt: Wad = shrine.get_redistributed_debt_for_trove(recipient_trove2);
                    common::assert_equalish(
                        recipient_trove2_attr_debt,
                        expected_recipient_trove2_attr_debt,
                        (WAD_ONE / 100).into(),
                        'wrong attributed debt #2'
                    );

                    // Check that each yang's total and initial yang amounts are correct
                    // Yangs 1 and 3 should have total unchanged, and initial amounts changed.
                    // yang 2 should have total decreased, and initial amount unchanged.
                    let after_yang1_total: Wad = shrine.get_yang_total(yang1_addr);
                    let after_yang2_total: Wad = shrine.get_yang_total(yang2_addr);
                    let after_yang3_total: Wad = shrine.get_yang_total(yang3_addr);

                    let after_yang1_initial_amt: Wad = shrine.get_initial_yang_amt(yang1_addr);
                    let after_yang2_initial_amt: Wad = shrine.get_initial_yang_amt(yang2_addr);
                    let after_yang3_initial_amt: Wad = shrine.get_initial_yang_amt(yang3_addr);

                    if *pct_value_to_redistribute == RAY_ONE.into() {
                        // strict equality because there is no offset since redistributed trove 
                        // has no yang2 remaining
                        assert_eq!(
                            after_yang2_total,
                            before_yang2_total - before_redistributed_trove_yang2_amt,
                            "wrong yang2 total"
                        );
                    } else {
                        // le because there is an offset to account for redistributed trove having
                        // yang2 remaining
                        assert(
                            after_yang2_total < before_yang2_total - before_redistributed_trove_yang2_amt,
                            'wrong yang2 total'
                        );
                    }
                    assert_eq!(after_yang2_initial_amt, before_yang2_initial_amt, "wrong initial yang2");

                    assert_eq!(after_yang1_total, before_yang1_total, "wrong yang1 total");
                    assert_eq!(
                        after_yang1_initial_amt,
                        before_yang1_initial_amt + before_redistributed_trove_yang1_amt,
                        "wrong initial yang1"
                    );
                    assert_eq!(after_yang3_total, before_yang3_total, "wrong yang3 total");
                    assert_eq!(
                        after_yang3_initial_amt,
                        before_yang3_initial_amt + before_redistributed_trove_yang3_amt,
                        "wrong initial yang3"
                    );

                    // Check that the debt for yangs 1 and 3 have been added to the budget as deficit
                    let after_budget: SignedWad = shrine.get_budget();
                    let budget_diff: SignedWad = after_budget - before_budget;
                    let expected_budget_deficit = SignedWad {
                        val: redistributed_trove_debt.val - expected_redistributed_trove_yang2_debt.val, sign: true
                    };
                    common::assert_equalish(
                        budget_diff,
                        expected_budget_deficit,
                        SignedWad { val: WAD_ONE / 100, sign: false },
                        'wrong budget deficit'
                    );

                    let after_troves_deficit: SignedWad = shrine.get_total_troves_deficit();
                    let troves_deficit_diff: SignedWad = after_troves_deficit - before_troves_deficit;
                    assert_eq!(troves_deficit_diff, budget_diff, "troves deficit != budget deficit");

                    // Trigger an update in recipient troves with an empty melt
                    shrine.melt(trove1_owner, recipient_trove1, WadZeroable::zero());
                    shrine.melt(trove1_owner, recipient_trove2, WadZeroable::zero());

                    assert(
                        shrine.get_trove_redistribution_id(recipient_trove1) == expected_redistribution_id, 'wrong id'
                    );
                    assert(
                        shrine.get_trove_redistribution_id(recipient_trove2) == expected_redistribution_id, 'wrong id'
                    );

                    let after_recipient_trove1_health: Health = shrine.get_trove_health(recipient_trove1);
                    let after_recipient_trove2_health: Health = shrine.get_trove_health(recipient_trove2);

                    //
                    // Debt assertions
                    //

                    // Check that recipient troves receives their proportion of trove 1's entire debt
                    let expected_recipient_trove1_debt: Wad = before_recipient_trove1_health.debt
                        + expected_recipient_trove1_attr_debt;
                    common::assert_equalish(
                        after_recipient_trove1_health.debt,
                        expected_recipient_trove1_debt,
                        (WAD_ONE / 100).into(), // error margin
                        'wrong recipient trove 1 debt',
                    );

                    let expected_recipient_trove2_debt: Wad = before_recipient_trove2_health.debt
                        + expected_recipient_trove2_attr_debt;
                    common::assert_equalish(
                        after_recipient_trove2_health.debt,
                        expected_recipient_trove2_debt,
                        (WAD_ONE / 100).into(), // error margin
                        'wrong recipient trove 2 debt',
                    );

                    let yang2_redistribution_unit_debt: Wad = shrine
                        .get_redistribution_for_yang(yang2_addr, expected_redistribution_id);
                    let actual_redistributed_debt: Wad = recipient_troves_yang2_amt * yang2_redistribution_unit_debt;
                    assert(
                        before_redistributed_trove_health.debt == actual_redistributed_debt + budget_diff.val.into(),
                        'debt invariant failed'
                    );

                    let expected_events = array![
                        (
                            shrine.contract_address,
                            shrine_contract::Event::TroveRedistributed(
                                shrine_contract::TroveRedistributed {
                                    redistribution_id: expected_redistribution_id,
                                    trove_id: redistributed_trove,
                                    debt: before_redistributed_trove_health.debt,
                                }
                            )
                        ),
                    ];
                    spy.assert_emitted(@expected_events);

                    shrine_utils::assert_shrine_invariants(shrine, yangs, 3);
                },
                Option::None => { break; }
            };
        };
    }

    // Redistribution with only 1 trove.
    // Since the trove's yangs are zeroed, the initial yang would essentially "receive"
    // the trove's value via rebasing. The trove's debt would also be zeroed even though
    // it was not distributed at all. However, the debt would still be backed, and the
    // value can be accessed in the event of a shutdown.
    #[test]
    fn test_shrine_redistribution_only_one_trove_remaining() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        start_prank(CheatTarget::All, shrine_utils::admin());
        setup_trove1(shrine);

        // Simulate purge with 0 yin to update the trove's debt
        start_prank(CheatTarget::All, shrine_utils::admin());
        let trove1_owner = common::trove1_owner_addr();
        let redistributed_trove = common::TROVE_1;
        let redistributed_trove_health: Health = shrine.get_trove_health(redistributed_trove);
        shrine.melt(trove1_owner, redistributed_trove, WadZeroable::zero());

        assert(shrine.get_redistributions_count() == 0, 'wrong start state');
        shrine.redistribute(redistributed_trove, redistributed_trove_health.debt, RAY_ONE.into());

        let expected_redistribution_id: u32 = 1;
        assert(shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count');

        let after_trove_health: Health = shrine.get_trove_health(common::TROVE_2);
        assert(after_trove_health.value.is_zero(), 'wrong value post redistribution');
        assert(after_trove_health.debt.is_zero(), 'wrong debt after redistribution');

        assert(shrine.get_trove_redistribution_id(common::TROVE_2) == 0, 'wrong redistribution id');
        // Trigger an update in trove 2 with an empty melt
        shrine.melt(trove1_owner, common::TROVE_2, WadZeroable::zero());
        assert(shrine.get_trove_redistribution_id(common::TROVE_2) == expected_redistribution_id, 'wrong id');

        shrine_utils::assert_shrine_invariants(shrine, shrine_utils::two_yang_addrs(), 3);
    }

    // This test asserts that the sum of troves' debt after pulling redistributed debt does not
    // exceed the total debt.
    // Note that yangs 1 and 2 are normally redistributed, and yang 3 is exceptionally
    // redistributed.
    #[test]
    fn test_multi_troves_system_debt_not_exceeded() {
        let shrine: IShrineDispatcher = redistribution_setup(Option::None);

        let yangs: Span<ContractAddress> = shrine_utils::two_yang_addrs();
        let yang1_addr = *yangs.at(0);
        let yang2_addr = *yangs.at(1);

        // Create another 10 troves with different collateral amounts
        let mut idx: u64 = 0;
        let new_troves_count: u64 = 10;
        start_prank(CheatTarget::All, shrine_utils::admin());
        loop {
            if idx == new_troves_count {
                break;
            }

            let trove_idx: u64 = 4 + idx;
            let tmp_multiplier: u128 = (idx + 1).into();
            shrine.deposit(yang1_addr, trove_idx, (tmp_multiplier * 100000000000000000).into()); // idx * 0.1 Wad
            shrine.deposit(yang2_addr, trove_idx, (tmp_multiplier * 200000000000000000).into()); // idx * 0.2 Wad

            idx += 1;
        };

        shrine.redistribute(common::TROVE_1, shrine_utils::TROVE1_FORGE_AMT.into(), RAY_ONE.into());

        shrine_utils::assert_shrine_invariants(shrine, yangs, 13);
    }

    #[test]
    #[should_panic(expected: ('SH: pct_val_to_redistribute > 1',))]
    fn test_shrine_redistribution_gt_one_ray_pct_value_to_redistribute_fail() {
        let shrine: IShrineDispatcher = redistribution_setup(Option::None);

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.redistribute(common::TROVE_1, 1_u128.into(), (RAY_ONE + RAY_PERCENT).into());
    }
}
