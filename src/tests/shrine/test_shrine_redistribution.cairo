#[cfg(test)]
mod TestShrine {
    use array::{ArrayTrait, SpanTrait};
    use integer::BoundedU256;
    use option::OptionTrait;
    use traits::{Default, Into};
    use starknet::{contract_address_const, ContractAddress};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;

    use aura::core::shrine::Shrine;
    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::serde;
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{
        Ray, RayZeroable, RAY_ONE, RAY_SCALE, Wad, WadZeroable, WAD_DECIMALS, WAD_SCALE
    };

    use aura::tests::shrine::utils::ShrineUtils;

    use debug::PrintTrait;

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
        shrine.forge(trove1_owner, ShrineUtils::TROVE_1, ShrineUtils::TROVE1_FORGE_AMT.into());
    }

    fn setup_trove2(shrine: IShrineDispatcher) {
        let yang1_addr = ShrineUtils::yang1_addr();
        let yang2_addr = ShrineUtils::yang2_addr();

        let trove2_owner = ShrineUtils::trove2_owner_addr();
        shrine.deposit(yang1_addr, ShrineUtils::TROVE_2, TROVE2_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, ShrineUtils::TROVE_2, TROVE2_YANG2_DEPOSIT.into());
        shrine.forge(trove2_owner, ShrineUtils::TROVE_2, TROVE2_FORGE_AMT.into());
    }

    fn setup_trove3(shrine: IShrineDispatcher) {
        let yang1_addr = ShrineUtils::yang1_addr();
        let yang2_addr = ShrineUtils::yang2_addr();

        let trove3_owner = ShrineUtils::trove3_owner_addr();
        shrine.deposit(yang1_addr, ShrineUtils::TROVE_3, TROVE3_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, ShrineUtils::TROVE_3, TROVE3_YANG2_DEPOSIT.into());
        shrine.forge(trove3_owner, ShrineUtils::TROVE_3, TROVE3_FORGE_AMT.into());
    }

    // Helper function to set up three troves
    // - Trove 1 deposits and forges the amounts specified in `src/tests/shrine/utils.cairo`
    // - Trove 2 mimics trove 1 except with all amounts halved
    // - Trove 3 deposits and forges the amounts specified in this file
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
    fn preview_trove_redistribution(shrine: IShrineDispatcher, mut yang_addrs: Span<ContractAddress>, trove: u64) -> (Span<Wad>, Span<Wad>, Span<Wad>) {
        let (_, _, trove_value, trove_debt) = shrine.get_trove_info(trove);

        let mut trove_yang_values: Array<Wad> = Default::default();
        let mut expected_unit_debts: Array<Wad> = Default::default();
        let mut expected_errors: Array<Wad> = Default::default();

        loop {
            match yang_addrs.pop_front() {
                Option::Some(yang) => {
                    // Calculate value liquidated for each yang
                    let deposited = shrine.get_deposit(*yang, trove);
                    let (yang_price, _, _) = shrine.get_current_yang_price(*yang);
                    let yang_value = yang_price * deposited;

                    trove_yang_values.append(yang_price * deposited);

                    // Calculate error after redistributing debt for each yang
                    let expected_yang_debt = yang_value / trove_value * trove_debt;
                    let expected_remaining_yang = shrine.get_yang_total(*yang) - deposited;
                    let expected_unit_debt = expected_yang_debt / expected_remaining_yang;
                    expected_unit_debts.append(expected_unit_debt);

                    let actual_redistributed_debt = expected_unit_debt * expected_remaining_yang;
                    let expected_error = expected_yang_debt - actual_redistributed_debt;

                    expected_errors.append(expected_error);
                },
                Option::None(_) => {
                    break;
                }
            };
        };
        (trove_yang_values.span(), expected_unit_debts.span(), expected_errors.span())
    }

    //
    // Tests
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_one_redistribution() {
        let shrine: IShrineDispatcher = redistribution_setup();

        let (_, _, _, before_trove2_debt) = shrine.get_trove_info(ShrineUtils::TROVE_2);

        let mut trove2_yang_deposits: Array<Wad> = Default::default();
        trove2_yang_deposits.append(TROVE2_YANG1_DEPOSIT.into());
        trove2_yang_deposits.append(TROVE2_YANG2_DEPOSIT.into());
        let mut trove2_yang_deposits = trove2_yang_deposits.span();

        let yang_addrs: Span<ContractAddress> = ShrineUtils::yang_addrs();
        let (mut trove1_yang_values, mut expected_unit_debts, _) = preview_trove_redistribution(shrine, yang_addrs, ShrineUtils::TROVE_1);

        // Simulate purge with 0 yin to update the trove's debt
        set_contract_address(ShrineUtils::admin());
        let trove1_owner = ShrineUtils::trove1_owner_addr();
        shrine.melt(trove1_owner, ShrineUtils::TROVE_1, WadZeroable::zero());

        assert(shrine.get_redistributions_count() == 0, 'wrong start state');
        shrine.redistribute(ShrineUtils::TROVE_1);

        let expected_redistribution_id: u32 = 1;
        assert(shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count');

        let mut expected_trove2_debt = before_trove2_debt;

        let mut yang_addrs_copy = yang_addrs;
        loop {
            match yang_addrs_copy.pop_front() {
                Option::Some(yang) => {
                    assert(shrine.get_deposit(*yang, ShrineUtils::TROVE_1) == WadZeroable::zero(), 'deposit should be 0');

                    let unit_debt = shrine.get_redistributed_unit_debt_for_yang(*yang, expected_redistribution_id);
                    let expected_unit_debt = *expected_unit_debts.pop_front().unwrap();
                    assert(unit_debt == expected_unit_debt, 'wrong unit debt');

                    let trove2_yang_deposit = *trove2_yang_deposits.pop_front().unwrap();
                    expected_trove2_debt += trove2_yang_deposit * expected_unit_debt;
                },
                Option::None(_) => {
                    break;
                }
            };
        };

        let (_, _, _, after_trove2_debt) = shrine.get_trove_info(ShrineUtils::TROVE_2);

        assert(after_trove2_debt == expected_trove2_debt, 'wrong debt after redistribution');
        
        //assert(shrine.get_trove_redistribution_id(ShrineUtils::TROVE_2) == 0, 'wrong redistribution id');
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
        let (_, _, mut expected_trove1_errors) = preview_trove_redistribution(shrine, yang_addrs, ShrineUtils::TROVE_1);

        // Skip to 2nd redistribution
        // Simulate purge with 0 yin to update the trove's debt
        set_contract_address(ShrineUtils::admin());
        shrine.melt(ShrineUtils::trove1_owner_addr(), ShrineUtils::TROVE_1, WadZeroable::zero());
        shrine.redistribute(ShrineUtils::TROVE_1);

        let trove2_owner = ShrineUtils::trove2_owner_addr();

        let (_, _, trove2_value, trove2_debt) = shrine.get_trove_info(ShrineUtils::TROVE_2);
        let (_, _, _, before_trove3_debt) = shrine.get_trove_info(ShrineUtils::TROVE_3);

        let (mut trove2_yang_values, _, _) = preview_trove_redistribution(shrine, yang_addrs, ShrineUtils::TROVE_2);

        let mut expected_remaining_yangs: Array<Wad> = Default::default();
        expected_remaining_yangs.append(TROVE3_YANG1_DEPOSIT.into());
        expected_remaining_yangs.append(TROVE3_YANG2_DEPOSIT.into());
        let mut expected_remaining_yangs = expected_remaining_yangs.span();

        shrine.melt(trove2_owner, ShrineUtils::TROVE_2, WadZeroable::zero());
        shrine.redistribute(ShrineUtils::TROVE_2);

        let expected_redistribution_id: u32 = 2;
        assert(shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count');

        let mut expected_trove3_debt = before_trove3_debt;

        let mut yang_addrs_copy = yang_addrs;

        loop {
            match yang_addrs_copy.pop_front() {
                Option::Some(yang) => {
                    assert(shrine.get_deposit(*yang, ShrineUtils::TROVE_2) == WadZeroable::zero(), 'deposit should be 0');

                    let trove3_yang_deposit = *expected_remaining_yangs.pop_front().unwrap();

                    let remaining_yang = trove3_yang_deposit;

                    // Calculate the amount of debt redistributed for the yang, including the error 
                    // from trove 1's redistribution
                    let mut expected_yang_debt = (*trove2_yang_values.pop_front().unwrap() / trove2_value) * trove2_debt;
                    expected_yang_debt += *expected_trove1_errors.pop_front().unwrap();

                    let expected_unit_debt = expected_yang_debt / remaining_yang;
                    let unit_debt = shrine.get_redistributed_unit_debt_for_yang(*yang, expected_redistribution_id);
                    assert(expected_unit_debt == unit_debt, 'wrong unit debt');

                    expected_trove3_debt += trove3_yang_deposit * expected_unit_debt;
                },
                Option::None(_) => {
                    break;
                }
            };
        };
        
        let (_, _, _, after_trove3_debt) = shrine.get_trove_info(ShrineUtils::TROVE_3);
        assert(after_trove3_debt == expected_trove3_debt, 'wrong debt after redistribution');
        
        // Trigger an update in trove 3 with an empty melt
        shrine.melt(trove2_owner, ShrineUtils::TROVE_3, WadZeroable::zero());
        // TODO: checking equality with `expected_redistribution_id` causes `Unknown ap change` error
        assert(shrine.get_trove_redistribution_id(ShrineUtils::TROVE_3) == 2, 'wrong id');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_redistribute_dust_yang_rounding() {
        // Manually set up troves so that the redistributed trove has a dust amount of one
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        setup_trove1(shrine);
        setup_trove3(shrine);

        let yang1_addr = ShrineUtils::yang1_addr();
        let yang2_addr = ShrineUtils::yang2_addr();

        let trove2_owner = ShrineUtils::trove2_owner_addr();
        let trove2_yang1_amt: Wad = 1000_u128.into();  // 1E-15 (Wad)
        let trove2_yang2_amt: Wad = 1000000000000000000000_u128.into();  // 1_000 (Wad)
        shrine.deposit(yang1_addr, ShrineUtils::TROVE_2, trove2_yang1_amt);
        shrine.deposit(yang2_addr, ShrineUtils::TROVE_2, trove2_yang2_amt);
        shrine.forge(trove2_owner, ShrineUtils::TROVE_2, TROVE2_FORGE_AMT.into());

        // Save information before redistribution
        let (_, _, trove2_value, trove2_debt) = shrine.get_trove_info(ShrineUtils::TROVE_2);
   
        let yang_addrs: Span<ContractAddress> = ShrineUtils::yang_addrs();
        let (trove2_yang_values, _, _) = preview_trove_redistribution(shrine, yang_addrs, ShrineUtils::TROVE_2);

        // Sanity check that the amount of debt attributed to YANG_2 falls below the thre
        let trove2_yang1_debt = wadray::rmul_rw(wadray::rdiv_ww(*trove2_yang_values.at(0), trove2_value), trove2_debt);
        assert(trove2_yang1_debt < Shrine::ROUNDING_THRESHOLD.into(), 'not below rounding threshold');

        // Redistribute trove 2
        shrine.melt(trove2_owner, ShrineUtils::TROVE_2, WadZeroable::zero());
        shrine.redistribute(ShrineUtils::TROVE_2);

        // Check that yang 1 unit debt is not zero
        let expected_redistribution_id: u32 = 1;
        assert(shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count');
        assert(shrine.get_redistributed_unit_debt_for_yang(yang1_addr, expected_redistribution_id) == WadZeroable::zero(), 'should be skipped');
        
        // Check that all of trove 2's debt was distributed to yang 2
        let expected_remaining_yang2: Wad = (ShrineUtils::TROVE1_YANG2_DEPOSIT + TROVE3_YANG2_DEPOSIT).into();
        let expected_unit_debt_for_yang2 = trove2_debt / expected_remaining_yang2;
        assert(shrine.get_redistributed_unit_debt_for_yang(yang2_addr, expected_redistribution_id) == expected_unit_debt_for_yang2, 'wrong unit debt');
    }
}
