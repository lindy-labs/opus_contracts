#[cfg(test)]
mod TestShrineRedistribution {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use traits::{Default, Into};
    use starknet::ContractAddress;
    use starknet::testing::set_contract_address;

    use aura::core::shrine::Shrine;

    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::serde;
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, Wad, WadZeroable};

    use aura::tests::shrine::utils::ShrineUtils;

    //
    // Setup
    //

    const TROVE2_YANG1_DEPOSIT: u128 = 2370000000000000000; // 2.37 (Wad)
    const TROVE2_YANG2_DEPOSIT: u128 = 8310000000000000000; // 8.31 (Wad)
    const TROVE2_FORGE_AMT: u128 = 3456000000000000000000; // 3_456 (Wad)

    const TROVE3_YANG1_DEPOSIT: u128 = 4950000000000000000; // 4.95 (Wad)
    const TROVE3_YANG2_DEPOSIT: u128 = 6500000000000000000; // 6.5 (Wad)
    const TROVE3_FORGE_AMT: u128 = 2222000000000000000000; // 2_222 (Wad)

    fn setup_trove1(shrine: IShrineDispatcher) {
        let yang1_addr = ShrineUtils::yang1_addr();
        let yang2_addr = ShrineUtils::yang2_addr();

        let trove1_owner = ShrineUtils::trove1_owner_addr();
        shrine.deposit(yang1_addr, ShrineUtils::TROVE_1, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, ShrineUtils::TROVE_1, ShrineUtils::TROVE1_YANG2_DEPOSIT.into());
        shrine
            .forge(
                trove1_owner,
                ShrineUtils::TROVE_1,
                ShrineUtils::TROVE1_FORGE_AMT.into(),
                0_u128.into()
            );
    }

    fn setup_trove2(shrine: IShrineDispatcher) {
        let yang1_addr = ShrineUtils::yang1_addr();
        let yang2_addr = ShrineUtils::yang2_addr();

        let trove2_owner = ShrineUtils::trove2_owner_addr();
        shrine.deposit(yang1_addr, ShrineUtils::TROVE_2, TROVE2_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, ShrineUtils::TROVE_2, TROVE2_YANG2_DEPOSIT.into());
        shrine.forge(trove2_owner, ShrineUtils::TROVE_2, TROVE2_FORGE_AMT.into(), 0_u128.into());
    }

    fn setup_trove3(shrine: IShrineDispatcher) {
        let yang1_addr = ShrineUtils::yang1_addr();
        let yang2_addr = ShrineUtils::yang2_addr();

        let trove3_owner = ShrineUtils::trove3_owner_addr();
        shrine.deposit(yang1_addr, ShrineUtils::TROVE_3, TROVE3_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, ShrineUtils::TROVE_3, TROVE3_YANG2_DEPOSIT.into());
        shrine.forge(trove3_owner, ShrineUtils::TROVE_3, TROVE3_FORGE_AMT.into(), 0_u128.into());
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
                    let mut expected_yang_debt = yang_value / trove_value * trove_debt;
                    cumulative_redistributed_debt += expected_yang_debt;
                    let remainder = trove_debt - cumulative_redistributed_debt;
                    if remainder < Shrine::ROUNDING_THRESHOLD.into() {
                        expected_yang_debt += remainder;
                        cumulative_redistributed_debt += remainder;
                    }

                    let expected_remaining_yang = shrine.get_yang_total(*yang) - deposited;
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
                    let mut expected_yang_debt = (*redistributed_trove_yang_values
                        .pop_front()
                        .unwrap()
                        / redistributed_trove_value)
                        * redistributed_trove_debt;
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
                    let unit_debt = shrine
                        .get_redistributed_unit_debt_for_yang(*yang, expected_redistribution_id);
                    ShrineUtils::assert_equalish(
                        expected_unit_debt, unit_debt, 1_u128.into(), 'wrong unit debt'
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

        let (_, _, _, before_trove2_debt) = shrine.get_trove_info(ShrineUtils::TROVE_2);

        // Note order is reversed to match `yang_addrs`
        let mut trove2_yang_deposits: Array<Wad> = Default::default();
        trove2_yang_deposits.append(TROVE2_YANG2_DEPOSIT.into());
        trove2_yang_deposits.append(TROVE2_YANG1_DEPOSIT.into());
        let mut trove2_yang_deposits = trove2_yang_deposits.span();

        let yang_addrs: Span<ContractAddress> = ShrineUtils::yang_addrs();
        let (trove1_yang_values, expected_unit_debts, expected_errors, expected_remaining_yangs) =
            preview_trove_redistribution(
            shrine, yang_addrs, ShrineUtils::TROVE_1
        );

        // Simulate purge with 0 yin to update the trove's debt
        set_contract_address(ShrineUtils::admin());
        let trove1_owner = ShrineUtils::trove1_owner_addr();
        let (_, _, trove1_value, trove1_debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        shrine.melt(trove1_owner, ShrineUtils::TROVE_1, WadZeroable::zero());

        assert(shrine.get_redistributions_count() == 0, 'wrong start state');
        shrine.redistribute(ShrineUtils::TROVE_1);

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
            ShrineUtils::TROVE_1,
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

        let (_, _, _, after_trove2_debt) = shrine.get_trove_info(ShrineUtils::TROVE_2);

        assert(after_trove2_debt == expected_trove2_debt, 'wrong debt after redistribution');

        assert(
            shrine.get_trove_redistribution_id(ShrineUtils::TROVE_2) == 0, 'wrong redistribution id'
        );
        // Trigger an update in trove 2 with an empty melt
        shrine.melt(trove1_owner, ShrineUtils::TROVE_2, WadZeroable::zero());
        // TODO: checking equality with `expected_redistribution_id` causes `Unknown ap change` error
        assert(shrine.get_trove_redistribution_id(ShrineUtils::TROVE_2) == 1, 'wrong id');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_two_redistributions() {
        let shrine: IShrineDispatcher = redistribution_setup();

        let yang_addrs: Span<ContractAddress> = ShrineUtils::yang_addrs();
        let (_, _, expected_trove1_errors, _) = preview_trove_redistribution(
            shrine, yang_addrs, ShrineUtils::TROVE_1
        );

        // Perform first redistribution - covered by previous test
        set_contract_address(ShrineUtils::admin());
        shrine.melt(ShrineUtils::trove1_owner_addr(), ShrineUtils::TROVE_1, WadZeroable::zero());
        shrine.redistribute(ShrineUtils::TROVE_1);

        let trove2_owner = ShrineUtils::trove2_owner_addr();

        let (_, _, trove2_value, trove2_debt) = shrine.get_trove_info(ShrineUtils::TROVE_2);
        let (_, _, _, before_trove3_debt) = shrine.get_trove_info(ShrineUtils::TROVE_3);

        let (mut trove2_yang_values, _, _, expected_remaining_yangs) = preview_trove_redistribution(
            shrine, yang_addrs, ShrineUtils::TROVE_2
        );

        // Perform second redistribution
        shrine.melt(trove2_owner, ShrineUtils::TROVE_2, WadZeroable::zero());
        let (_, _, _, redistributed_debt) = shrine.get_trove_info(ShrineUtils::TROVE_2);

        shrine.redistribute(ShrineUtils::TROVE_2);

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
            ShrineUtils::TROVE_2,
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

        let (_, _, _, after_trove3_debt) = shrine.get_trove_info(ShrineUtils::TROVE_3);
        assert(after_trove3_debt == expected_trove3_debt, 'wrong debt after redistribution');

        assert(
            shrine.get_trove_redistribution_id(ShrineUtils::TROVE_3) == 0, 'wrong redistribution id'
        );
        // Trigger an update in trove 3 with an empty melt
        shrine.melt(trove2_owner, ShrineUtils::TROVE_3, WadZeroable::zero());
        // TODO: checking equality with `expected_redistribution_id` causes `Unknown ap change` error
        assert(shrine.get_trove_redistribution_id(ShrineUtils::TROVE_3) == 2, 'wrong id');
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

        let trove2_owner = ShrineUtils::trove2_owner_addr();
        let trove2_yang1_amt: Wad = 1000_u128.into(); // 1E-15 (Wad)
        let trove2_yang2_amt: Wad = 1000000000000000000000_u128.into(); // 1_000 (Wad)
        shrine.deposit(yang1_addr, ShrineUtils::TROVE_2, trove2_yang1_amt);
        shrine.deposit(yang2_addr, ShrineUtils::TROVE_2, trove2_yang2_amt);
        shrine.forge(trove2_owner, ShrineUtils::TROVE_2, TROVE2_FORGE_AMT.into(), 0_u128.into());

        // Get information before redistribution
        let (_, _, trove2_value, trove2_debt) = shrine.get_trove_info(ShrineUtils::TROVE_2);

        let yang_addrs: Span<ContractAddress> = ShrineUtils::yang_addrs();

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
        shrine.melt(trove2_owner, ShrineUtils::TROVE_2, WadZeroable::zero());
        shrine.redistribute(ShrineUtils::TROVE_2);

        // Check that yang 1 unit debt is zero
        let expected_redistribution_id: u32 = 1;
        assert(
            shrine.get_redistributions_count() == expected_redistribution_id,
            'wrong redistribution count'
        );
        assert(
            shrine
                .get_redistributed_unit_debt_for_yang(
                    yang1_addr, expected_redistribution_id
                ) == WadZeroable::zero(),
            'should be skipped'
        );

        // Check that all of trove 2's debt was distributed to yang 2
        let expected_remaining_yang2: Wad = (ShrineUtils::TROVE1_YANG2_DEPOSIT
            + TROVE3_YANG2_DEPOSIT)
            .into();
        let expected_unit_debt_for_yang2 = trove2_debt / expected_remaining_yang2;
        assert(
            shrine
                .get_redistributed_unit_debt_for_yang(
                    yang2_addr, expected_redistribution_id
                ) == expected_unit_debt_for_yang2,
            'wrong unit debt'
        );
    }
}