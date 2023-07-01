#[cfg(test)]
mod TestShrineRedistribution {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use traits::{Default, Into};
    use starknet::ContractAddress;
    use starknet::testing::set_contract_address;
    use zeroable::Zeroable;

    use aura::core::shrine::Shrine;

    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::serde;
    use aura::utils::types::{ExceptionalYangRedistribution, YangRedistribution};
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, Wad, WadZeroable};

    use aura::tests::shrine::utils::ShrineUtils;
    use aura::tests::common;

    use debug::PrintTrait;

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
        let yang1_addr = ShrineUtils::yang1_addr();
        let yang2_addr = ShrineUtils::yang2_addr();

        let trove1_owner = common::trove1_owner_addr();
        shrine.deposit(yang1_addr, common::TROVE_1, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, common::TROVE_1, ShrineUtils::TROVE1_YANG2_DEPOSIT.into());
        shrine
            .forge(
                trove1_owner, common::TROVE_1, ShrineUtils::TROVE1_FORGE_AMT.into(), 0_u128.into()
            );
    }

    fn setup_trove2(shrine: IShrineDispatcher) {
        let yang1_addr = ShrineUtils::yang1_addr();
        let yang2_addr = ShrineUtils::yang2_addr();

        let trove2_owner = common::trove2_owner_addr();
        shrine.deposit(yang1_addr, common::TROVE_2, TROVE2_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, common::TROVE_2, TROVE2_YANG2_DEPOSIT.into());
        shrine.forge(trove2_owner, common::TROVE_2, TROVE2_FORGE_AMT.into(), 0_u128.into());
    }

    fn setup_trove3(shrine: IShrineDispatcher) {
        let yang1_addr = ShrineUtils::yang1_addr();
        let yang2_addr = ShrineUtils::yang2_addr();

        let trove3_owner = ShrineUtils::common::trove3_owner_addr();
        shrine.deposit(yang1_addr, common::TROVE_3, TROVE3_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, common::TROVE_3, TROVE3_YANG2_DEPOSIT.into());
        shrine.forge(trove3_owner, common::TROVE_3, TROVE3_FORGE_AMT.into(), 0_u128.into());
    }

    // Helper function to set up three troves
    // - Trove 1 deposits and forges the amounts specified in `src/tests/shrine/utils.cairo`
    // - Troves 2 and 3 deposits and forges the amounts specified in this file
    fn redistribution_setup() -> IShrineDispatcher {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        setup_trove1(shrine);
        setup_trove2(shrine);
        setup_trove3(shrine);

        shrine
    }

    // Helper function to return the total debt error from a redistribution
    fn get_redistributed_debt_error(
        shrine: IShrineDispatcher,
        mut yang_addrs: Span<ContractAddress>, 
        redistribution_id: u32
    ) -> Wad {
        let mut cumulative_error: Wad = WadZeroable::zero();

        loop {
            match yang_addrs.pop_front() {
                Option::Some(yang) => {
                    let yang_redistribution = shrine
                        .get_redistribution_for_yang(*yang, redistribution_id);
                    cumulative_error += yang_redistribution.error;
                },
                Option::None(_) => {
                    break cumulative_error;
                },
            };
        }
    }

    // Returns a tuple of arrays which are the expected values from redistributing a trove
    // - value liquidated for each yang
    // - unit debt after redistributing debt for each yang
    // - error after redistributing debt for each yang
    // - expected amount of yangs remaining after redistribution
    // Note that once the remaining redistribution value falls below the threshold, an early
    // return will be performed, so yangs with dust value of debt will not be included.
    fn preview_trove_redistribution(
        shrine: IShrineDispatcher, mut yang_addrs: Span<ContractAddress>, trove: u64
    ) -> (Span<Wad>, Span<Wad>, Span<Wad>, Span<Wad>) {
        let (_, _, trove_value, trove_debt) = shrine.get_trove_info(trove);

        let mut trove_yang_values: Array<Wad> = Default::default();
        let mut expected_unit_debts: Array<Wad> = Default::default();
        let mut expected_errors: Array<Wad> = Default::default();
        let mut expected_remaining_yangs: Array<Wad> = Default::default();
        let mut cumulative_redistributed_debt: Wad = WadZeroable::zero();

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
                        wadray::rdiv_ww(yang_value, trove_value), 
                        trove_debt,
                    );
                    cumulative_redistributed_debt += expected_yang_debt;
                    let remainder = trove_debt - cumulative_redistributed_debt;
                    if remainder < Shrine::ROUNDING_THRESHOLD.into() {
                        expected_yang_debt += remainder;
                        cumulative_redistributed_debt += remainder;
                    }

                    let expected_remaining_yang = shrine.get_yang_total(*yang) - deposited - shrine.get_initial_yang_amt(*yang);
                    let expected_unit_debt = expected_yang_debt / expected_remaining_yang;
                    expected_remaining_yangs.append(expected_remaining_yang);
                    expected_unit_debts.append(expected_unit_debt);

                    let actual_redistributed_debt = expected_unit_debt * expected_remaining_yang;
                    let expected_error = expected_yang_debt - actual_redistributed_debt;

                    expected_errors.append(expected_error);

                    if remainder < Shrine::ROUNDING_THRESHOLD.into() {
                        break;
                    }
                },
                Option::None(_) => {
                    break;
                }
            };
        };
        (
            trove_yang_values.span(),
            expected_unit_debts.span(),
            expected_errors.span(),
            expected_remaining_yangs.span()
        )
    }

    // Returns a tuple of
    // 1. the expected debt for the recipient trove from the redistribution
    // 2. the amount of redistributed debt based on unit debt per yang and errors, less
    //    errors carried over from the previous redistribution
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
        mut prev_errors: Span<Wad>,
    ) -> (Wad, Wad) {
        let mut expected_recipient_trove_debt_increment = WadZeroable::zero();
        let mut cumulative_redistributed_debt = WadZeroable::zero();

        let has_errors: bool = prev_errors.len() > 0;

        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    assert(
                        shrine.get_deposit(*yang, redistributed_trove_id) == WadZeroable::zero(),
                        'deposit should be 0'
                    );

                    let recipient_trove_yang_deposit = *recipient_trove_yangs.pop_front().unwrap();
                    let remaining_yang = *expected_remaining_yangs.pop_front().unwrap();

                    // Calculate the amount of debt redistributed for the yang, checking for
                    // rounding threshold,
                    let mut expected_yang_debt = wadray::rmul_rw(
                        wadray::rdiv_ww(*redistributed_trove_yang_values
                        .pop_front()
                        .unwrap(),
                        redistributed_trove_value),
                        redistributed_trove_debt
                    );
                    // Use a temporary variable for cumulative redistributed debt to check for rounding
                    let tmp_cumulative_redistributed_debt = cumulative_redistributed_debt
                        + expected_yang_debt;
                    let remainder = redistributed_trove_debt - tmp_cumulative_redistributed_debt;
                    if remainder < Shrine::ROUNDING_THRESHOLD.into() {
                        expected_yang_debt += remainder;
                    }

                    // If provided, include the error from previous redistribution to calculate
                    // unit debt
                    let mut prev_error = WadZeroable::zero();
                    if has_errors {
                        prev_error = *prev_errors.pop_front().unwrap();
                        expected_yang_debt += prev_error;
                    }

                    let expected_unit_debt = expected_yang_debt / remaining_yang;
                    let redistribution = shrine
                        .get_redistribution_for_yang(*yang, expected_redistribution_id);
                        
                    common::assert_equalish(
                        expected_unit_debt,
                        redistribution.unit_debt,
                        1_u128.into(),
                        'wrong unit debt'
                    );

                    expected_recipient_trove_debt_increment += recipient_trove_yang_deposit
                        * expected_unit_debt;

                    // Calculate cumulative redistributed debt for subsequent check
                    let expected_cumulative_increment = remaining_yang * expected_unit_debt;
                    cumulative_redistributed_debt += expected_cumulative_increment;
                    let expected_error = expected_yang_debt - expected_cumulative_increment;
                    cumulative_redistributed_debt += expected_error;

                    // If provided, exclude the error from previous redistribution to calculate
                    // the redistributed trove's debt
                    if has_errors {
                        cumulative_redistributed_debt -= prev_error;
                    }
                },
                Option::None(_) => {
                    break;
                }
            };
        };

        (expected_recipient_trove_debt_increment, cumulative_redistributed_debt)
    }

    //
    // Tests
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_one_redistribution() {
        let shrine: IShrineDispatcher = redistribution_setup();

        let (_, _, _, before_trove2_debt) = shrine.get_trove_info(common::TROVE_2);

        // Note order is reversed to match `yang_addrs`
        let mut trove2_yang_deposits: Array<Wad> = Default::default();
        trove2_yang_deposits.append(TROVE2_YANG2_DEPOSIT.into());
        trove2_yang_deposits.append(TROVE2_YANG1_DEPOSIT.into());
        let mut trove2_yang_deposits = trove2_yang_deposits.span();

        let yang_addrs: Span<ContractAddress> = ShrineUtils::two_yang_addrs();
        let (trove1_yang_values, expected_unit_debts, expected_errors, expected_remaining_yangs) =
            preview_trove_redistribution(
            shrine, yang_addrs, common::TROVE_1
        );

        // Simulate purge with 0 yin to update the trove's debt
        set_contract_address(ShrineUtils::admin());
        let trove1_owner = common::trove1_owner_addr();
        let (_, _, trove1_value, trove1_debt) = shrine.get_trove_info(common::TROVE_1);
        shrine.melt(trove1_owner, common::TROVE_1, WadZeroable::zero());

        assert(shrine.get_redistributions_count() == 0, 'wrong start state');
        shrine.redistribute(common::TROVE_1);

        let expected_redistribution_id: u32 = 1;
        assert(
            shrine.get_redistributions_count() == expected_redistribution_id,
            'wrong redistribution count'
        );

        let empty_errors: Span<Wad> = Default::default().span();
        let (expected_trove2_debt_increment, cumulative_redistributed_debt) =
            assert_redistribution_is_correct(
            shrine,
            yang_addrs,
            expected_remaining_yangs,
            trove2_yang_deposits,
            common::TROVE_1,
            trove1_debt,
            trove1_value,
            trove1_yang_values,
            expected_redistribution_id,
            empty_errors, // Dummy values
        );

        let expected_trove2_debt = before_trove2_debt + expected_trove2_debt_increment;

        // Check invariant of [(yang1_total * yang1_unit_debt + error) + ... (yang2 ...) + rounding]
        // is equal to redistributed trove's debt
        assert(cumulative_redistributed_debt == trove1_debt, 'wrong redistributed debt');

        let (_, _, _, after_trove2_debt) = shrine.get_trove_info(common::TROVE_2);

        assert(after_trove2_debt == expected_trove2_debt, 'wrong debt after redistribution');

        assert(shrine.get_trove_redistribution_id(common::TROVE_2) == 0, 'wrong redistribution id');
        // Trigger an update in trove 2 with an empty melt
        shrine.melt(trove1_owner, common::TROVE_2, WadZeroable::zero());
        // TODO: checking equality with `expected_redistribution_id` causes `Unknown ap change` error
        assert(shrine.get_trove_redistribution_id(common::TROVE_2) == 1, 'wrong id');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_two_redistributions() {
        let shrine: IShrineDispatcher = redistribution_setup();

        let yang_addrs: Span<ContractAddress> = ShrineUtils::two_yang_addrs();
        let (_, _, expected_trove1_errors, _) = preview_trove_redistribution(
            shrine, yang_addrs, common::TROVE_1
        );

        // Perform first redistribution - covered by previous test
        set_contract_address(ShrineUtils::admin());
        shrine.melt(common::trove1_owner_addr(), common::TROVE_1, WadZeroable::zero());
        shrine.redistribute(common::TROVE_1);

        let trove2_owner = common::trove2_owner_addr();

        let (_, _, trove2_value, trove2_debt) = shrine.get_trove_info(common::TROVE_2);
        let (_, _, _, before_trove3_debt) = shrine.get_trove_info(common::TROVE_3);

        let (mut trove2_yang_values, _, _, expected_remaining_yangs) = preview_trove_redistribution(
            shrine, yang_addrs, common::TROVE_2
        );

        // Perform second redistribution
        shrine.melt(trove2_owner, common::TROVE_2, WadZeroable::zero());
        let (_, _, _, redistributed_debt) = shrine.get_trove_info(common::TROVE_2);

        shrine.redistribute(common::TROVE_2);

        let expected_redistribution_id: u32 = 2;
        assert(
            shrine.get_redistributions_count() == expected_redistribution_id,
            'wrong redistribution count'
        );

        let (expected_trove3_debt_increment, cumulative_redistributed_debt) =
            assert_redistribution_is_correct(
            shrine,
            yang_addrs,
            expected_remaining_yangs,
            expected_remaining_yangs, // Trove 3 is the only remaining trove
            common::TROVE_2,
            trove2_debt,
            trove2_value,
            trove2_yang_values,
            expected_redistribution_id,
            expected_trove1_errors,
        );

        let expected_trove3_debt = before_trove3_debt + expected_trove3_debt_increment;

        // Check invariant of [(yang1_total * yang1_unit_debt + error) + ... (yang2 ...) + rounding]
        // is equal to redistributed trove's debt
        assert(redistributed_debt == cumulative_redistributed_debt, 'wrong redistributed debt');

        let (_, _, _, after_trove3_debt) = shrine.get_trove_info(common::TROVE_3);
        assert(after_trove3_debt == expected_trove3_debt, 'wrong debt after redistribution');

        assert(shrine.get_trove_redistribution_id(common::TROVE_3) == 0, 'wrong redistribution id');
        // Trigger an update in trove 3 with an empty melt
        shrine.melt(trove2_owner, common::TROVE_3, WadZeroable::zero());
        // TODO: checking equality with `expected_redistribution_id` causes `Unknown ap change` error
        assert(shrine.get_trove_redistribution_id(common::TROVE_3) == 2, 'wrong id');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_redistribute_dust_yang_rounding() {
        // Manually set up troves so that the redistributed trove has a dust amount of one yang
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        setup_trove1(shrine);
        setup_trove3(shrine);

        let yang1_addr = ShrineUtils::yang1_addr();
        let yang2_addr = ShrineUtils::yang2_addr();

        let trove2_owner = common::trove2_owner_addr();
        let trove2_yang1_amt: Wad = 1000_u128.into(); // 1E-15 (Wad)
        let trove2_yang2_amt: Wad = 1000000000000000000000_u128.into(); // 1_000 (Wad)
        shrine.deposit(yang1_addr, common::TROVE_2, trove2_yang1_amt);
        shrine.deposit(yang2_addr, common::TROVE_2, trove2_yang2_amt);
        shrine.forge(trove2_owner, common::TROVE_2, TROVE2_FORGE_AMT.into(), 0_u128.into());

        // Get information before redistribution
        let (_, _, trove2_value, trove2_debt) = shrine.get_trove_info(common::TROVE_2);

        let yang_addrs: Span<ContractAddress> = ShrineUtils::two_yang_addrs();

        // Sanity check that the amount of debt attributed to YANG_2 falls below the threshold
        let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr);
        let expected_yang2_redistributed_value = trove2_yang1_amt * yang2_price;

        let trove2_yang1_debt = wadray::rmul_rw(
            wadray::rdiv_ww(expected_yang2_redistributed_value, trove2_value), trove2_debt
        );
        assert(
            trove2_yang1_debt < Shrine::ROUNDING_THRESHOLD.into(), 'not below rounding threshold'
        );

        // Redistribute trove 2
        shrine.melt(trove2_owner, common::TROVE_2, WadZeroable::zero());
        shrine.redistribute(common::TROVE_2);

        // Check that yang 1 unit debt is zero
        let expected_redistribution_id: u32 = 1;
        assert(
            shrine.get_redistributions_count() == expected_redistribution_id,
            'wrong redistribution count'
        );
        assert(
            shrine
                .get_redistribution_for_yang(yang1_addr, expected_redistribution_id)
                .unit_debt == WadZeroable::zero(),
            'should be skipped'
        );

        // Check that all of trove 2's debt was distributed to yang 2
        let expected_remaining_yang2: Wad = (ShrineUtils::TROVE1_YANG2_DEPOSIT
            + TROVE3_YANG2_DEPOSIT)
            .into();
        let expected_unit_debt_for_yang2 = trove2_debt / expected_remaining_yang2;
        assert(
            shrine
                .get_redistribution_for_yang(yang2_addr, expected_redistribution_id)
                .unit_debt == expected_unit_debt_for_yang2,
            'wrong unit debt'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_one_exceptional_redistribution_one_recipient_yang() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        // Manually set up troves so that the redistributed trove (trove 1) uses all three yangs
        // while the recipient troves (trove 2 and 3) uses only yang 2.
        let yang1_addr = ShrineUtils::yang1_addr();
        let yang2_addr = ShrineUtils::yang2_addr();
        let yang3_addr = ShrineUtils::yang3_addr();

        let trove1_owner = common::trove1_owner_addr();
        let redistributed_trove: u64 = common::TROVE_1;

        set_contract_address(ShrineUtils::admin());
        shrine.deposit(yang1_addr, redistributed_trove, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, redistributed_trove, ShrineUtils::TROVE1_YANG2_DEPOSIT.into());
        shrine.deposit(yang3_addr, redistributed_trove, ShrineUtils::TROVE1_YANG3_DEPOSIT.into());
        shrine
            .forge(
                trove1_owner,
                redistributed_trove,
                ShrineUtils::TROVE1_FORGE_AMT.into(),
                0_u128.into()
            );

        let trove2_owner = common::trove2_owner_addr();
        let recipient_trove1: u64 = common::TROVE_2;
        shrine.deposit(yang2_addr, recipient_trove1, TROVE2_YANG2_DEPOSIT.into());
        shrine.forge(trove2_owner, recipient_trove1, TROVE2_FORGE_AMT.into(), 0_u128.into());

        let trove3_owner = common::trove3_owner_addr();
        let recipient_trove2: u64 = common::TROVE_3;
        shrine.deposit(yang2_addr, recipient_trove2, TROVE3_YANG2_DEPOSIT.into());
        shrine.forge(trove3_owner, recipient_trove2, TROVE3_FORGE_AMT.into(), 0_u128.into());

        let (_, _, before_recipient_trove1_value, before_recipient_trove1_debt) = shrine
            .get_trove_info(recipient_trove1);
        let (_, _, before_recipient_trove2_value, before_recipient_trove2_debt) = shrine
            .get_trove_info(recipient_trove2);

        // Note that since there is only one yang in recipient troves, the check here is a lot simpler because
        // all redistributions will follow the same proportion. See the next test with two recipient yangs for 
        // a more detailed calculation when there is more than one recipient yang with different proportions 
        let total_recipient_troves_value: Wad = before_recipient_trove1_value
            + before_recipient_trove2_value;
        let expected_recipient_trove1_pct: Ray = wadray::rdiv_ww(
            before_recipient_trove1_value, total_recipient_troves_value
        );
        let expected_recipient_trove2_pct: Ray = wadray::rdiv_ww(
            before_recipient_trove2_value, total_recipient_troves_value
        );

        // Simulate purge with 0 yin to update the trove's debt
        let (_, _, redistributed_trove_value, redistributed_trove_debt) = shrine
            .get_trove_info(common::TROVE_1);
        shrine.melt(trove1_owner, common::TROVE_1, WadZeroable::zero());

        assert(shrine.get_redistributions_count() == 0, 'wrong start state');
        shrine.redistribute(common::TROVE_1);

        let expected_redistribution_id: u32 = 1;
        assert(
            shrine.get_redistributions_count() == expected_redistribution_id,
            'wrong redistribution count'
        );

        assert(shrine.get_trove_redistribution_id(common::TROVE_2) == 0, 'wrong redistribution id');
        // Trigger an update in recipient troves with an empty melt
        shrine.melt(trove1_owner, recipient_trove1, WadZeroable::zero());
        shrine.melt(trove1_owner, recipient_trove2, WadZeroable::zero());

        // TODO: checking equality with `expected_redistribution_id` causes `Unknown ap change` error
        assert(shrine.get_trove_redistribution_id(recipient_trove1) == 1, 'wrong id');
        assert(shrine.get_trove_redistribution_id(recipient_trove2) == 1, 'wrong id');

        let (_, _, after_recipient_trove1_value, after_recipient_trove1_debt) = shrine
            .get_trove_info(recipient_trove1);
        let (_, _, after_recipient_trove2_value, after_recipient_trove2_debt) = shrine
            .get_trove_info(recipient_trove2);

        // Check that troves 2 and 3 receives trove 1's yang1 and yang3
        assert(
            shrine.get_deposit(yang1_addr, redistributed_trove) == WadZeroable::zero(),
            'should be 0 yang 1 left'
        );
        let recipient_trove1_yang1_amt: Wad = shrine.get_deposit(yang1_addr, recipient_trove1);
        let expected_recipient_trove1_yang1_amt: Wad = wadray::rmul_wr(
            ShrineUtils::TROVE1_YANG1_DEPOSIT.into(), expected_recipient_trove1_pct
        );
        common::assert_equalish(
            recipient_trove1_yang1_amt,
            expected_recipient_trove1_yang1_amt,
            10_u128.into(), // error margin
            'wrong recipient trove 1 yang 1'
        );

        let recipient_trove2_yang1_amt: Wad = shrine.get_deposit(yang1_addr, recipient_trove2);
        let expected_recipient_trove2_yang1_amt: Wad = wadray::rmul_wr(
            ShrineUtils::TROVE1_YANG1_DEPOSIT.into(), expected_recipient_trove2_pct
        );
        common::assert_equalish(
            recipient_trove2_yang1_amt,
            expected_recipient_trove2_yang1_amt,
            10_u128.into(), // error margin
            'wrong recipient trove 2 yang 1'
        );

        common::assert_equalish(
            recipient_trove1_yang1_amt + recipient_trove2_yang1_amt,
            ShrineUtils::TROVE1_YANG1_DEPOSIT.into(),
            15_u128.into(), // error margin
            'yang invariant failed #1'
        );

        assert(
            shrine.get_deposit(yang2_addr, redistributed_trove) == WadZeroable::zero(),
            'should be 0 yang 2 left'
        );

        assert(
            shrine.get_deposit(yang3_addr, redistributed_trove) == WadZeroable::zero(),
            'should be 0 yang 3 left'
        );
        let recipient_trove1_yang3_amt: Wad = shrine.get_deposit(yang3_addr, recipient_trove1);
        let expected_recipient_trove1_yang3_amt: Wad = wadray::rmul_wr(
            ShrineUtils::TROVE1_YANG3_DEPOSIT.into(), expected_recipient_trove1_pct
        );
        common::assert_equalish(
            recipient_trove1_yang3_amt,
            expected_recipient_trove1_yang3_amt,
            10_u128.into(), // error margin
            'wrong recipient trove 1 yang 3'
        );

        let recipient_trove2_yang3_amt: Wad = shrine.get_deposit(yang3_addr, recipient_trove2);
        let expected_recipient_trove2_yang3_amt: Wad = wadray::rmul_wr(
            ShrineUtils::TROVE1_YANG3_DEPOSIT.into(), expected_recipient_trove2_pct
        );
        common::assert_equalish(
            recipient_trove2_yang3_amt,
            expected_recipient_trove2_yang3_amt,
            10_u128.into(), // error margin
            'wrong recipient trove 2 yang 3'
        );
        common::assert_equalish(
            recipient_trove1_yang3_amt + recipient_trove2_yang3_amt,
            ShrineUtils::TROVE1_YANG3_DEPOSIT.into(),
            10_u128.into(), // error margin
            'yang invariant failed #2'
        );

        // Check that recipient troves receives their proportion of trove 1's entire debt
        let expected_recipient_trove1_debt: Wad = before_recipient_trove1_debt
            + wadray::rmul_wr(redistributed_trove_debt, expected_recipient_trove1_pct);
        common::assert_equalish(
            after_recipient_trove1_debt,
            expected_recipient_trove1_debt,
            10_u128.into(), // error margin
            'wrong recipient trove 1 debt',
        );

        let expected_recipient_trove2_debt: Wad = before_recipient_trove2_debt
            + wadray::rmul_wr(redistributed_trove_debt, expected_recipient_trove2_pct);
        common::assert_equalish(
            after_recipient_trove2_debt,
            expected_recipient_trove2_debt,
            10_u128.into(), // error margin
            'wrong recipient trove 2 debt',
        );

        let recipient_troves_debt_increment: Wad = (after_recipient_trove1_debt
            - before_recipient_trove1_debt)
            + (after_recipient_trove2_debt - before_recipient_trove2_debt);
        common::assert_equalish(
            redistributed_trove_debt,
            recipient_troves_debt_increment,
            20_u128.into(), // error margin
            'wrong recipients debt increment',
        );

        // Check invariant that redistributed unit debt should be equal to all debt redistributed to troves
        // and the errors for all yangs
        let cumulative_error: Wad = get_redistributed_debt_error(
            shrine,
            ShrineUtils::three_yang_addrs(),
            expected_redistribution_id,
        );

        assert(
            redistributed_trove_debt == recipient_troves_debt_increment + cumulative_error,
            'debt invariant failed'
        );

        // Note that we cannot fully check the updated value of the recipient trove here because
        // we need the oracle to update the yang price for yang2 based on the new asset amount per 
        // yang2, but we can check the increase in value from yang1 and yang3.
        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let (yang3_price, _, _) = shrine.get_current_yang_price(yang3_addr);
        let expected_recipient_trove1_value: Wad = before_recipient_trove1_value
            + (recipient_trove1_yang1_amt * yang1_price)
            + (recipient_trove1_yang3_amt * yang3_price);

        common::assert_equalish(
            after_recipient_trove1_value,
            expected_recipient_trove1_value,
            10_u128.into(), // error margin
            'wrong recipient trove1 value'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_one_exceptional_redistribution_two_recipient_yangs() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        // Manually set up troves so that the redistributed trove (trove 1) uses all three yangs
        // while the recipient troves (troves 2 and 3) use only yang2 and yang3
        let yang1_addr = ShrineUtils::yang1_addr();
        let yang2_addr = ShrineUtils::yang2_addr();
        let yang3_addr = ShrineUtils::yang3_addr();

        let trove1_owner = common::trove1_owner_addr();
        let redistributed_trove: u64 = common::TROVE_1;

        set_contract_address(ShrineUtils::admin());
        shrine.deposit(yang1_addr, redistributed_trove, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, redistributed_trove, ShrineUtils::TROVE1_YANG2_DEPOSIT.into());
        shrine.deposit(yang3_addr, redistributed_trove, ShrineUtils::TROVE1_YANG3_DEPOSIT.into());
        shrine
            .forge(
                trove1_owner,
                redistributed_trove,
                ShrineUtils::TROVE1_FORGE_AMT.into(),
                0_u128.into()
            );

        let trove2_owner = common::trove2_owner_addr();
        let recipient_trove1: u64 = common::TROVE_2;
        shrine.deposit(yang2_addr, recipient_trove1, TROVE2_YANG2_DEPOSIT.into());
        shrine.deposit(yang3_addr, recipient_trove1, TROVE2_YANG3_DEPOSIT.into());
        shrine.forge(trove2_owner, recipient_trove1, TROVE2_FORGE_AMT.into(), 0_u128.into());

        let trove3_owner = common::trove3_owner_addr();
        let recipient_trove2: u64 = common::TROVE_3;
        shrine.deposit(yang2_addr, recipient_trove2, TROVE3_YANG2_DEPOSIT.into());
        shrine.deposit(yang3_addr, recipient_trove2, TROVE3_YANG3_DEPOSIT.into());
        shrine.forge(trove3_owner, recipient_trove2, TROVE3_FORGE_AMT.into(), 0_u128.into());

        let (_, _, before_recipient_trove1_value, before_recipient_trove1_debt) = shrine
            .get_trove_info(recipient_trove1);
        let (_, _, before_recipient_trove2_value, before_recipient_trove2_debt) = shrine
            .get_trove_info(recipient_trove2);

        let total_recipient_troves_value: Wad = before_recipient_trove1_value
            + before_recipient_trove2_value;
        let expected_recipient_trove1_pct: Ray = wadray::rdiv_ww(
            before_recipient_trove1_value, total_recipient_troves_value
        );
        let expected_recipient_trove2_pct: Ray = wadray::rdiv_ww(
            before_recipient_trove2_value, total_recipient_troves_value
        );

        // Simulate purge with 0 yin to update the trove's debt
        let (_, _, redistributed_trove_value, redistributed_trove_debt) = shrine
            .get_trove_info(common::TROVE_1);
        shrine.melt(trove1_owner, common::TROVE_1, WadZeroable::zero());

        assert(shrine.get_redistributions_count() == 0, 'wrong start state');
        shrine.redistribute(common::TROVE_1);

        let expected_redistribution_id: u32 = 1;
        assert(
            shrine.get_redistributions_count() == expected_redistribution_id,
            'wrong redistribution count'
        );

        assert(shrine.get_trove_redistribution_id(common::TROVE_2) == 0, 'wrong redistribution id');
        // Trigger an update in recipient troves with an empty melt
        shrine.melt(trove1_owner, recipient_trove1, WadZeroable::zero());
        shrine.melt(trove1_owner, recipient_trove2, WadZeroable::zero());

        // TODO: checking equality with `expected_redistribution_id` causes `Unknown ap change` error
        assert(shrine.get_trove_redistribution_id(recipient_trove1) == 1, 'wrong id');
        assert(shrine.get_trove_redistribution_id(recipient_trove2) == 1, 'wrong id');

        let (_, _, after_recipient_trove1_value, after_recipient_trove1_debt) = shrine
            .get_trove_info(recipient_trove1);
        let (_, _, after_recipient_trove2_value, after_recipient_trove2_debt) = shrine
            .get_trove_info(recipient_trove2);

        // Check that recipient troves receive trove 1's yang1
        assert(
            shrine.get_deposit(yang1_addr, redistributed_trove) == WadZeroable::zero(),
            'should be 0 yang 1 left'
        );
        let recipient_trove1_yang1_amt: Wad = shrine.get_deposit(yang1_addr, recipient_trove1);
        let expected_recipient_trove1_yang1_amt: Wad = wadray::rmul_wr(
            ShrineUtils::TROVE1_YANG1_DEPOSIT.into(), expected_recipient_trove1_pct
        );
        common::assert_equalish(
            recipient_trove1_yang1_amt,
            expected_recipient_trove1_yang1_amt,
            100_u128.into(), // error margin
            'wrong recipient trove 1 yang 1'
        );

        let recipient_trove2_yang1_amt: Wad = shrine.get_deposit(yang1_addr, recipient_trove2);
        let expected_recipient_trove2_yang1_amt: Wad = wadray::rmul_wr(
            ShrineUtils::TROVE1_YANG1_DEPOSIT.into(), expected_recipient_trove2_pct
        );
        common::assert_equalish(
            recipient_trove2_yang1_amt,
            expected_recipient_trove2_yang1_amt,
            100_u128.into(), // error margin
            'wrong recipient trove 2 yang 1'
        );

        common::assert_equalish(
            recipient_trove1_yang1_amt + recipient_trove2_yang1_amt,
            ShrineUtils::TROVE1_YANG1_DEPOSIT.into(),
            100_u128.into(), // error margin
            'wrong recipient troves yang 1'
        );

        assert(
            shrine.get_deposit(yang2_addr, redistributed_trove) == WadZeroable::zero(),
            'should be 0 yang 2 left'
        );
        assert(
            shrine.get_deposit(yang3_addr, redistributed_trove) == WadZeroable::zero(),
            'should be 0 yang 3 left'
        );

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let redistributed_yang1_value: Wad = ShrineUtils::TROVE1_YANG1_DEPOSIT.into() * yang1_price;

        let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr);
        let redistributed_yang2_value: Wad = ShrineUtils::TROVE1_YANG2_DEPOSIT.into() * yang2_price;

        let (yang3_price, _, _) = shrine.get_current_yang_price(yang3_addr);
        let redistributed_yang3_value: Wad = ShrineUtils::TROVE1_YANG3_DEPOSIT.into() * yang3_price;

        // Amount of debt redistributed for each yang
        let redistributed_yang1_debt: Wad = wadray::rmul_wr(
            redistributed_trove_debt,
            wadray::rdiv_ww(redistributed_yang1_value, redistributed_trove_value)
        );

        let redistributed_yang2_debt: Wad = wadray::rmul_wr(
            redistributed_trove_debt,
            wadray::rdiv_ww(redistributed_yang2_value, redistributed_trove_value)
        );

        let redistributed_yang3_debt: Wad = wadray::rmul_wr(
            redistributed_trove_debt,
            wadray::rdiv_ww(redistributed_yang3_value, redistributed_trove_value)
        );

        // Sanity check
        assert(
            redistributed_yang1_debt
                + redistributed_yang2_debt
                + redistributed_yang3_debt < redistributed_trove_debt,
            'should not exceed trove debt'
        );

        // Calculate the percentage of debt redistributed to each yang, and each recipient trove's entitlement
        // to each portion.
        let other_troves_value: Wad = before_recipient_trove1_value + before_recipient_trove2_value;
        let other_troves_yang2_amt: Wad = (TROVE2_YANG2_DEPOSIT + TROVE3_YANG2_DEPOSIT).into();
        let other_troves_yang2_value: Wad = other_troves_yang2_amt * yang2_price;

        let other_troves_yang3_amt: Wad = (TROVE2_YANG3_DEPOSIT + TROVE3_YANG3_DEPOSIT).into();
        let other_troves_yang3_value: Wad = other_troves_yang3_amt * yang3_price;

        let yang1_debt_redistributed_to_yang2: Wad = wadray::rmul_wr(
            redistributed_yang1_debt, wadray::rdiv_ww(other_troves_yang2_value, other_troves_value), 
        );
        let yang1_debt_redistributed_to_yang3: Wad = wadray::rmul_wr(
            redistributed_yang1_debt, wadray::rdiv_ww(other_troves_yang3_value, other_troves_value), 
        );

        assert(
            yang1_debt_redistributed_to_yang2
                + yang1_debt_redistributed_to_yang3 < redistributed_yang1_debt,
            'should not exceed'
        );

        let recipient_trove1_yang2_pct: Ray = wadray::rdiv_ww(
            TROVE2_YANG2_DEPOSIT.into(), other_troves_yang2_amt
        );
        let recipient_trove2_yang2_pct: Ray = wadray::rdiv_ww(
            TROVE3_YANG2_DEPOSIT.into(), other_troves_yang2_amt
        );

        let recipient_trove1_yang3_pct: Ray = wadray::rdiv_ww(
            TROVE2_YANG3_DEPOSIT.into(), other_troves_yang3_amt
        );
        let recipient_trove2_yang3_pct: Ray = wadray::rdiv_ww(
            TROVE3_YANG3_DEPOSIT.into(), other_troves_yang3_amt
        );

        let expected_recipient_trove1_debt: Wad = before_recipient_trove1_debt
            + wadray::rmul_wr(yang1_debt_redistributed_to_yang2, recipient_trove1_yang2_pct)
            + // Redistributed debt from yang 1 to yang 2 
            wadray::rmul_wr(yang1_debt_redistributed_to_yang3, recipient_trove1_yang3_pct)
            + // Redistributed debt from yang 1 to yang 3
            wadray::rmul_wr(redistributed_yang2_debt, recipient_trove1_yang2_pct)
            + // Redistributed debt from yang 2 to yang 2
            wadray::rmul_wr(
                redistributed_yang3_debt, recipient_trove1_yang3_pct
            ); // Redistributed debt from yang 3 to yang 3

        common::assert_equalish(
            after_recipient_trove1_debt,
            expected_recipient_trove1_debt,
            100_u128.into(), // error margin
            'wrong recipient trove 1 debt',
        );

        let expected_recipient_trove2_debt: Wad = before_recipient_trove2_debt
            + wadray::rmul_wr(yang1_debt_redistributed_to_yang2, recipient_trove2_yang2_pct)
            + // Redistributed debt from yang 1 to yang 2 
            wadray::rmul_wr(yang1_debt_redistributed_to_yang3, recipient_trove2_yang3_pct)
            + // Redistributed debt from yang 1 to yang 3
            wadray::rmul_wr(redistributed_yang2_debt, recipient_trove2_yang2_pct)
            + // Redistributed debt from yang 2 to yang 2
            wadray::rmul_wr(
                redistributed_yang3_debt, recipient_trove2_yang3_pct
            ); // Redistributed debt from yang 3 to yang 3

        common::assert_equalish(
            after_recipient_trove2_debt,
            expected_recipient_trove2_debt,
            100_u128.into(), // error margin
            'wrong recipient trove 2 debt',
        );

        let recipient_troves_debt_increment: Wad = (after_recipient_trove1_debt
            - before_recipient_trove1_debt)
            + (after_recipient_trove2_debt - before_recipient_trove2_debt);
        common::assert_equalish(
            redistributed_trove_debt,
            recipient_troves_debt_increment,
            100_u128.into(), // error margin
            'wrong recipients debt increment',
        );

        // Check invariant that redistributed unit debt should be equal to all debt redistributed to troves
        // and the errors for all yangs
        let cumulative_error: Wad = get_redistributed_debt_error(
            shrine,
            ShrineUtils::three_yang_addrs(),
            expected_redistribution_id,
        );
        
        assert(
            redistributed_trove_debt == recipient_troves_debt_increment + cumulative_error,
            'redistribution invariant failed'
        );

        // Note that we cannot fully check the updated value of the recipient trove here because
        // we need the oracle to update the yang price for yang2 and yang3 based on the new asset 
        // amount yang, but we can check the increase in value from yang1.
        let expected_recipient_trove1_value: Wad = before_recipient_trove1_value
            + (recipient_trove1_yang1_amt * yang1_price);
        common::assert_equalish(
            after_recipient_trove1_value,
            expected_recipient_trove1_value,
            100_u128.into(), // error margin
            'wrong recipient trove 1 value'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_multiple_exceptional_redistribution() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        // Manually set up troves so that the redistributed trove (trove 1) uses all three yangs
        // while the recipient troves (trove 2 and 3) uses only yang 2.
        let yang1_addr = ShrineUtils::yang1_addr();
        let yang2_addr = ShrineUtils::yang2_addr();
        let yang3_addr = ShrineUtils::yang3_addr();

        let trove1_owner = common::trove1_owner_addr();
        let redistributed_trove1: u64 = common::TROVE_1;

        set_contract_address(ShrineUtils::admin());
        shrine.deposit(yang1_addr, redistributed_trove1, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, redistributed_trove1, ShrineUtils::TROVE1_YANG2_DEPOSIT.into());
        shrine.deposit(yang3_addr, redistributed_trove1, ShrineUtils::TROVE1_YANG3_DEPOSIT.into());
        shrine
            .forge(
                trove1_owner,
                redistributed_trove1,
                ShrineUtils::TROVE1_FORGE_AMT.into(),
                0_u128.into()
            );

        let trove2_owner = common::trove2_owner_addr();
        let recipient_trove: u64 = common::TROVE_2;
        shrine.deposit(yang2_addr, recipient_trove, TROVE2_YANG2_DEPOSIT.into());
        shrine.forge(trove2_owner, recipient_trove, TROVE2_FORGE_AMT.into(), 0_u128.into());

        let trove3_owner = common::trove3_owner_addr();
        let redistributed_trove2: u64 = common::TROVE_3;
        shrine.deposit(yang2_addr, redistributed_trove2, TROVE3_YANG2_DEPOSIT.into());
        shrine.forge(trove3_owner, redistributed_trove2, TROVE3_FORGE_AMT.into(), 0_u128.into());

        let start_total_debt: Wad = shrine.get_total_debt();

        // Simulate purge with 0 yin to update the trove's debt
        let (_, _, before_recipient_trove_value, before_recipient_trove_debt) = shrine
            .get_trove_info(recipient_trove);
        // Redistributed trove 2 is first a recipient in the first redistribution
        let (_, _, before_recipient_trove2_value, before_recipient_trove2_debt) = shrine
            .get_trove_info(redistributed_trove2);

        let total_recipient_troves_value: Wad = before_recipient_trove_value
            + before_recipient_trove2_value;
        let expected_recipient_trove1_pct: Ray = wadray::rdiv_ww(
            before_recipient_trove_value, total_recipient_troves_value
        );

        shrine.melt(trove1_owner, common::TROVE_1, WadZeroable::zero());
        shrine.redistribute(redistributed_trove1);

        // At this point, both troves 2 and 3 have some amount of each yang.
        // Redistribute trove 3 next to check that the originally redistributed 
        // yang 1 for trove 3 is properly redistributed to trove 2, even if trove 2
        // is not updated.
        shrine.melt(trove3_owner, redistributed_trove2, WadZeroable::zero());
        shrine.redistribute(redistributed_trove2);

        assert(shrine.get_redistributions_count() == 2, 'wrong redistributions count');

        // Trigger an update in recipient troves with an empty melt
        shrine.melt(trove1_owner, recipient_trove, WadZeroable::zero());

        let expected_redistribution_id: u32 = 2;
        assert(shrine.get_trove_redistribution_id(recipient_trove) == 2, 'wrong id');

        let (_, _, after_recipient_trove_value, after_recipient_trove_debt) = shrine
            .get_trove_info(recipient_trove);
        
        //
        // Debt assertion
        //
        
        // Recipient trove should have the total debt before all redistributions
        // minus some loss of precision
        common::assert_equalish(
            after_recipient_trove_debt,
            start_total_debt, 
            10_u128.into(), // error margin
            'wrong recipient trove debt'
        );

        let cumulative_error: Wad = get_redistributed_debt_error(
            shrine,
            ShrineUtils::three_yang_addrs(),
            expected_redistribution_id,
        );
        assert(
            start_total_debt == after_recipient_trove_debt + cumulative_error,
            'debt invariant failed'
        );

        //
        // Yangs assertions
        //

        assert(
            shrine.get_deposit(yang1_addr, redistributed_trove2) == WadZeroable::zero(),
            'should be 0 yang 1 left'
        );
        // Recipient trove's yang 1 amount should be the amount received from the first 
        // redistribution, since the second redistribution would have rebased
        let recipient_trove_yang1_amt : Wad = shrine.get_deposit(yang1_addr, recipient_trove);
        let expected_recipient_trove_yang1_amt: Wad = wadray::rmul_wr(
            ShrineUtils::TROVE1_YANG1_DEPOSIT.into(), expected_recipient_trove1_pct
        );
        common::assert_equalish(
            recipient_trove_yang1_amt,
            expected_recipient_trove_yang1_amt,
            100_u128.into(), // error margin
            'wrong recipient trove yang 1'
        );
        // Check that the second redistributed trove's yang1 has been rebased
        common::assert_equalish(
            shrine.get_yang_total(yang1_addr),
            recipient_trove_yang1_amt + shrine.get_initial_yang_amt(yang1_addr),
            20_u128.into(), // error margin due to loss of precision in favour of protocol
            'wrong total yang 1'
        );

        assert(
            shrine.get_deposit(yang2_addr, redistributed_trove2) == WadZeroable::zero(),
            'should be 0 yang 2 left'
        );
        let recipient_trove_yang2_amt: Wad = shrine.get_deposit(yang2_addr, recipient_trove);
        // Recipient trove's yang2 should stay constant since all redistributions were via rebasing
        assert(recipient_trove_yang2_amt == TROVE2_YANG2_DEPOSIT.into(), 'wrong recipient trove yang 2');
        assert(shrine.get_yang_total(yang2_addr) == TROVE2_YANG2_DEPOSIT.into() + shrine.get_initial_yang_amt(yang2_addr), 'wrong total yang 2');

        assert(
            shrine.get_deposit(yang3_addr, redistributed_trove2) == WadZeroable::zero(),
            'should be 0 yang 3 left'
        );
        // Recipient trove's yang 3 amount should be the amount received from the first 
        // redistribution, since the second redistribution would have rebased
        let recipient_trove_yang3_amt : Wad = shrine.get_deposit(yang3_addr, recipient_trove);
        let expected_recipient_trove_yang3_amt: Wad = wadray::rmul_wr(
            ShrineUtils::TROVE1_YANG3_DEPOSIT.into(), expected_recipient_trove1_pct
        );
        common::assert_equalish(
            recipient_trove_yang3_amt,
            expected_recipient_trove_yang3_amt,
            100_u128.into(), // error margin
            'wrong recipient trove yang 3'
        );
        // Check that the second redistributed trove's yang3 has been rebased
        common::assert_equalish(
            shrine.get_yang_total(yang3_addr),
            recipient_trove_yang3_amt + shrine.get_initial_yang_amt(yang3_addr),
            10_u128.into(), // error margin due to loss of precision in favour of protocol
            'wrong total yang 3'
        );
    }
}
