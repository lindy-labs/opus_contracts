mod test_shrine_redistribution {
    use core::num::traits::Zero;
    use opus::core::shrine::shrine as shrine_contract;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::{Health, YangSuspensionStatus};
    use snforge_std::{ContractClass, EventSpyAssertionsTrait, spy_events, start_cheat_caller_address};
    use starknet::ContractAddress;
    use wadray::{RAY_ONE, RAY_PERCENT, Ray, SignedWad, WAD_ONE, Wad};

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
        let yang1_addr = shrine_utils::YANG1_ADDR;
        let yang2_addr = shrine_utils::YANG2_ADDR;

        let trove1_owner = common::TROVE1_OWNER_ADDR;
        shrine.deposit(yang1_addr, common::TROVE_1, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, common::TROVE_1, shrine_utils::TROVE1_YANG2_DEPOSIT.into());
        shrine.forge(trove1_owner, common::TROVE_1, shrine_utils::TROVE1_FORGE_AMT.into(), Zero::zero());
    }

    fn setup_trove2(shrine: IShrineDispatcher) {
        let yang1_addr = shrine_utils::YANG1_ADDR;
        let yang2_addr = shrine_utils::YANG2_ADDR;

        let trove2_owner = common::TROVE2_OWNER_ADDR;
        shrine.deposit(yang1_addr, common::TROVE_2, TROVE2_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, common::TROVE_2, TROVE2_YANG2_DEPOSIT.into());
        shrine.forge(trove2_owner, common::TROVE_2, TROVE2_FORGE_AMT.into(), Zero::zero());
    }

    fn setup_trove3(shrine: IShrineDispatcher) {
        let yang1_addr = shrine_utils::YANG1_ADDR;
        let yang2_addr = shrine_utils::YANG2_ADDR;

        let trove3_owner = common::TROVE3_OWNER_ADDR;
        shrine.deposit(yang1_addr, common::TROVE_3, TROVE3_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, common::TROVE_3, TROVE3_YANG2_DEPOSIT.into());
        shrine.forge(trove3_owner, common::TROVE_3, TROVE3_FORGE_AMT.into(), Zero::zero());
    }

    // Helper function to set up three troves
    // - Trove 1 deposits and forges the amounts specified in `src/tests/shrine/utils.cairo`
    // - Troves 2 and 3 deposits and forges the amounts specified in this file
    fn redistribution_setup(shrine_class: Option<ContractClass>) -> IShrineDispatcher {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(shrine_class);

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        setup_trove1(shrine);
        setup_trove2(shrine);
        setup_trove3(shrine);

        shrine
    }

    // Returns a tuple of arrays which are the expected values from redistributing a trove
    // - value liquidated for each yang
    // - unit debt after redistributing debt for each yang
    // - expected amount of yangs remaining after redistribution
    // - total error from all yangs added to the protocol owned troves' debt
    // Note that once the remaining redistribution value falls below the threshold, an early
    // return will be performed, so yangs with dust value of debt will not be included.
    fn preview_trove_redistribution(
        shrine: IShrineDispatcher, mut yang_addrs: Span<ContractAddress>, trove: u64,
    ) -> (Span<Wad>, Span<Wad>, Span<Wad>, Wad) {
        let trove_health: Health = shrine.get_trove_health(trove);

        let mut trove_yang_values: Array<Wad> = ArrayTrait::new();
        let mut expected_unit_debts: Array<Wad> = ArrayTrait::new();
        let mut expected_remaining_yangs: Array<Wad> = ArrayTrait::new();
        let mut cumulative_redistributed_debt: Wad = Zero::zero();
        let mut cumulative_error = Zero::zero();

        for yang in yang_addrs {
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
                - shrine.get_protocol_owned_yang_amt(*yang);
            let expected_unit_debt = expected_yang_debt / expected_remaining_yang;
            expected_remaining_yangs.append(expected_remaining_yang);
            expected_unit_debts.append(expected_unit_debt);

            let actual_redistributed_debt = expected_unit_debt * expected_remaining_yang;
            let expected_error = expected_yang_debt - actual_redistributed_debt;

            cumulative_error += expected_error;

            if remainder < shrine_contract::ROUNDING_THRESHOLD.into() {
                break;
            }
        }
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
        let mut expected_recipient_trove_debt_increment = Zero::zero();
        let mut cumulative_redistributed_debt = Zero::zero();

        for yang in yangs {
            assert(shrine.get_deposit(*yang, redistributed_trove_id).is_zero(), 'deposit should be 0');

            let recipient_trove_yang_deposit = *recipient_trove_yangs.pop_front().unwrap();
            let remaining_yang = *expected_remaining_yangs.pop_front().unwrap();

            // Calculate the amount of debt redistributed for the yang, checking for
            // rounding threshold,
            let mut expected_yang_debt = wadray::rmul_rw(
                wadray::rdiv_ww(*redistributed_trove_yang_values.pop_front().unwrap(), redistributed_trove_value),
                redistributed_trove_debt,
            );
            // Use a temporary variable for cumulative redistributed debt to check for rounding
            let tmp_cumulative_redistributed_debt = cumulative_redistributed_debt + expected_yang_debt;
            let remainder = redistributed_trove_debt - tmp_cumulative_redistributed_debt;
            if remainder < shrine_contract::ROUNDING_THRESHOLD.into() {
                expected_yang_debt += remainder;
            }

            let expected_unit_debt = expected_yang_debt / remaining_yang;
            let redistribution_unit_debt: Wad = shrine.get_redistribution_for_yang(*yang, expected_redistribution_id);

            common::assert_equalish(expected_unit_debt, redistribution_unit_debt, 2_u128.into(), 'wrong unit debt');

            expected_recipient_trove_debt_increment += recipient_trove_yang_deposit * expected_unit_debt;

            // Calculate cumulative redistributed debt for subsequent check
            let expected_cumulative_increment = remaining_yang * expected_unit_debt;
            cumulative_redistributed_debt += expected_cumulative_increment;
            let expected_error = expected_yang_debt - expected_cumulative_increment;
            cumulative_redistributed_debt += expected_error;
        }
        (expected_recipient_trove_debt_increment, cumulative_redistributed_debt)
    }

    //
    // Tests
    //

    #[test]
    fn test_shrine_one_redistribution() {
        let shrine: IShrineDispatcher = redistribution_setup(Option::None);
        let mut spy = spy_events();
        let before_trove2_health: Health = shrine.get_trove_health(common::TROVE_2);

        // Note order is reversed to match `yangs`
        let mut trove2_yang_deposits: Array<Wad> = array![TROVE2_YANG2_DEPOSIT.into(), TROVE2_YANG1_DEPOSIT.into()];
        let mut trove2_yang_deposits = trove2_yang_deposits.span();

        let redistributed_trove: u64 = common::TROVE_1;
        let recipient_trove: u64 = common::TROVE_2;
        let yangs: Span<ContractAddress> = shrine_utils::two_yang_addrs_reversed();
        let (trove1_yang_values, _, expected_remaining_yangs, expected_error) = preview_trove_redistribution(
            shrine, yangs, redistributed_trove,
        );
        let before_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();

        // Simulate purge with 0 yin to update the trove's debt
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        let trove1_owner = common::TROVE1_OWNER_ADDR;
        let trove1_health: Health = shrine.get_trove_health(redistributed_trove);
        shrine.melt(trove1_owner, redistributed_trove, Zero::zero());

        assert(shrine.get_redistributions_count() == 0, 'wrong start state');
        shrine.redistribute(redistributed_trove, trove1_health.debt, RAY_ONE.into());

        let unpulled_debt: Wad = shrine.get_redistributed_debt_for_trove(redistributed_trove);
        assert(unpulled_debt.is_zero(), 'should be zero');

        let after_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();
        let error_margin: Wad = 10_u128.into();
        common::assert_equalish(
            after_protocol_owned_troves_debt,
            before_protocol_owned_troves_debt + expected_error,
            error_margin,
            'wrong protocol debt',
        );

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

        common::assert_equalish(
            after_trove2_health.debt, expected_trove2_debt, error_margin, 'wrong debt after redistribution',
        );

        assert(shrine.get_trove_redistribution_id(recipient_trove) == 0, 'wrong redistribution id');

        let unpulled_debt: Wad = shrine.get_redistributed_debt_for_trove(recipient_trove);
        assert(unpulled_debt == expected_trove2_debt_increment, 'wrong attributed debt');

        // Trigger an update in trove 2 with an empty melt
        shrine.melt(trove1_owner, recipient_trove, Zero::zero());
        assert(shrine.get_trove_redistribution_id(recipient_trove) == expected_redistribution_id, 'wrong id');

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::TroveRedistributed(
                    shrine_contract::TroveRedistributed {
                        redistribution_id: expected_redistribution_id,
                        trove_id: redistributed_trove,
                        debt: trove1_health.debt,
                    },
                ),
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
            shrine, yangs, redistributed_trove1,
        );
        let before_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();

        // Perform first redistribution - covered by previous test
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.melt(common::TROVE1_OWNER_ADDR, redistributed_trove1, Zero::zero());

        let redistributed_trove1_health: Health = shrine.get_trove_health(redistributed_trove1);
        let redistributed_trove2_start_health = shrine.get_trove_health(redistributed_trove2);
        shrine.redistribute(redistributed_trove1, redistributed_trove1_health.debt, RAY_ONE.into());

        let error_margin = 10_u128.into();
        let intermediate_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();
        common::assert_equalish(
            intermediate_protocol_owned_troves_debt,
            before_protocol_owned_troves_debt + expected_redistributed_trove1_errors,
            error_margin,
            'wrong protocol debt #1',
        );

        let before_recipient_trove_health: Health = shrine.get_trove_health(recipient_trove);

        let (mut redistributed_trove2_yang_values, _, expected_remaining_yangs, expected_redistributed_trove2_errors) =
            preview_trove_redistribution(
            shrine, yangs, redistributed_trove2,
        );

        // Perform second redistribution
        shrine.melt(common::TROVE2_OWNER_ADDR, redistributed_trove2, Zero::zero());
        let redistributed_trove2_health: Health = shrine.get_trove_health(redistributed_trove2);

        shrine.redistribute(redistributed_trove2, redistributed_trove2_health.debt, RAY_ONE.into());

        let after_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();

        common::assert_equalish(
            after_protocol_owned_troves_debt,
            intermediate_protocol_owned_troves_debt + expected_redistributed_trove2_errors,
            error_margin,
            'wrong protocol debt #2',
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
            'wrong debt after redistribution',
        );

        assert(shrine.get_trove_redistribution_id(recipient_trove) == 0, 'wrong redistribution id');

        let unpulled_debt: Wad = shrine.get_redistributed_debt_for_trove(recipient_trove);
        let expected_recipient_trove_debt_total_increment = redistributed_trove1_health.debt
            + redistributed_trove2_start_health.debt
            - expected_redistributed_trove1_errors
            - expected_redistributed_trove2_errors;
        common::assert_equalish(
            unpulled_debt, expected_recipient_trove_debt_total_increment, 10_u128.into(), 'wrong attributed debt',
        );

        // Trigger an update in trove 3 with an empty melt
        shrine.melt(common::TROVE2_OWNER_ADDR, recipient_trove, Zero::zero());
        assert(shrine.get_trove_redistribution_id(recipient_trove) == expected_redistribution_id, 'wrong id');

        shrine_utils::assert_shrine_invariants(shrine, yangs, 3);
    }

    // Parametrized test to check that partial redistribution of a trove results in the correct
    // value and debt for the redistributed trove.
    fn test_shrine_redistribution(pct_debt_to_redistribute: Ray) {
        let shrine_class = shrine_utils::declare_shrine();

        let percentages: Span<Ray> = array![
            (15 * RAY_PERCENT).into(), (99 * RAY_PERCENT).into(), (100 * RAY_PERCENT).into(), Zero::zero(),
        ]
            .span();

        for pct_value_to_redistribute in percentages {
            let shrine: IShrineDispatcher = redistribution_setup(Option::Some(shrine_class));
            let mut spy = spy_events();

            let yangs: Span<ContractAddress> = shrine_utils::two_yang_addrs_reversed();
            let redistributed_trove = common::TROVE_1;
            let recipient_trove1 = common::TROVE_2;
            let recipient_trove2 = common::TROVE_3;

            // Simulate purge with 0 yin to update the trove's debt
            start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
            let trove1_owner = common::TROVE1_OWNER_ADDR;

            let before_redistributed_trove_health: Health = shrine.get_trove_health(redistributed_trove);
            let before_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();

            let (_, _, _, expected_error) = preview_trove_redistribution(shrine, yangs, redistributed_trove);

            shrine.melt(trove1_owner, redistributed_trove, Zero::zero());

            assert(shrine.get_redistributions_count() == 0, 'wrong start state');
            let debt_to_redistribute: Wad = wadray::rmul_wr(
                before_redistributed_trove_health.debt, pct_debt_to_redistribute,
            );
            shrine.redistribute(redistributed_trove, debt_to_redistribute, *pct_value_to_redistribute);

            let after_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();
            let expected_protocol_owned_troves_debt: Wad = before_protocol_owned_troves_debt + expected_error;
            let error_margin: Wad = 30_u128.into();
            common::assert_equalish(
                after_protocol_owned_troves_debt,
                expected_protocol_owned_troves_debt,
                error_margin,
                'wrong protocol debt #1',
            );

            let after_redistributed_trove_health: Health = shrine.get_trove_health(redistributed_trove);
            assert(
                after_redistributed_trove_health.debt == before_redistributed_trove_health.debt - debt_to_redistribute,
                'wrong redistributed trove debt',
            );

            let recipient_trove1_health: Health = shrine.get_trove_health(recipient_trove1);
            let recipient_trove2_health: Health = shrine.get_trove_health(recipient_trove2);

            // Accrue some interest
            common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);
            let updated_recipient_trove1_health: Health = shrine.get_trove_health(recipient_trove1);
            let updated_recipient_trove2_health: Health = shrine.get_trove_health(recipient_trove2);
            let accrued_interest: Wad = (updated_recipient_trove1_health.debt - recipient_trove1_health.debt)
                + (updated_recipient_trove2_health.debt - recipient_trove2_health.debt);
            let before_budget: SignedWad = shrine.get_budget();

            // Sanity check that we accrued more interest than the protocol owned troves' debt
            // for the next part of the test
            assert(accrued_interest > after_protocol_owned_troves_debt, 'interest sanity check');

            start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
            shrine.melt(trove1_owner, recipient_trove1, Zero::zero());
            shrine.melt(trove1_owner, recipient_trove2, Zero::zero());

            assert(shrine.get_protocol_owned_troves_debt().is_zero(), 'wrong po debt after interest');

            let excess: SignedWad = accrued_interest.into() - after_protocol_owned_troves_debt.into();
            let after_budget: SignedWad = shrine.get_budget();
            let expected_budget: SignedWad = before_budget + excess;
            assert_eq!(after_budget, expected_budget, "wrong budget");

            let expected_redistribution_id: u32 = 1;

            let mut expected_events = array![
                (
                    shrine.contract_address,
                    shrine_contract::Event::TroveRedistributed(
                        shrine_contract::TroveRedistributed {
                            redistribution_id: expected_redistribution_id,
                            trove_id: redistributed_trove,
                            debt: debt_to_redistribute,
                        },
                    ),
                ),
            ];
            if after_protocol_owned_troves_debt.is_non_zero() {
                expected_events
                    .append(
                        // protocol owned troves' debt update for redistribution
                        (
                            shrine.contract_address,
                            shrine_contract::Event::ProtocolOwnedTrovesDebtUpdated(
                                shrine_contract::ProtocolOwnedTrovesDebtUpdated {
                                    total: after_protocol_owned_troves_debt,
                                },
                            ),
                        ),
                    );
                expected_events
                    .append(
                        // protocol owned troves' debt update for interest accrual
                        (
                            shrine.contract_address,
                            shrine_contract::Event::ProtocolOwnedTrovesDebtUpdated(
                                shrine_contract::ProtocolOwnedTrovesDebtUpdated { total: Zero::zero() },
                            ),
                        ),
                    );
            }

            spy.assert_emitted(@expected_events);

            shrine_utils::assert_shrine_invariants(shrine, yangs, 3);
            // We are unable to test the trove value in a sensible way here because
        // the yang price has not been updated to reflect any rebasing of the
        // asset amount per yang wad. Instead, refer to the tests for purger
        // for assertions on the redistributed trove's value.
        };
    }

    #[test]
    fn test_shrine_redistribution_parametrized_1() {
        test_shrine_redistribution((15 * RAY_PERCENT).into());
    }

    #[test]
    fn test_shrine_redistribution_parametrized_2() {
        test_shrine_redistribution((99 * RAY_PERCENT).into());
    }

    #[test]
    fn test_shrine_redistribution_parametrized_3() {
        test_shrine_redistribution((100 * RAY_PERCENT).into());
    }

    #[test]
    fn test_shrine_redistribution_parametrized_4() {
        test_shrine_redistribution(Zero::zero());
    }

    #[test]
    fn test_shrine_redistribute_dust_yang_rounding() {
        // Manually set up troves so that the redistributed trove has a dust amount of one yang
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        setup_trove1(shrine);
        setup_trove3(shrine);

        let yang1_addr = shrine_utils::YANG1_ADDR;
        let yang2_addr = shrine_utils::YANG2_ADDR;

        let trove2_owner = common::TROVE2_OWNER_ADDR;
        let redistributed_trove = common::TROVE_2;
        let trove2_yang1_amt: Wad = 1000000000000000000000_u128.into(); // 1E-15 (Wad)
        let trove2_yang2_amt: Wad = 1000_u128.into(); // 1_000 (Wad)
        shrine.deposit(yang1_addr, redistributed_trove, trove2_yang1_amt);
        shrine.deposit(yang2_addr, redistributed_trove, trove2_yang2_amt);
        shrine.forge(trove2_owner, redistributed_trove, TROVE2_FORGE_AMT.into(), Zero::zero());

        // Get information before redistribution
        let trove2_health: Health = shrine.get_trove_health(redistributed_trove);

        // Sanity check that the amount of debt attributed to YANG_2 falls below the threshold
        let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr);
        let expected_yang2_redistributed_value = trove2_yang2_amt * yang2_price;

        let trove2_yang2_debt = wadray::rmul_rw(
            wadray::rdiv_ww(expected_yang2_redistributed_value, trove2_health.value), trove2_health.debt,
        );
        assert(trove2_yang2_debt < shrine_contract::ROUNDING_THRESHOLD.into(), 'not below rounding threshold');

        // Redistribute trove 2
        shrine.melt(trove2_owner, redistributed_trove, Zero::zero());
        shrine.redistribute(redistributed_trove, trove2_health.debt, RAY_ONE.into());

        let unpulled_debt: Wad = shrine.get_redistributed_debt_for_trove(redistributed_trove);
        assert(unpulled_debt.is_zero(), 'should be zero');

        // Check that yang 1 unit debt is zero
        let expected_redistribution_id: u32 = 1;
        assert(shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count');
        assert(
            shrine.get_redistribution_for_yang(yang2_addr, expected_redistribution_id).is_zero(), 'should be skipped',
        );

        // Check trove 2 has no yang 1, and some amount of yang 2.
        assert(shrine.get_deposit(yang1_addr, redistributed_trove).is_zero(), 'yang 1 should be zero');
        assert(shrine.get_deposit(yang2_addr, redistributed_trove).is_non_zero(), 'yang 2 should not be zero');

        // Check that all of trove 2's debt was distributed to yang 1
        let expected_remaining_yang1: Wad = (shrine_utils::TROVE1_YANG1_DEPOSIT + TROVE3_YANG1_DEPOSIT).into();
        let expected_unit_debt_for_yang2 = trove2_health.debt / expected_remaining_yang1;
        assert(
            shrine.get_redistribution_for_yang(yang1_addr, expected_redistribution_id) == expected_unit_debt_for_yang2,
            'wrong unit debt',
        );

        shrine_utils::assert_shrine_invariants(shrine, shrine_utils::two_yang_addrs(), 3);
    }

    #[test]
    fn test_exceptional_redistributions() {
        let shrine_class = shrine_utils::declare_shrine();

        let pct_value_to_redistribute_arr: Span<Ray> = array![
            RAY_PERCENT.into(), (50 * RAY_PERCENT).into(), (RAY_ONE - 1).into(), RAY_ONE.into(),
        ]
            .span();

        for pct_value_to_redistribute in pct_value_to_redistribute_arr {
            let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::Some(shrine_class));
            let mut spy = spy_events();

            // Manually set up troves so that the redistributed trove (trove 1) uses all three yangs
            // while the recipient troves (trove 2 and 3) uses only yang 2.
            let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs_reversed();
            let yang1_addr = *yangs.at(2);
            let yang2_addr = *yangs.at(1);
            let yang3_addr = *yangs.at(0);

            let trove1_owner = common::TROVE1_OWNER_ADDR;
            let redistributed_trove: u64 = common::TROVE_1;

            start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
            let redistributed_trove_debt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
            shrine.deposit(yang1_addr, redistributed_trove, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
            shrine.deposit(yang2_addr, redistributed_trove, shrine_utils::TROVE1_YANG2_DEPOSIT.into());
            shrine.deposit(yang3_addr, redistributed_trove, shrine_utils::TROVE1_YANG3_DEPOSIT.into());
            shrine.forge(trove1_owner, redistributed_trove, redistributed_trove_debt, Zero::zero());

            let trove2_owner = common::TROVE2_OWNER_ADDR;
            let recipient_trove1: u64 = common::TROVE_2;
            shrine.deposit(yang2_addr, recipient_trove1, TROVE2_YANG2_DEPOSIT.into());
            shrine.forge(trove2_owner, recipient_trove1, WAD_ONE.into(), Zero::zero());

            let trove3_owner = common::TROVE3_OWNER_ADDR;
            let recipient_trove2: u64 = common::TROVE_3;
            shrine.deposit(yang2_addr, recipient_trove2, TROVE3_YANG2_DEPOSIT.into());
            shrine.forge(trove3_owner, recipient_trove2, WAD_ONE.into(), Zero::zero());

            let before_redistributed_trove_health: Health = shrine.get_trove_health(redistributed_trove);
            let expected_redistributed_value: Wad = wadray::rmul_wr(
                before_redistributed_trove_health.value, *pct_value_to_redistribute,
            );

            let before_recipient_trove1_health: Health = shrine.get_trove_health(recipient_trove1);
            let before_recipient_trove2_health: Health = shrine.get_trove_health(recipient_trove2);

            let before_redistributed_trove_yang1_amt: Wad = wadray::rmul_wr(
                shrine.get_deposit(yang1_addr, redistributed_trove), *pct_value_to_redistribute,
            );
            let before_redistributed_trove_yang2_amt: Wad = wadray::rmul_wr(
                shrine.get_deposit(yang2_addr, redistributed_trove), *pct_value_to_redistribute,
            );
            let before_redistributed_trove_yang3_amt: Wad = wadray::rmul_wr(
                shrine.get_deposit(yang3_addr, redistributed_trove), *pct_value_to_redistribute,
            );

            let before_yang1_total: Wad = shrine.get_yang_total(yang1_addr);
            let before_yang2_total: Wad = shrine.get_yang_total(yang2_addr);
            let before_yang3_total: Wad = shrine.get_yang_total(yang3_addr);

            let before_yang1_protocol_owned_amt: Wad = shrine.get_protocol_owned_yang_amt(yang1_addr);
            let before_yang2_protocol_owned_amt: Wad = shrine.get_protocol_owned_yang_amt(yang2_addr);
            let before_yang3_protocol_owned_amt: Wad = shrine.get_protocol_owned_yang_amt(yang3_addr);

            let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr);
            let redistributed_trove_yang2_value: Wad = wadray::rmul_wr(
                shrine.get_deposit(yang2_addr, redistributed_trove), *pct_value_to_redistribute,
            )
                * yang2_price;
            let expected_redistributed_trove_yang2_debt: Wad = (redistributed_trove_yang2_value
                / expected_redistributed_value)
                * before_redistributed_trove_health.debt;

            let before_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();

            // Simulate purge with 0 yin to update the trove's debt
            shrine.melt(trove1_owner, redistributed_trove, Zero::zero());
            shrine
                .redistribute(redistributed_trove, before_redistributed_trove_health.debt, *pct_value_to_redistribute);
            let expected_redistribution_id: u32 = 1;
            assert(shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count');

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
                'wrong attributed debt #1',
            );

            let recipient_trove2_attr_debt: Wad = shrine.get_redistributed_debt_for_trove(recipient_trove2);
            common::assert_equalish(
                recipient_trove2_attr_debt,
                expected_recipient_trove2_attr_debt,
                (WAD_ONE / 100).into(),
                'wrong attributed debt #2',
            );

            // Check that each yang's total and initial yang amounts are correct
            // Yangs 1 and 3 should have total unchanged, and initial amounts changed.
            // yang 2 should have total decreased, and initial amount unchanged.
            let after_yang1_total: Wad = shrine.get_yang_total(yang1_addr);
            let after_yang2_total: Wad = shrine.get_yang_total(yang2_addr);
            let after_yang3_total: Wad = shrine.get_yang_total(yang3_addr);

            let after_yang1_protocol_owned_amt: Wad = shrine.get_protocol_owned_yang_amt(yang1_addr);
            let after_yang2_protocol_owned_amt: Wad = shrine.get_protocol_owned_yang_amt(yang2_addr);
            let after_yang3_protocol_owned_amt: Wad = shrine.get_protocol_owned_yang_amt(yang3_addr);

            if *pct_value_to_redistribute == RAY_ONE.into() {
                // strict equality because there is no offset since redistributed trove
                // has no yang2 remaining
                assert_eq!(
                    after_yang2_total, before_yang2_total - before_redistributed_trove_yang2_amt, "wrong yang2 total",
                );
            } else {
                // le because there is an offset to account for redistributed trove having
                // yang2 remaining
                assert(
                    after_yang2_total < before_yang2_total - before_redistributed_trove_yang2_amt, 'wrong yang2 total',
                );
            }
            assert_eq!(after_yang2_protocol_owned_amt, before_yang2_protocol_owned_amt, "wrong initial yang2");

            assert_eq!(after_yang1_total, before_yang1_total, "wrong yang1 total");
            assert_eq!(
                after_yang1_protocol_owned_amt,
                before_yang1_protocol_owned_amt + before_redistributed_trove_yang1_amt,
                "wrong initial yang1",
            );
            assert_eq!(after_yang3_total, before_yang3_total, "wrong yang3 total");
            assert_eq!(
                after_yang3_protocol_owned_amt,
                before_yang3_protocol_owned_amt + before_redistributed_trove_yang3_amt,
                "wrong initial yang3",
            );

            // Check that the debt for yangs 1 and 3 have been added to the protocol owned' troves debt
            let after_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();
            let expected_protocol_owned_troves_debt = redistributed_trove_debt
                - expected_redistributed_trove_yang2_debt;
            common::assert_equalish(
                after_protocol_owned_troves_debt,
                expected_protocol_owned_troves_debt,
                10000_u128.into(),
                'wrong protocol debt',
            );

            // Trigger an update in recipient troves with an empty melt
            shrine.melt(trove1_owner, recipient_trove1, Zero::zero());
            shrine.melt(trove1_owner, recipient_trove2, Zero::zero());

            assert(shrine.get_trove_redistribution_id(recipient_trove1) == expected_redistribution_id, 'wrong id');
            assert(shrine.get_trove_redistribution_id(recipient_trove2) == expected_redistribution_id, 'wrong id');

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
            let protocol_owned_troves_debt_diff: Wad = (after_protocol_owned_troves_debt
                - before_protocol_owned_troves_debt);
            assert(
                before_redistributed_trove_health.debt == actual_redistributed_debt + protocol_owned_troves_debt_diff,
                'debt invariant failed',
            );

            // Accrue some interest
            common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);
            let accrued_recipient_trove2_health: Health = shrine.get_trove_health(recipient_trove2);
            let accrued_interest: Wad = accrued_recipient_trove2_health.debt - after_recipient_trove2_health.debt;
            let before_budget: SignedWad = shrine.get_budget();

            start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
            shrine.melt(trove1_owner, recipient_trove2, Zero::zero());

            let accrued_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();
            let expected_protocol_owned_troves_debt: Wad = after_protocol_owned_troves_debt - accrued_interest;
            assert_eq!(
                accrued_protocol_owned_troves_debt, expected_protocol_owned_troves_debt, "wrong po debt after interest",
            );

            // Since the amount accrued should be less than the amount redistributed earlier, budget
            // should remain unchanged
            let after_budget: SignedWad = shrine.get_budget();
            assert_eq!(after_budget, before_budget, "budget changed");

            let expected_events = array![
                (
                    shrine.contract_address,
                    shrine_contract::Event::TroveRedistributed(
                        shrine_contract::TroveRedistributed {
                            redistribution_id: expected_redistribution_id,
                            trove_id: redistributed_trove,
                            debt: before_redistributed_trove_health.debt,
                        },
                    ),
                ),
                // protocol owned troves' debt update for redistribution
                (
                    shrine.contract_address,
                    shrine_contract::Event::ProtocolOwnedTrovesDebtUpdated(
                        shrine_contract::ProtocolOwnedTrovesDebtUpdated { total: after_protocol_owned_troves_debt },
                    ),
                ),
                // protocol owned troves' debt update for interest accrual
                (
                    shrine.contract_address,
                    shrine_contract::Event::ProtocolOwnedTrovesDebtUpdated(
                        shrine_contract::ProtocolOwnedTrovesDebtUpdated { total: accrued_protocol_owned_troves_debt },
                    ),
                ),
            ];
            spy.assert_emitted(@expected_events);

            shrine_utils::assert_shrine_invariants(shrine, yangs, 3);
        };
    }

    // Redistribution with only 1 trove.
    // Since the trove's yangs are zeroed, the initial yang would essentially "receive"
    // the trove's value via rebasing and all the debt would go to the protocol owned troves' debt.
    // The trove's debt would also be zeroed. However, the debt would still be backed by the
    // initial yangs, and the value can be accessed in the event of a shutdown.
    #[test]
    fn test_shrine_redistribution_only_one_trove_remaining() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        setup_trove1(shrine);

        // Simulate purge with 0 yin to update the trove's debt
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        let trove1_owner = common::TROVE1_OWNER_ADDR;
        let redistributed_trove = common::TROVE_1;
        let redistributed_trove_health: Health = shrine.get_trove_health(redistributed_trove);
        shrine.melt(trove1_owner, redistributed_trove, Zero::zero());

        let before_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();

        assert(shrine.get_redistributions_count() == 0, 'wrong start state');
        shrine.redistribute(redistributed_trove, redistributed_trove_health.debt, RAY_ONE.into());

        let after_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();
        let expected_protocol_owned_troves_debt: Wad = before_protocol_owned_troves_debt
            + redistributed_trove_health.debt;
        assert_eq!(after_protocol_owned_troves_debt, expected_protocol_owned_troves_debt, "wrong protocol debt");

        let expected_redistribution_id: u32 = 1;
        assert(shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count');

        let after_trove_health: Health = shrine.get_trove_health(common::TROVE_2);
        assert(after_trove_health.value.is_zero(), 'wrong value post redistribution');
        assert(after_trove_health.debt.is_zero(), 'wrong debt after redistribution');

        assert(shrine.get_trove_redistribution_id(common::TROVE_2) == 0, 'wrong redistribution id');
        // Trigger an update in trove 2 with an empty melt
        shrine.melt(trove1_owner, common::TROVE_2, Zero::zero());
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
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        while idx != new_troves_count {
            let trove_idx: u64 = 4 + idx;
            let tmp_multiplier: u128 = (idx + 1).into();
            shrine.deposit(yang1_addr, trove_idx, (tmp_multiplier * 100000000000000000).into()); // idx * 0.1 Wad
            shrine.deposit(yang2_addr, trove_idx, (tmp_multiplier * 200000000000000000).into()); // idx * 0.2 Wad

            idx += 1;
        }

        let redistributed_trove: u64 = common::TROVE_1;
        let (_, _, _, expected_error) = preview_trove_redistribution(shrine, yangs, redistributed_trove);
        let before_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();

        shrine.redistribute(redistributed_trove, shrine_utils::TROVE1_FORGE_AMT.into(), RAY_ONE.into());

        let after_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();
        let expected_protocol_owned_troves_debt: Wad = before_protocol_owned_troves_debt + expected_error;
        assert_eq!(after_protocol_owned_troves_debt, expected_protocol_owned_troves_debt, "wrong protocol debt");

        shrine_utils::assert_shrine_invariants(shrine, yangs, 13);
    }

    // Check that a delisted yang is not redistributed
    #[test]
    fn test_shrine_redistribution_including_delisted_yang() {
        let shrine: IShrineDispatcher = redistribution_setup(Option::None);

        let trove1_owner = common::TROVE1_OWNER_ADDR;
        let redistributed_trove: u64 = common::TROVE_1;

        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs();
        let yang_to_delist: ContractAddress = *yangs[0];
        let yang_amt_deposited: Wad = shrine.get_deposit(yang_to_delist, redistributed_trove);
        let before_protocol_owned_delisted_yang_amt: Wad = shrine.get_protocol_owned_yang_amt(yang_to_delist);

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.forge(trove1_owner, redistributed_trove, (100 * WAD_ONE).into(), Zero::zero());
        shrine.suspend_yang(yang_to_delist);

        shrine_utils::advance_prices_periodically(shrine, yangs, shrine_contract::SUSPENSION_GRACE_PERIOD);

        assert(shrine.get_yang_suspension_status(yang_to_delist) == YangSuspensionStatus::Permanent, 'not delisted');

        // Simulate purge with 0 yin to update the trove's debt
        let trove1_health: Health = shrine.get_trove_health(redistributed_trove);
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.melt(trove1_owner, redistributed_trove, Zero::zero());

        assert(shrine.get_redistributions_count() == 0, 'wrong start state');
        shrine.redistribute(redistributed_trove, trove1_health.debt, RAY_ONE.into());

        assert(shrine.get_deposit(yang_to_delist, redistributed_trove).is_zero(), 'delisted yang should be zero');
        assert(shrine.get_deposit(*yangs[1], redistributed_trove).is_zero(), 'yang 2 should be zero');
        assert(shrine.get_deposit(*yangs[2], redistributed_trove).is_zero(), 'yang 3 should be zero');

        let after_protocol_owned_delisted_yang_amt: Wad = shrine.get_protocol_owned_yang_amt(yang_to_delist);
        let expected_protocol_owned_delisted_yang_amt: Wad = before_protocol_owned_delisted_yang_amt
            + yang_amt_deposited;
        assert_eq!(
            after_protocol_owned_delisted_yang_amt,
            expected_protocol_owned_delisted_yang_amt,
            "wrong protocol owned delisted yang amt",
        );
    }

    #[test]
    fn test_shrine_redistribution_delisted_yang_only() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs();
        let yang_to_delist: ContractAddress = *yangs[0];

        let trove1_owner = common::TROVE1_OWNER_ADDR;
        let redistributed_trove: u64 = common::TROVE_1;

        let yang_amt_to_deposit: Wad = (1000 * WAD_ONE).into();
        let forge_amt: Wad = (100 * WAD_ONE).into();
        shrine_utils::trove1_deposit(shrine, yang_amt_to_deposit);
        shrine_utils::trove1_forge(shrine, forge_amt);

        let before_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();
        let before_protocol_owned_delisted_yang_amt: Wad = shrine.get_protocol_owned_yang_amt(yang_to_delist);

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.suspend_yang(yang_to_delist);

        shrine_utils::advance_prices_periodically(shrine, yangs, shrine_contract::SUSPENSION_GRACE_PERIOD);

        assert(shrine.get_yang_suspension_status(yang_to_delist) == YangSuspensionStatus::Permanent, 'not delisted');

        // Simulate purge with 0 yin to update the trove's debt
        let trove1_health: Health = shrine.get_trove_health(redistributed_trove);
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.melt(trove1_owner, redistributed_trove, Zero::zero());

        assert(shrine.get_redistributions_count() == 0, 'wrong start state');
        shrine.redistribute(redistributed_trove, trove1_health.debt, RAY_ONE.into());

        assert(shrine.get_deposit(yang_to_delist, redistributed_trove).is_zero(), 'delisted yang should be zero');

        let after_protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();
        let expected_protocol_owned_troves_debt: Wad = before_protocol_owned_troves_debt + forge_amt;
        assert_eq!(
            after_protocol_owned_troves_debt, expected_protocol_owned_troves_debt, "wrong protocol owned troves' debt",
        );

        let after_protocol_owned_delisted_yang_amt: Wad = shrine.get_protocol_owned_yang_amt(yang_to_delist);
        let expected_protocol_owned_delisted_yang_amt: Wad = before_protocol_owned_delisted_yang_amt
            + yang_amt_to_deposit;
        assert_eq!(
            after_protocol_owned_delisted_yang_amt,
            expected_protocol_owned_delisted_yang_amt,
            "wrong protocol owned delisted yang amt",
        );
    }

    #[test]
    #[should_panic(expected: 'SH: pct_val_to_redistribute > 1')]
    fn test_shrine_redistribution_gt_one_ray_pct_value_to_redistribute_fail() {
        let shrine: IShrineDispatcher = redistribution_setup(Option::None);

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.redistribute(common::TROVE_1, 1_u128.into(), (RAY_ONE + RAY_PERCENT).into());
    }

    #[test]
    fn test_reduction_of_protocol_owned_troves_debt() {
        let shrine_class = shrine_utils::declare_shrine();

        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs();
        let yang1_addr = *yangs.at(0);
        let yang2_addr = *yangs.at(1);
        let yang3_addr = *yangs.at(2);

        let trove1_owner = common::TROVE1_OWNER_ADDR;
        let target_trove: u64 = common::TROVE_1;

        let trove2_owner = common::TROVE2_OWNER_ADDR;
        let redistributed_trove: u64 = common::TROVE_2;

        let yin_price: Wad = 980000000000000000_u128.into(); // 0.98 (wad)

        let num_cases = 4;
        let mut idx = 0;

        while idx != num_cases {
            let target_trove_forge_amts: Span<Wad> = array![Zero::zero(), WAD_ONE.into()].span();

            for target_trove_forge_amt in target_trove_forge_amts {
                let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::Some(shrine_class));

                // Create a trove and accrue some interest
                start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
                let target_trove_start_debt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
                shrine.deposit(yang1_addr, target_trove, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
                shrine.forge(trove1_owner, target_trove, target_trove_start_debt, Zero::zero());

                common::advance_intervals(200);

                let target_trove_health: Health = shrine.get_trove_health(target_trove);
                let accrued_interest: Wad = target_trove_health.debt - target_trove_start_debt;
                assert(accrued_interest.is_non_zero(), 'no interest accrued');

                // Update yin price for forge fee
                shrine.update_yin_spot_price(yin_price);
                let forge_fee_pct: Wad = shrine.get_forge_fee_pct();

                let expected_forge_fee: Wad = forge_fee_pct * *target_trove_forge_amt;
                let expected_forge_fee_and_accrued_interest: Wad = expected_forge_fee + accrued_interest;

                // Create a trove with different yangs and with the amount of debt depending on the test case,
                // then immediately redistribute it
                let protocol_owned_debt_amt: Wad = match idx {
                    0 => expected_forge_fee_and_accrued_interest * (2 * WAD_ONE).into(),
                    1 => expected_forge_fee_and_accrued_interest + 1_u128.into(),
                    2 => expected_forge_fee_and_accrued_interest,
                    3 => expected_forge_fee_and_accrued_interest - 1_u128.into(),
                    _ => panic!("invalid idx"),
                };

                shrine.deposit(yang2_addr, redistributed_trove, shrine_utils::TROVE1_YANG2_DEPOSIT.into());
                shrine.deposit(yang3_addr, redistributed_trove, shrine_utils::TROVE1_YANG3_DEPOSIT.into());
                shrine.forge(trove2_owner, redistributed_trove, protocol_owned_debt_amt, forge_fee_pct);

                shrine.redistribute(redistributed_trove, protocol_owned_debt_amt, RAY_ONE.into());

                let protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();
                assert_eq!(
                    protocol_owned_troves_debt, protocol_owned_debt_amt, "setup: wrong protocol owned troves debt amt",
                );

                let before_shrine_health: Health = shrine.get_shrine_health();
                let before_budget: SignedWad = shrine.get_budget();

                // Charge interest on the first trove
                let mut spy = spy_events();
                shrine.forge(trove1_owner, target_trove, *target_trove_forge_amt, forge_fee_pct);

                let expected_protocol_owned_troves_debt: Wad =
                    if protocol_owned_debt_amt >= expected_forge_fee_and_accrued_interest {
                    protocol_owned_debt_amt - expected_forge_fee_and_accrued_interest
                } else {
                    Zero::zero()
                };

                let protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();
                assert_eq!(protocol_owned_troves_debt, expected_protocol_owned_troves_debt, "wrong po troves' debt");

                let after_budget: SignedWad = shrine.get_budget();
                let excess_interest: Wad = if protocol_owned_debt_amt < expected_forge_fee_and_accrued_interest {
                    expected_forge_fee_and_accrued_interest - protocol_owned_debt_amt
                } else {
                    Zero::zero()
                };
                let expected_budget: SignedWad = before_budget + excess_interest.into();
                assert_eq!(after_budget, expected_budget, "wrong budget");

                let expected_total_troves_debt_increment: Wad = *target_trove_forge_amt + excess_interest;
                let expected_total_troves_debt: Wad = before_shrine_health.debt + expected_total_troves_debt_increment;

                let mut expected_events = array![
                    (
                        shrine.contract_address,
                        shrine_contract::Event::ProtocolOwnedTrovesDebtUpdated(
                            shrine_contract::ProtocolOwnedTrovesDebtUpdated {
                                total: expected_protocol_owned_troves_debt,
                            },
                        ),
                    ),
                    (
                        shrine.contract_address,
                        shrine_contract::Event::TotalTrovesDebtUpdated(
                            shrine_contract::TotalTrovesDebtUpdated { total: expected_total_troves_debt },
                        ),
                    ),
                    (
                        shrine.contract_address,
                        shrine_contract::Event::BudgetAdjusted(
                            shrine_contract::BudgetAdjusted { amount: excess_interest.into() },
                        ),
                    ),
                ];

                if (*target_trove_forge_amt).is_non_zero() {
                    expected_events
                        .append(
                            (
                                shrine.contract_address,
                                shrine_contract::Event::ForgeFeePaid(
                                    shrine_contract::ForgeFeePaid {
                                        trove_id: target_trove, fee: expected_forge_fee, fee_pct: forge_fee_pct,
                                    },
                                ),
                            ),
                        );
                }

                spy.assert_emitted(@expected_events);
            }
            idx += 1;
        };
    }
}
