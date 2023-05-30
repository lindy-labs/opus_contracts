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

    // Helper function to set up three troves
    // - Trove 1 deposits and forges the amounts specified in `src/tests/shrine/utils.cairo`
    // - Trove 2 mimics trove 1 except with all amounts halved
    // - Trove 3 deposits and forges the amounts specified in this file
    fn redistribution_setup() -> IShrineDispatcher {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        let yang1_addr = ShrineUtils::yang1_addr();
        let yang2_addr = ShrineUtils::yang2_addr();

        set_contract_address(ShrineUtils::admin());
        
        let trove1_owner = ShrineUtils::trove1_owner_addr();
        shrine.deposit(yang1_addr, ShrineUtils::TROVE_1, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, ShrineUtils::TROVE_1, ShrineUtils::TROVE1_YANG2_DEPOSIT.into());
        shrine.forge(trove1_owner, ShrineUtils::TROVE_1, ShrineUtils::TROVE1_FORGE_AMT.into());

        let trove2_owner = ShrineUtils::trove2_owner_addr();
        shrine.deposit(yang1_addr, ShrineUtils::TROVE_2, TROVE2_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, ShrineUtils::TROVE_2, TROVE2_YANG2_DEPOSIT.into());
        shrine.forge(trove2_owner, ShrineUtils::TROVE_2, TROVE2_FORGE_AMT.into());

        let trove3_owner = ShrineUtils::trove3_owner_addr();
        shrine.deposit(yang1_addr, ShrineUtils::TROVE_3, TROVE3_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, ShrineUtils::TROVE_3, TROVE3_YANG2_DEPOSIT.into());
        shrine.forge(trove3_owner, ShrineUtils::TROVE_3, TROVE3_FORGE_AMT.into());

        shrine
    }

    //
    // Tests
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_one_redistribution() {
        let shrine: IShrineDispatcher = redistribution_setup();

        let trove1_owner = ShrineUtils::trove1_owner_addr();

        let (_, _, trove1_value, trove1_debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        let (_, _, _, before_trove2_debt) = shrine.get_trove_info(ShrineUtils::TROVE_2);

        let yang_addrs: Span<ContractAddress> = ShrineUtils::yang_addrs();
        let mut yang_addrs_copy = yang_addrs;

        let expected_remaining_yang1 = (TROVE2_YANG1_DEPOSIT + TROVE3_YANG1_DEPOSIT).into();
        let expected_remaining_yang2 = (TROVE2_YANG2_DEPOSIT + TROVE3_YANG2_DEPOSIT).into();
        let mut expected_remaining_yangs: Array<Wad> = Default::default();
        expected_remaining_yangs.append(expected_remaining_yang1);
        expected_remaining_yangs.append(expected_remaining_yang2);
        let mut expected_remaining_yangs = expected_remaining_yangs.span();

        let mut trove2_yang_deposits: Array<Wad> = Default::default();
        trove2_yang_deposits.append(TROVE2_YANG1_DEPOSIT.into());
        trove2_yang_deposits.append(TROVE2_YANG2_DEPOSIT.into());
        let mut trove2_yang_deposits = trove2_yang_deposits.span();

        let mut trove1_yang_values: Array<Wad> = Default::default();
        loop {
            match yang_addrs_copy.pop_front() {
                Option::Some(yang) => {

                    let deposited = shrine.get_deposit(*yang, ShrineUtils::TROVE_1);
                    let (yang_price, _, _) = shrine.get_current_yang_price(*yang);

                    trove1_yang_values.append(yang_price * deposited);
                },
                Option::None(_) => {
                    break;
                }
            };
        };
        let mut trove1_yang_values = trove1_yang_values.span();

        let (yang2_price, _, _) = shrine.get_current_yang_price(ShrineUtils::yang2_addr());

        // Simulate purge with 0 yin to update the trove's debt
        set_contract_address(ShrineUtils::admin());
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

                    let expected_yang_debt = (*trove1_yang_values.pop_front().unwrap() / trove1_value) * trove1_debt;
                    let expected_unit_debt = expected_yang_debt / *expected_remaining_yangs.pop_front().unwrap();

                    let unit_debt = shrine.get_redistributed_unit_debt_for_yang(*yang, expected_redistribution_id);
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

        // Skip to 2nd redistribution
        // Simulate purge with 0 yin to update the trove's debt
        set_contract_address(ShrineUtils::admin());
        shrine.melt(ShrineUtils::trove1_owner_addr(), ShrineUtils::TROVE_1, WadZeroable::zero());
        shrine.redistribute(ShrineUtils::TROVE_1);

        let trove2_owner = ShrineUtils::trove2_owner_addr();

        let (_, _, trove2_value, trove2_debt) = shrine.get_trove_info(ShrineUtils::TROVE_2);
        let (_, _, _, before_trove3_debt) = shrine.get_trove_info(ShrineUtils::TROVE_2);

        let yang_addrs: Span<ContractAddress> = ShrineUtils::yang_addrs();
        let mut yang_addrs_copy = yang_addrs;

        let mut trove2_yang_values: Array<Wad> = Default::default();
        loop {
            match yang_addrs_copy.pop_front() {
                Option::Some(yang) => {

                    let deposited = shrine.get_deposit(*yang, ShrineUtils::TROVE_2);
                    let (yang_price, _, _) = shrine.get_current_yang_price(*yang);

                    trove2_yang_values.append(yang_price * deposited);
                },
                Option::None(_) => {
                    break;
                }
            };
        };
        let mut trove2_yang_values = trove2_yang_values.span();

        let (yang2_price, _, _) = shrine.get_current_yang_price(ShrineUtils::yang2_addr());

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
        'before loop'.print();
        loop {
            match yang_addrs_copy.pop_front() {
                Option::Some(yang) => {
                    (*yang).print();
                    assert(shrine.get_deposit(*yang, ShrineUtils::TROVE_2) == WadZeroable::zero(), 'deposit should be 0');

                    let trove3_yang_deposit = *expected_remaining_yangs.pop_front().unwrap();

                    trove3_yang_deposit.val.print();
                    let remaining_yang = trove3_yang_deposit;

                    trove2_value.val.print();
                    trove2_debt.val.print();
                    let expected_yang_debt = (*trove2_yang_values.pop_front().unwrap() / trove2_value) * trove2_debt;

                    expected_yang_debt.val.print();
                    let expected_unit_debt = expected_yang_debt / remaining_yang;

                    let unit_debt = shrine.get_redistributed_unit_debt_for_yang(*yang, expected_redistribution_id);

                    expected_unit_debt.val.print();
                    unit_debt.val.print();
                    assert(unit_debt == expected_unit_debt, 'wrong unit debt');

                    expected_trove3_debt += trove3_yang_deposit * expected_unit_debt;
                },
                Option::None(_) => {
                    break;
                }
            };
        };
        
        'after loop'.print();
        let (_, _, _, after_trove3_debt) = shrine.get_trove_info(ShrineUtils::TROVE_2);

        assert(after_trove3_debt == expected_trove3_debt, 'wrong debt after redistribution');
        
        // Trigger an update in trove 3 with an empty melt
        shrine.melt(trove2_owner, ShrineUtils::TROVE_3, WadZeroable::zero());
        // TODO: checking equality with `expected_redistribution_id` causes `Unknown ap change` error
        assert(shrine.get_trove_redistribution_id(ShrineUtils::TROVE_3) == 2, 'wrong id');
    }

}
