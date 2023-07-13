#[cfg(test)]
mod TestAbbot {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::{ContractAddress, contract_address_const};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;
    use traits::{Default, Into, TryInto};

    use aura::core::sentinel::Sentinel;

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{Wad, WadZeroable, WAD_SCALE};

    use aura::tests::abbot::utils::AbbotUtils;
    use aura::tests::sentinel::utils::SentinelUtils;
    use aura::tests::shrine::utils::ShrineUtils;
    use aura::tests::common;

    use debug::PrintTrait;

    //
    // Tests
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_open_trove_pass() {
        let (
            shrine, _, abbot, mut yangs, gates, trove_owner, trove_id, mut deposited_amts, forge_amt
        ) =
            AbbotUtils::deploy_abbot_and_open_trove();
        let trove_owner: ContractAddress = common::trove1_owner_addr();

        // Check trove ID
        let expected_trove_id: u64 = 1;
        assert(trove_id == expected_trove_id, 'wrong trove ID');
        assert(abbot.get_trove_owner(expected_trove_id) == trove_owner, 'wrong trove owner');
        assert(abbot.get_troves_count() == expected_trove_id, 'wrong troves count');

        let mut expected_user_trove_ids: Array<u64> = Default::default();
        expected_user_trove_ids.append(expected_trove_id);
        assert(
            abbot.get_user_trove_ids(trove_owner) == expected_user_trove_ids.span(),
            'wrong user trove ids'
        );

        let mut yangs_total: Array<Wad> = Default::default();
        // Check yangs
        let mut yangs_copy = yangs;
        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => {
                    let decimals: u8 = IERC20Dispatcher { contract_address: *yang }.decimals();
                    let expected_initial_yang: Wad = wadray::fixed_point_to_wad(
                        Sentinel::INITIAL_DEPOSIT_AMT, decimals
                    );
                    let expected_deposited_yang: Wad = wadray::fixed_point_to_wad(
                        *deposited_amts.pop_front().unwrap(), decimals
                    );
                    let expected_yang_total: Wad = expected_initial_yang + expected_deposited_yang;
                    assert(
                        shrine.get_yang_total(*yang) == expected_yang_total, 'wrong yang total #1'
                    );
                    yangs_total.append(expected_yang_total);

                    assert(
                        shrine.get_deposit(*yang, trove_id) == expected_deposited_yang,
                        'wrong trove yang balance #1'
                    );
                },
                Option::None(_) => {
                    break;
                },
            };
        };

        // Check trove's debt
        // TODO: calling `shrine.get_trove_info()` results in `Unknown ap change` error
        //let (_, _, _, debt) = shrine.get_trove_info(expected_trove_id);
        //assert(debt == forge_amt, 'wrong trove debt');

        assert(shrine.get_total_debt() == forge_amt, 'wrong total debt');

        // User opens another trove
        let second_forge_amt: Wad = 1666000000000000000000_u128.into();
        let mut second_deposit_amts = AbbotUtils::subsequent_deposit_amts();
        let second_trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner, yangs, second_deposit_amts, gates, second_forge_amt
        );

        let expected_trove_id: u64 = 2;
        assert(second_trove_id == expected_trove_id, 'wrong trove ID');
        assert(abbot.get_trove_owner(expected_trove_id) == trove_owner, 'wrong trove owner');
        assert(abbot.get_troves_count() == expected_trove_id, 'wrong troves count');

        expected_user_trove_ids.append(expected_trove_id);
        assert(
            abbot.get_user_trove_ids(trove_owner) == expected_user_trove_ids.span(),
            'wrong user trove ids'
        );

        // Check yangs
        let mut yangs_total = yangs_total.span();
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let decimals: u8 = IERC20Dispatcher { contract_address: *yang }.decimals();
                    let before_yang_total: Wad = *yangs_total.pop_front().unwrap();
                    let expected_deposited_yang: Wad = wadray::fixed_point_to_wad(
                        *second_deposit_amts.pop_front().unwrap(), decimals
                    );
                    let expected_yang_total: Wad = before_yang_total + expected_deposited_yang;
                    assert(
                        shrine.get_yang_total(*yang) == expected_yang_total, 'wrong yang total #2'
                    );

                    assert(
                        shrine.get_deposit(*yang, second_trove_id) == expected_deposited_yang,
                        'wrong trove yang balance #2'
                    );
                },
                Option::None(_) => {
                    break;
                },
            };
        };

        assert(shrine.get_total_debt() == forge_amt + second_forge_amt, 'wrong total debt #2');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: No yangs', 'ENTRYPOINT_FAILED'))]
    fn test_open_trove_no_yangs_fail() {
        let (_, _, abbot, _, _) = AbbotUtils::abbot_deploy();
        let trove_owner: ContractAddress = common::trove1_owner_addr();

        let yangs: Array<ContractAddress> = Default::default();
        let yang_amts: Array<u128> = Default::default();
        let forge_amt: Wad = 1_u128.into();
        let max_forge_fee_pct: Wad = WadZeroable::zero();

        set_contract_address(trove_owner);
        abbot.open_trove(forge_amt, yangs.span(), yang_amts.span(), max_forge_fee_pct);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Array lengths mismatch', 'ENTRYPOINT_FAILED'))]
    fn test_open_trove_input_args_mismatch_fail() {
        let (_, _, abbot, yangs, _) = AbbotUtils::abbot_deploy();
        let trove_owner: ContractAddress = common::trove1_owner_addr();

        let yang_amts: Array<u128> = Default::default();
        let forge_amt: Wad = 1_u128.into();
        let max_forge_fee_pct: Wad = WadZeroable::zero();

        set_contract_address(trove_owner);
        abbot.open_trove(forge_amt, yangs, yang_amts.span(), max_forge_fee_pct);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SE: Yang not added', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED'))]
    fn test_open_trove_invalid_yang_fail() {
        let (_, _, abbot, _, _) = AbbotUtils::abbot_deploy();

        let invalid_yang: ContractAddress = contract_address_const::<0xdead>();
        let mut yangs: Array<ContractAddress> = Default::default();
        yangs.append(invalid_yang);
        let mut yang_amts: Array<u128> = Default::default();
        yang_amts.append(WAD_SCALE);
        let forge_amt: Wad = 1_u128.into();
        let max_forge_fee_pct: Wad = WadZeroable::zero();

        abbot.open_trove(forge_amt, yangs.span(), yang_amts.span(), max_forge_fee_pct);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_close_trove_pass() {
        let (shrine, _, abbot, mut yangs, _, trove_owner, trove_id, _, _) =
            AbbotUtils::deploy_abbot_and_open_trove();

        set_contract_address(trove_owner);
        abbot.close_trove(trove_id);

        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    assert(
                        shrine.get_deposit(*yang, trove_id) == WadZeroable::zero(),
                        'wrong yang amount'
                    );
                },
                Option::None(_) => {
                    break;
                },
            };
        };

        let (_, _, _, debt) = shrine.get_trove_info(trove_id);
        assert(debt == WadZeroable::zero(), 'wrong trove debt');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Not trove owner', 'ENTRYPOINT_FAILED'))]
    fn test_close_non_owner_fail() {
        let (_, _, abbot, _, _, _, trove_id, _, _) = AbbotUtils::deploy_abbot_and_open_trove();

        set_contract_address(common::badguy());
        abbot.close_trove(trove_id);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_deposit_pass() {
        let (shrine, _, abbot, mut yangs, mut gates, trove_owner, trove_id, mut deposited_amts, _) =
            AbbotUtils::deploy_abbot_and_open_trove();

        set_contract_address(trove_owner);
        let mut yangs_copy = yangs;
        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => {
                    let before_trove_yang: Wad = shrine.get_deposit(*yang, trove_id);
                    let decimals: u8 = IERC20Dispatcher { contract_address: *yang }.decimals();
                    let deposit_amt: u128 = *deposited_amts.pop_front().unwrap();
                    let expected_deposited_yang: Wad = wadray::fixed_point_to_wad(
                        deposit_amt, decimals
                    );
                    abbot.deposit(*yang, trove_id, deposit_amt);
                    let after_trove_yang: Wad = shrine.get_deposit(*yang, trove_id);
                    assert(
                        after_trove_yang == before_trove_yang + expected_deposited_yang,
                        'wrong yang amount #1'
                    );

                    // Depositing 0 should pass
                    abbot.deposit(*yang, trove_id, 0_u128);
                    assert(
                        shrine.get_deposit(*yang, trove_id) == after_trove_yang,
                        'wrong yang amount #2'
                    );
                },
                Option::None(_) => {
                    break;
                },
            };
        };

        // Check that non-owner can deposit to trove
        let non_owner: ContractAddress = common::trove2_owner_addr();
        let mut non_owner_deposit_amts: Span<u128> = AbbotUtils::subsequent_deposit_amts();
        common::fund_user(non_owner, yangs, AbbotUtils::initial_asset_amts());

        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    SentinelUtils::approve_max(*gates.pop_front().unwrap(), *yang, non_owner);

                    let before_trove_yang: Wad = shrine.get_deposit(*yang, trove_id);
                    let decimals: u8 = IERC20Dispatcher { contract_address: *yang }.decimals();
                    let deposit_amt: u128 = *non_owner_deposit_amts.pop_front().unwrap();
                    let expected_deposited_yang: Wad = wadray::fixed_point_to_wad(
                        deposit_amt, decimals
                    );

                    set_contract_address(non_owner);
                    abbot.deposit(*yang, trove_id, deposit_amt);
                    let after_trove_yang: Wad = shrine.get_deposit(*yang, trove_id);
                    assert(
                        after_trove_yang == before_trove_yang + expected_deposited_yang,
                        'wrong yang amount #3'
                    );
                },
                Option::None(_) => {
                    break;
                },
            };
        };
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SE: Yang not added', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_zero_address_yang_fail() {
        let (_, _, abbot, _, _, trove_owner, trove_id, _, _) =
            AbbotUtils::deploy_abbot_and_open_trove();

        let invalid_yang_addr = ContractAddressZeroable::zero();
        let trove_id: u64 = common::TROVE_1;
        let amount: u128 = 1;

        set_contract_address(trove_owner);
        abbot.deposit(invalid_yang_addr, trove_id, amount);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Trove ID cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_zero_trove_id_fail() {
        let (_, _, abbot, yangs, _) = AbbotUtils::abbot_deploy();
        let trove_owner: ContractAddress = common::trove1_owner_addr();

        let yang_addr = *yangs.at(0);
        let invalid_trove_id: u64 = 0;
        let amount: u128 = 1;

        set_contract_address(trove_owner);
        abbot.deposit(yang_addr, invalid_trove_id, amount);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SE: Yang not added', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_invalid_yang_fail() {
        let (_, _, abbot, _, _, trove_owner, trove_id, _, _) =
            AbbotUtils::deploy_abbot_and_open_trove();

        let invalid_yang_addr = contract_address_const::<0x0101>();
        set_contract_address(trove_owner);
        abbot.deposit(invalid_yang_addr, trove_id, 0_u128);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Non-existent trove', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_non_existent_trove_fail() {
        let (_, _, abbot, yangs, _, trove_owner, trove_id, _, _) =
            AbbotUtils::deploy_abbot_and_open_trove();

        let eth_addr: ContractAddress = *yangs.at(0);
        set_contract_address(trove_owner);
        abbot.deposit(eth_addr, trove_id + 1, 1_u128);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(
        expected: ('SE: Exceeds max amount allowed', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED')
    )]
    fn test_deposit_exceeds_asset_cap_fail() {
        let (_, sentinel, abbot, yangs, gates, trove_owner, trove_id, _, _) =
            AbbotUtils::deploy_abbot_and_open_trove();

        let eth_addr: ContractAddress = *yangs.at(0);
        let eth_gate_addr: ContractAddress = *gates.at(0).contract_address;
        let eth_gate_bal = IERC20Dispatcher {
            contract_address: eth_addr
        }.balance_of(eth_gate_addr);

        set_contract_address(SentinelUtils::admin());
        let new_eth_asset_max: u128 = eth_gate_bal.try_into().unwrap();
        sentinel.set_yang_asset_max(eth_addr, new_eth_asset_max);

        set_contract_address(trove_owner);
        abbot.deposit(eth_addr, trove_id, 1_u128);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_withdraw_pass() {
        let (shrine, _, abbot, yangs, _, trove_owner, trove_id, _, _) =
            AbbotUtils::deploy_abbot_and_open_trove();

        let eth_addr: ContractAddress = *yangs.at(0);
        let eth_withdraw_amt: Wad = WAD_SCALE.into();
        set_contract_address(trove_owner);
        abbot.withdraw(eth_addr, trove_id, eth_withdraw_amt);

        assert(
            shrine.get_deposit(eth_addr, trove_id) == AbbotUtils::ETH_DEPOSIT_AMT.into()
                - eth_withdraw_amt,
            'wrong yang amount'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SE: Yang not added', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED'))]
    fn test_withdraw_zero_address_yang_fail() {
        let (_, _, abbot, _, _, trove_owner, trove_id, _, _) =
            AbbotUtils::deploy_abbot_and_open_trove();

        let invalid_yang_addr = ContractAddressZeroable::zero();
        let trove_id: u64 = common::TROVE_1;
        let amount: Wad = 1_u128.into();

        set_contract_address(trove_owner);
        abbot.withdraw(invalid_yang_addr, trove_id, amount);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SE: Yang not added', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED'))]
    fn test_withdraw_invalid_yang_fail() {
        let (_, _, abbot, _, _, trove_owner, trove_id, _, _) =
            AbbotUtils::deploy_abbot_and_open_trove();

        let invalid_yang_addr = contract_address_const::<0x0101>();
        set_contract_address(trove_owner);
        abbot.withdraw(invalid_yang_addr, trove_id, 0_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Not trove owner', 'ENTRYPOINT_FAILED'))]
    fn test_withdraw_non_owner_fail() {
        let (_, _, abbot, yangs, _, trove_owner, trove_id, _, _) =
            AbbotUtils::deploy_abbot_and_open_trove();

        let eth_addr: ContractAddress = *yangs.at(0);
        set_contract_address(common::badguy());
        abbot.withdraw(eth_addr, trove_id, 0_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_forge_pass() {
        let (shrine, _, abbot, _, _, trove_owner, trove_id, _, forge_amt) =
            AbbotUtils::deploy_abbot_and_open_trove();

        let additional_forge_amt: Wad = AbbotUtils::OPEN_TROVE_FORGE_AMT.into();
        set_contract_address(trove_owner);
        abbot.forge(trove_id, additional_forge_amt, WadZeroable::zero());

        let (_, _, _, after_trove_debt) = shrine.get_trove_info(trove_id);
        assert(after_trove_debt == forge_amt + additional_forge_amt, 'wrong trove debt');
        assert(
            shrine.get_yin(trove_owner) == forge_amt + additional_forge_amt, 'wrong yin balance'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(
        expected: ('SH: Trove LTV is too high', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED')
    )]
    fn test_forge_ltv_unsafe_fail() {
        let (shrine, _, abbot, _, _, trove_owner, trove_id, _, _) =
            AbbotUtils::deploy_abbot_and_open_trove();

        let unsafe_forge_amt: Wad = shrine.get_max_forge(trove_id) + 2_u128.into();
        set_contract_address(trove_owner);
        abbot.forge(trove_id, unsafe_forge_amt, WadZeroable::zero());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Not trove owner', 'ENTRYPOINT_FAILED'))]
    fn test_forge_non_owner_fail() {
        let (_, _, abbot, _, _, _, trove_id, _, _) = AbbotUtils::deploy_abbot_and_open_trove();

        set_contract_address(common::badguy());
        abbot.forge(trove_id, 0_u128.into(), WadZeroable::zero());
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_melt_pass() {
        let (shrine, _, abbot, yangs, gates, trove_owner, trove_id, _, start_forge_amt) =
            AbbotUtils::deploy_abbot_and_open_trove();

        let (_, _, _, before_trove_debt) = shrine.get_trove_info(trove_id);
        let before_yin: Wad = shrine.get_yin(trove_owner);

        let melt_amt: Wad = (before_yin.val / 2).into();
        set_contract_address(trove_owner);
        abbot.melt(trove_id, melt_amt);

        let (_, _, _, after_trove_debt) = shrine.get_trove_info(trove_id);
        assert(after_trove_debt == before_trove_debt - melt_amt, 'wrong trove debt');
        assert(shrine.get_yin(trove_owner) == before_yin - melt_amt, 'wrong yin balance');

        // Test non-owner melting
        let non_owner: ContractAddress = common::trove2_owner_addr();
        common::fund_user(non_owner, yangs, AbbotUtils::initial_asset_amts());
        let non_owner_forge_amt = start_forge_amt;
        common::open_trove_helper(
            abbot,
            non_owner,
            yangs,
            AbbotUtils::open_trove_yang_asset_amts(),
            gates,
            non_owner_forge_amt
        );

        set_contract_address(non_owner);
        abbot.melt(trove_id, after_trove_debt);

        let (_, _, _, final_trove_debt) = shrine.get_trove_info(trove_id);
        assert(final_trove_debt == WadZeroable::zero(), 'wrong trove debt');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_get_user_trove_ids() {
        let (_, _, abbot, yangs, gates) = AbbotUtils::abbot_deploy();
        let trove_owner1: ContractAddress = common::trove1_owner_addr();
        let trove_owner2: ContractAddress = common::trove2_owner_addr();

        let forge_amt: Wad = AbbotUtils::OPEN_TROVE_FORGE_AMT.into();
        common::fund_user(trove_owner1, yangs, AbbotUtils::initial_asset_amts());
        common::fund_user(trove_owner2, yangs, AbbotUtils::initial_asset_amts());

        let first_trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner1, yangs, AbbotUtils::open_trove_yang_asset_amts(), gates, forge_amt
        );
        let second_trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner2, yangs, AbbotUtils::open_trove_yang_asset_amts(), gates, forge_amt
        );
        let third_trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner1, yangs, AbbotUtils::open_trove_yang_asset_amts(), gates, forge_amt
        );
        let fourth_trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner2, yangs, AbbotUtils::open_trove_yang_asset_amts(), gates, forge_amt
        );

        let mut expected_owner1_trove_ids: Array<u64> = Default::default();
        let mut expected_owner2_trove_ids: Array<u64> = Default::default();

        let empty_user_trove_ids: Span<u64> = expected_owner1_trove_ids.span();

        expected_owner1_trove_ids.append(first_trove_id);
        expected_owner1_trove_ids.append(third_trove_id);

        expected_owner2_trove_ids.append(second_trove_id);
        expected_owner2_trove_ids.append(fourth_trove_id);

        assert(
            abbot.get_user_trove_ids(trove_owner1) == expected_owner1_trove_ids.span(),
            'wrong user trove IDs'
        );
        assert(
            abbot.get_user_trove_ids(trove_owner2) == expected_owner2_trove_ids.span(),
            'wrong user trove IDs'
        );
        assert(abbot.get_troves_count() == 4, 'wrong troves count');

        let non_user: ContractAddress = common::trove3_owner_addr();
        assert(
            abbot.get_user_trove_ids(non_user) == empty_user_trove_ids, 'wrong non user trove IDs'
        );
    }
}
