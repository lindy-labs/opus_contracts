mod test_abbot {
    use core::num::traits::Zero;
    use opus::core::abbot::abbot as abbot_contract;
    use opus::interfaces::IAbbot::IAbbotDispatcherTrait;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IGate::IGateDispatcher;
    use opus::interfaces::ISentinel::ISentinelDispatcherTrait;
    use opus::interfaces::IShrine::IShrineDispatcherTrait;
    use opus::tests::abbot::utils::abbot_utils;
    use opus::tests::abbot::utils::abbot_utils::{AbbotTestConfig, AbbotTestTrove};
    use opus::tests::common;
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::{AssetBalance, Health, YangBalance};
    use opus::utils::math::fixed_point_to_wad;
    use snforge_std::{EventSpyAssertionsTrait, spy_events, start_cheat_caller_address, stop_cheat_caller_address};
    use starknet::ContractAddress;
    use wadray::{WAD_SCALE, Wad};

    //
    // Tests
    //

    #[test]
    fn test_open_trove_pass() {
        let AbbotTestConfig { shrine, abbot, yangs, gates, .. } = abbot_utils::abbot_deploy(Option::None);

        let mut spy = spy_events();
        let mut expected_events = ArrayTrait::new();

        // Deploying the first trove
        let trove_owner: ContractAddress = common::TROVE1_OWNER_ADDR;
        let forge_amt: Wad = abbot_utils::OPEN_TROVE_FORGE_AMT.into();
        common::fund_user(trove_owner, yangs, abbot_utils::initial_asset_amts());
        let deposited_amts: Span<u128> = abbot_utils::open_trove_yang_asset_amts();
        let trove_id: u64 = common::open_trove_helper(abbot, trove_owner, yangs, deposited_amts, gates, forge_amt);

        // Check trove ID
        let expected_trove_id: u64 = 1;
        assert(trove_id == expected_trove_id, 'wrong trove ID');
        assert(
            abbot.get_trove_owner(expected_trove_id).expect('should not be zero') == trove_owner, 'wrong trove owner',
        );
        assert(abbot.get_troves_count() == expected_trove_id, 'wrong troves count');

        let mut expected_user_trove_ids: Array<u64> = array![expected_trove_id];
        assert(abbot.get_user_trove_ids(trove_owner) == expected_user_trove_ids.span(), 'wrong user trove ids');

        let mut yangs_total: Array<Wad> = ArrayTrait::new();
        // Check yangs
        let mut deposited_amts_copy = deposited_amts;
        for yang in yangs {
            let decimals: u8 = IERC20Dispatcher { contract_address: *yang }.decimals();
            let asset_amt: u128 = *deposited_amts_copy.pop_front().unwrap();
            let expected_initial_yang: Wad = fixed_point_to_wad(sentinel_utils::get_initial_asset_amt(*yang), decimals);
            let expected_deposited_yang: Wad = fixed_point_to_wad(asset_amt, decimals);
            let expected_yang_total: Wad = expected_initial_yang + expected_deposited_yang;
            assert(shrine.get_yang_total(*yang) == expected_yang_total, 'wrong yang total #1');
            yangs_total.append(expected_yang_total);

            assert(shrine.get_deposit(*yang, trove_id) == expected_deposited_yang, 'wrong trove yang balance #1');

            expected_events
                .append(
                    (
                        abbot.contract_address,
                        abbot_contract::Event::Deposit(
                            abbot_contract::Deposit {
                                user: trove_owner, trove_id, yang: *yang, yang_amt: expected_deposited_yang, asset_amt,
                            },
                        ),
                    ),
                );
        }

        // Check trove's debt
        let trove_health: Health = shrine.get_trove_health(expected_trove_id);
        assert(trove_health.debt == forge_amt, 'wrong trove debt');

        let shrine_health: Health = shrine.get_shrine_health();
        assert(shrine_health.debt == forge_amt, 'wrong total debt');

        // User opens another trove
        let second_forge_amt: Wad = 1666000000000000000000_u128.into();
        let mut second_deposit_amts = abbot_utils::subsequent_deposit_amts();
        let second_trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner, yangs, second_deposit_amts, gates, second_forge_amt,
        );

        let expected_trove_id: u64 = 2;
        assert(second_trove_id == expected_trove_id, 'wrong trove ID');
        assert(
            abbot.get_trove_owner(expected_trove_id).expect('should not be zero') == trove_owner, 'wrong trove owner',
        );
        assert(abbot.get_troves_count() == expected_trove_id, 'wrong troves count');

        expected_user_trove_ids.append(expected_trove_id);
        assert(abbot.get_user_trove_ids(trove_owner) == expected_user_trove_ids.span(), 'wrong user trove ids');

        // Check yangs
        let mut yangs_total = yangs_total.span();
        for yang in yangs {
            let decimals: u8 = IERC20Dispatcher { contract_address: *yang }.decimals();
            let asset_amt: u128 = *second_deposit_amts.pop_front().unwrap();
            let before_yang_total: Wad = *yangs_total.pop_front().unwrap();
            let expected_deposited_yang: Wad = fixed_point_to_wad(asset_amt, decimals);
            let expected_yang_total: Wad = before_yang_total + expected_deposited_yang;
            assert(shrine.get_yang_total(*yang) == expected_yang_total, 'wrong yang total #2');

            assert(
                shrine.get_deposit(*yang, second_trove_id) == expected_deposited_yang, 'wrong trove yang balance #2',
            );

            expected_events
                .append(
                    (
                        abbot.contract_address,
                        abbot_contract::Event::Deposit(
                            abbot_contract::Deposit {
                                user: trove_owner,
                                trove_id: second_trove_id,
                                yang: *yang,
                                yang_amt: expected_deposited_yang,
                                asset_amt,
                            },
                        ),
                    ),
                );
        }

        let shrine_health: Health = shrine.get_shrine_health();
        assert(shrine_health.debt == forge_amt + second_forge_amt, 'wrong total debt #2');

        expected_events
            .append(
                (
                    abbot.contract_address,
                    abbot_contract::Event::TroveOpened(
                        abbot_contract::TroveOpened { user: trove_owner, trove_id: trove_id },
                    ),
                ),
            );
        expected_events
            .append(
                (
                    abbot.contract_address,
                    abbot_contract::Event::TroveOpened(
                        abbot_contract::TroveOpened { user: trove_owner, trove_id: second_trove_id },
                    ),
                ),
            );
        spy.assert_emitted(@expected_events);

        shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
    }

    #[test]
    #[should_panic(expected: 'ABB: No debt forged')]
    fn test_open_trove_zero_forge_amt_fail() {
        let AbbotTestConfig { abbot, yangs, gates, .. } = abbot_utils::abbot_deploy(Option::None);

        let trove_owner: ContractAddress = common::TROVE1_OWNER_ADDR;
        let forge_amt = Zero::zero();
        common::fund_user(trove_owner, yangs, abbot_utils::initial_asset_amts());
        let deposited_amts: Span<u128> = abbot_utils::open_trove_yang_asset_amts();
        common::open_trove_helper(abbot, trove_owner, yangs, deposited_amts, gates, forge_amt);
    }

    #[test]
    #[should_panic(expected: 'ABB: No yangs')]
    fn test_open_trove_no_yangs_fail() {
        let AbbotTestConfig { abbot, .. } = abbot_utils::abbot_deploy(Option::None);
        let trove_owner: ContractAddress = common::TROVE1_OWNER_ADDR;

        let yangs: Array<ContractAddress> = ArrayTrait::new();
        let yang_amts: Array<u128> = ArrayTrait::new();
        let forge_amt: Wad = 1_u128.into();
        let max_forge_fee_pct: Wad = Zero::zero();

        start_cheat_caller_address(abbot.contract_address, trove_owner);
        let yang_assets: Span<AssetBalance> = common::combine_assets_and_amts(yangs.span(), yang_amts.span());
        abbot.open_trove(yang_assets, forge_amt, max_forge_fee_pct);
    }

    #[test]
    #[should_panic(expected: 'SE: Yang not added')]
    fn test_open_trove_invalid_yang_fail() {
        let AbbotTestConfig { abbot, .. } = abbot_utils::abbot_deploy(Option::None);

        let invalid_yang: ContractAddress = sentinel_utils::DUMMY_YANG_ADDR;
        let mut yangs: Array<ContractAddress> = array![invalid_yang];
        let mut yang_amts: Array<u128> = array![WAD_SCALE];
        let forge_amt: Wad = 1_u128.into();
        let max_forge_fee_pct: Wad = Zero::zero();

        let yang_assets: Span<AssetBalance> = common::combine_assets_and_amts(yangs.span(), yang_amts.span());
        abbot.open_trove(yang_assets, forge_amt, max_forge_fee_pct);
    }

    #[test]
    fn test_close_trove_pass() {
        let (AbbotTestConfig { shrine, abbot, yangs, .. }, AbbotTestTrove { trove_owner, trove_id, .. }) =
            abbot_utils::deploy_abbot_and_open_trove(
            Option::None,
        );

        let mut spy = spy_events();
        let mut expected_events = ArrayTrait::new();

        let mut before_trove_owner_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, array![trove_owner].span(),
        );
        let mut trove_yang_deposits: Span<YangBalance> = shrine.get_trove_deposits(trove_id);

        start_cheat_caller_address(abbot.contract_address, trove_owner);
        abbot.close_trove(trove_id);

        let mut after_trove_owner_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, array![trove_owner].span(),
        );

        for yang in yangs {
            assert(shrine.get_deposit(*yang, trove_id).is_zero(), 'wrong yang amount');

            let mut after_trove_owner_asset_bal_arr: Span<u128> = *after_trove_owner_asset_bals.pop_front().unwrap();
            let after_trove_owner_asset_bal: u128 = *after_trove_owner_asset_bal_arr.pop_front().unwrap();

            let mut before_trove_owner_asset_bal_arr: Span<u128> = *before_trove_owner_asset_bals.pop_front().unwrap();
            let before_trove_owner_asset_bal: u128 = *before_trove_owner_asset_bal_arr.pop_front().unwrap();

            expected_events
                .append(
                    (
                        abbot.contract_address,
                        abbot_contract::Event::Withdraw(
                            abbot_contract::Withdraw {
                                user: trove_owner,
                                trove_id,
                                yang: *yang,
                                yang_amt: (*trove_yang_deposits.pop_front().unwrap()).amount,
                                asset_amt: after_trove_owner_asset_bal - before_trove_owner_asset_bal,
                            },
                        ),
                    ),
                );
        }

        let trove_health: Health = shrine.get_trove_health(trove_id);
        assert(trove_health.debt.is_zero(), 'wrong trove debt');

        expected_events
            .append(
                (abbot.contract_address, abbot_contract::Event::TroveClosed(abbot_contract::TroveClosed { trove_id })),
            );
        spy.assert_emitted(@expected_events);

        shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
    }

    #[test]
    #[should_panic(expected: 'ABB: Not trove owner')]
    fn test_close_non_owner_fail() {
        let (AbbotTestConfig { abbot, .. }, AbbotTestTrove { trove_id, .. }) = abbot_utils::deploy_abbot_and_open_trove(
            Option::None,
        );

        start_cheat_caller_address(abbot.contract_address, common::BAD_GUY);
        abbot.close_trove(trove_id);
    }

    #[test]
    fn test_deposit_pass() {
        let (
            AbbotTestConfig { shrine, abbot, yangs, .. }, AbbotTestTrove { trove_owner, trove_id, yang_asset_amts, .. },
        ) =
            abbot_utils::deploy_abbot_and_open_trove(
            Option::None,
        );

        let mut spy = spy_events();
        let mut expected_events = ArrayTrait::new();

        start_cheat_caller_address(abbot.contract_address, trove_owner);
        let mut deposited_amts_copy = yang_asset_amts;
        for yang in yangs {
            let before_trove_yang: Wad = shrine.get_deposit(*yang, trove_id);
            let decimals: u8 = IERC20Dispatcher { contract_address: *yang }.decimals();
            let deposit_amt: u128 = *deposited_amts_copy.pop_front().unwrap();
            let expected_deposited_yang: Wad = fixed_point_to_wad(deposit_amt, decimals);
            abbot.deposit(trove_id, AssetBalance { address: *yang, amount: deposit_amt });
            let after_trove_yang: Wad = shrine.get_deposit(*yang, trove_id);
            assert(after_trove_yang == before_trove_yang + expected_deposited_yang, 'wrong yang amount #1');

            expected_events
                .append(
                    (
                        abbot.contract_address,
                        abbot_contract::Event::Deposit(
                            abbot_contract::Deposit {
                                user: trove_owner,
                                trove_id: trove_id,
                                yang: *yang,
                                yang_amt: expected_deposited_yang,
                                asset_amt: deposit_amt,
                            },
                        ),
                    ),
                );

            // Depositing 0 should pass
            abbot.deposit(trove_id, AssetBalance { address: *yang, amount: 0_u128 });
            assert(shrine.get_deposit(*yang, trove_id) == after_trove_yang, 'wrong yang amount #2');
        }

        shrine_utils::assert_total_yang_invariant(shrine, yangs, abbot.get_troves_count());

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: 'SE: Yang not added')]
    fn test_deposit_zero_address_yang_fail() {
        let (AbbotTestConfig { abbot, .. }, AbbotTestTrove { trove_owner, trove_id, .. }) =
            abbot_utils::deploy_abbot_and_open_trove(
            Option::None,
        );

        let asset_addr = Zero::zero();
        let amount: u128 = 1;

        start_cheat_caller_address(abbot.contract_address, trove_owner);
        abbot.deposit(trove_id, AssetBalance { address: asset_addr, amount });
    }

    #[test]
    #[should_panic(expected: 'ABB: Not trove owner')]
    fn test_deposit_zero_trove_id_fail() {
        let AbbotTestConfig { abbot, yangs, .. } = abbot_utils::abbot_deploy(Option::None);
        let trove_owner: ContractAddress = common::TROVE1_OWNER_ADDR;

        let asset_addr = *yangs.at(0);
        let invalid_trove_id: u64 = 0;
        let amount: u128 = 1;

        start_cheat_caller_address(abbot.contract_address, trove_owner);
        abbot.deposit(invalid_trove_id, AssetBalance { address: asset_addr, amount });
    }

    #[test]
    #[should_panic(expected: 'ABB: Not trove owner')]
    fn test_deposit_not_trove_owner_fail() {
        let (AbbotTestConfig { abbot, yangs, .. }, AbbotTestTrove { trove_id, .. }) =
            abbot_utils::deploy_abbot_and_open_trove(
            Option::None,
        );

        let asset_addr = *yangs.at(0);
        let amount: u128 = 1;

        start_cheat_caller_address(abbot.contract_address, common::BAD_GUY);
        abbot.deposit(trove_id, AssetBalance { address: asset_addr, amount });
    }

    #[test]
    #[should_panic(expected: 'SE: Yang not added')]
    fn test_deposit_invalid_yang_fail() {
        let (AbbotTestConfig { abbot, .. }, AbbotTestTrove { trove_owner, trove_id, .. }) =
            abbot_utils::deploy_abbot_and_open_trove(
            Option::None,
        );

        start_cheat_caller_address(abbot.contract_address, trove_owner);

        let asset_addr = sentinel_utils::DUMMY_YANG_ADDR;
        let amount: u128 = 0;

        abbot.deposit(trove_id, AssetBalance { address: asset_addr, amount });
    }

    #[test]
    #[should_panic(expected: 'SE: Exceeds max amount allowed')]
    fn test_deposit_exceeds_asset_cap_fail() {
        let (AbbotTestConfig { sentinel, abbot, yangs, gates, .. }, AbbotTestTrove { trove_owner, trove_id, .. }) =
            abbot_utils::deploy_abbot_and_open_trove(
            Option::None,
        );

        let asset_addr: ContractAddress = *yangs.at(0);
        let gate_addr: ContractAddress = *gates.at(0).contract_address;
        let gate_bal = IERC20Dispatcher { contract_address: asset_addr }.balance_of(gate_addr);

        start_cheat_caller_address(sentinel.contract_address, sentinel_utils::ADMIN);
        let new_asset_max: u128 = gate_bal.try_into().unwrap();
        sentinel.set_yang_asset_max(asset_addr, new_asset_max);
        stop_cheat_caller_address(sentinel.contract_address);

        let amount: u128 = 1;
        start_cheat_caller_address(abbot.contract_address, trove_owner);
        abbot.deposit(trove_id, AssetBalance { address: asset_addr, amount });
    }

    #[test]
    fn test_withdraw_pass() {
        let (AbbotTestConfig { shrine, abbot, yangs, .. }, AbbotTestTrove { trove_owner, trove_id, .. }) =
            abbot_utils::deploy_abbot_and_open_trove(
            Option::None,
        );

        let mut spy = spy_events();

        let asset_addr: ContractAddress = *yangs.at(0);
        let amount: u128 = WAD_SCALE;
        start_cheat_caller_address(abbot.contract_address, trove_owner);
        abbot.withdraw(trove_id, AssetBalance { address: asset_addr, amount });

        let expected_events = array![
            (
                abbot.contract_address,
                abbot_contract::Event::Withdraw(
                    abbot_contract::Withdraw {
                        user: trove_owner, trove_id, yang: asset_addr, yang_amt: amount.into(), asset_amt: amount,
                    },
                ),
            ),
        ];

        assert(
            shrine.get_deposit(asset_addr, trove_id) == (abbot_utils::ETH_DEPOSIT_AMT - amount).into(),
            'wrong yang amount',
        );

        shrine_utils::assert_total_yang_invariant(shrine, yangs, abbot.get_troves_count());

        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_deposit_maximum_asset_and_withdraw_pass() {
        let AbbotTestConfig { shrine, sentinel, abbot, yangs, gates } = abbot_utils::abbot_deploy(Option::None);

        let eth: ContractAddress = *yangs[0];
        let eth_gate: IGateDispatcher = *gates[0];
        let eth_erc20: IERC20Dispatcher = IERC20Dispatcher { contract_address: eth };
        let eth_gate_balance: u128 = eth_erc20.balance_of(eth_gate.contract_address).try_into().unwrap();

        let wbtc: ContractAddress = *yangs[1];
        let wbtc_gate: IGateDispatcher = *gates[1];
        let wbtc_erc20: IERC20Dispatcher = IERC20Dispatcher { contract_address: wbtc };
        let wbtc_gate_balance: u128 = wbtc_erc20.balance_of(wbtc_gate.contract_address).try_into().unwrap();

        // Open a trove with maximum asset amount deposited for ETH and WBTC
        let trove_owner: ContractAddress = common::TROVE1_OWNER_ADDR;

        let deposit_eth_amt: u128 = sentinel_utils::ETH_ASSET_MAX - eth_gate_balance;
        let deposit_wbtc_amt: u128 = sentinel_utils::WBTC_ASSET_MAX - wbtc_gate_balance;
        let deposit_amts: Span<u128> = array![deposit_eth_amt, deposit_wbtc_amt].span();

        common::fund_user(trove_owner, yangs, deposit_amts);
        let forge_amt = 1_u128.into();
        let trove_id: u64 = common::open_trove_helper(abbot, trove_owner, yangs, deposit_amts, gates, forge_amt);

        // Sanity check that max assets have been deposited
        assert_eq!(
            eth_erc20.balance_of(eth_gate.contract_address).try_into().unwrap(),
            sentinel.get_yang_asset_max(eth),
            "yang not at max #1",
        );
        assert_eq!(
            wbtc_erc20.balance_of(wbtc_gate.contract_address).try_into().unwrap(),
            sentinel.get_yang_asset_max(wbtc),
            "yang not at max #2",
        );

        // Withdraw all ETH and WBTC
        start_cheat_caller_address(abbot.contract_address, trove_owner);
        abbot.melt(trove_id, forge_amt);
        abbot.withdraw(trove_id, AssetBalance { address: eth, amount: deposit_eth_amt });
        abbot.withdraw(trove_id, AssetBalance { address: wbtc, amount: deposit_wbtc_amt });

        assert(shrine.get_deposit(eth, trove_id).is_zero(), 'wrong yang amount #1');
        assert(shrine.get_deposit(wbtc, trove_id).is_zero(), 'wrong yang amount #2');

        shrine_utils::assert_total_yang_invariant(shrine, yangs, abbot.get_troves_count());
    }

    #[test]
    fn test_withdraw_suspended_yang_pass() {
        let AbbotTestConfig { shrine, sentinel, abbot, yangs, gates } = abbot_utils::abbot_deploy(Option::None);

        let eth: ContractAddress = *yangs[0];
        let eth_deposit_amt: u128 = abbot_utils::ETH_DEPOSIT_AMT;

        let trove_owner: ContractAddress = common::TROVE1_OWNER_ADDR;

        let deposit_yangs: Span<ContractAddress> = array![*yangs[0]].span();
        let deposit_amts: Span<u128> = array![eth_deposit_amt].span();

        common::fund_user(trove_owner, deposit_yangs, deposit_amts);
        let forge_amt = 1_u128.into();
        let trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner, deposit_yangs, deposit_amts, array![*gates[0]].span(), forge_amt,
        );

        start_cheat_caller_address(abbot.contract_address, trove_owner);
        abbot.melt(trove_id, forge_amt);
        stop_cheat_caller_address(abbot.contract_address);

        start_cheat_caller_address(sentinel.contract_address, sentinel_utils::ADMIN);
        sentinel.suspend_yang(eth);
        stop_cheat_caller_address(sentinel.contract_address);

        start_cheat_caller_address(abbot.contract_address, trove_owner);
        abbot.withdraw(trove_id, AssetBalance { address: eth, amount: eth_deposit_amt });

        assert(shrine.get_deposit(eth, trove_id).is_zero(), 'wrong yang amount');
    }

    #[test]
    #[should_panic(expected: 'SE: Yang not added')]
    fn test_withdraw_zero_address_yang_fail() {
        let (AbbotTestConfig { abbot, .. }, AbbotTestTrove { trove_owner, trove_id, .. }) =
            abbot_utils::deploy_abbot_and_open_trove(
            Option::None,
        );

        let asset_addr = Zero::zero();
        let amount: u128 = 1;

        start_cheat_caller_address(abbot.contract_address, trove_owner);
        abbot.withdraw(trove_id, AssetBalance { address: asset_addr, amount });
    }

    #[test]
    #[should_panic(expected: 'SE: Yang not added')]
    fn test_withdraw_invalid_yang_fail() {
        let (AbbotTestConfig { abbot, .. }, AbbotTestTrove { trove_owner, trove_id, .. }) =
            abbot_utils::deploy_abbot_and_open_trove(
            Option::None,
        );

        start_cheat_caller_address(abbot.contract_address, trove_owner);

        let asset_addr = sentinel_utils::DUMMY_YANG_ADDR;
        let amount: u128 = 0;

        abbot.withdraw(trove_id, AssetBalance { address: asset_addr, amount });
    }

    #[test]
    #[should_panic(expected: 'ABB: Not trove owner')]
    fn test_withdraw_non_owner_fail() {
        let (AbbotTestConfig { abbot, yangs, .. }, AbbotTestTrove { trove_id, .. }) =
            abbot_utils::deploy_abbot_and_open_trove(
            Option::None,
        );

        start_cheat_caller_address(abbot.contract_address, common::BAD_GUY);

        let asset_addr: ContractAddress = *yangs.at(0);
        let amount: u128 = 0;

        abbot.withdraw(trove_id, AssetBalance { address: asset_addr, amount });
    }

    #[test]
    fn test_forge_pass() {
        let (AbbotTestConfig { shrine, abbot, yangs, .. }, AbbotTestTrove { trove_owner, trove_id, forge_amt, .. }) =
            abbot_utils::deploy_abbot_and_open_trove(
            Option::None,
        );

        let additional_forge_amt: Wad = abbot_utils::OPEN_TROVE_FORGE_AMT.into();
        start_cheat_caller_address(abbot.contract_address, trove_owner);
        abbot.forge(trove_id, additional_forge_amt, Zero::zero());

        let after_trove_health: Health = shrine.get_trove_health(trove_id);
        assert(after_trove_health.debt == forge_amt + additional_forge_amt, 'wrong trove debt');
        assert(shrine.get_yin(trove_owner) == forge_amt + additional_forge_amt, 'wrong yin balance');

        shrine_utils::assert_total_troves_debt_invariant(shrine, yangs, abbot.get_troves_count());
    }

    #[test]
    #[should_panic(expected: 'SH: Trove LTV > threshold')]
    fn test_forge_ltv_unsafe_fail() {
        let (AbbotTestConfig { shrine, abbot, yangs, gates, .. }, AbbotTestTrove { trove_owner, trove_id, .. }) =
            abbot_utils::deploy_abbot_and_open_trove(
            Option::None,
        );

        // deploy another trove to prevent recovery mode
        common::open_trove_helper(
            abbot, common::TROVE1_OWNER_ADDR, yangs, abbot_utils::open_trove_yang_asset_amts(), gates, 1_u128.into(),
        );

        assert(!shrine.is_recovery_mode(), 'recovery mode');

        let unsafe_forge_amt: Wad = shrine.get_max_forge(trove_id) + 2_u128.into();
        start_cheat_caller_address(abbot.contract_address, trove_owner);
        abbot.forge(trove_id, unsafe_forge_amt, Zero::zero());
    }

    #[test]
    #[should_panic(expected: 'ABB: Not trove owner')]
    fn test_forge_non_owner_fail() {
        let (AbbotTestConfig { abbot, .. }, AbbotTestTrove { trove_id, .. }) = abbot_utils::deploy_abbot_and_open_trove(
            Option::None,
        );

        start_cheat_caller_address(abbot.contract_address, common::BAD_GUY);
        abbot.forge(trove_id, Zero::zero(), Zero::zero());
    }

    #[test]
    fn test_melt_pass() {
        let (
            AbbotTestConfig {
                shrine, abbot, yangs, gates, ..,
                }, AbbotTestTrove {
                trove_owner, trove_id, forge_amt, ..,
            },
        ) =
            abbot_utils::deploy_abbot_and_open_trove(
            Option::None,
        );

        let before_trove_health: Health = shrine.get_trove_health(trove_id);
        let before_yin: Wad = shrine.get_yin(trove_owner);

        let melt_amt: u128 = before_yin.into() / 2;
        let melt_amt: Wad = melt_amt.into();
        start_cheat_caller_address(abbot.contract_address, trove_owner);
        abbot.melt(trove_id, melt_amt);

        let after_trove_health: Health = shrine.get_trove_health(trove_id);
        assert(after_trove_health.debt == before_trove_health.debt - melt_amt, 'wrong trove debt');
        assert(shrine.get_yin(trove_owner) == before_yin - melt_amt, 'wrong yin balance');

        // Test non-owner melting
        let non_owner: ContractAddress = common::TROVE2_OWNER_ADDR;
        common::fund_user(non_owner, yangs, abbot_utils::initial_asset_amts());
        let non_owner_forge_amt = forge_amt;
        common::open_trove_helper(
            abbot, non_owner, yangs, abbot_utils::open_trove_yang_asset_amts(), gates, non_owner_forge_amt,
        );

        start_cheat_caller_address(abbot.contract_address, non_owner);
        abbot.melt(trove_id, after_trove_health.debt);

        let final_trove_health: Health = shrine.get_trove_health(trove_id);
        assert(final_trove_health.debt.is_zero(), 'wrong trove debt');

        shrine_utils::assert_total_troves_debt_invariant(shrine, yangs, abbot.get_troves_count());
    }

    #[test]
    fn test_get_user_trove_ids() {
        let AbbotTestConfig { abbot, yangs, gates, .. } = abbot_utils::abbot_deploy(Option::None);
        let trove_owner1: ContractAddress = common::TROVE1_OWNER_ADDR;
        let trove_owner2: ContractAddress = common::TROVE2_OWNER_ADDR;

        let forge_amt: Wad = abbot_utils::OPEN_TROVE_FORGE_AMT.into();
        common::fund_user(trove_owner1, yangs, abbot_utils::initial_asset_amts());
        common::fund_user(trove_owner2, yangs, abbot_utils::initial_asset_amts());

        let first_trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner1, yangs, abbot_utils::open_trove_yang_asset_amts(), gates, forge_amt,
        );
        let second_trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner2, yangs, abbot_utils::open_trove_yang_asset_amts(), gates, forge_amt,
        );
        let third_trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner1, yangs, abbot_utils::open_trove_yang_asset_amts(), gates, forge_amt,
        );
        let fourth_trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner2, yangs, abbot_utils::open_trove_yang_asset_amts(), gates, forge_amt,
        );

        let mut expected_owner1_trove_ids: Array<u64> = array![first_trove_id, third_trove_id];
        let mut expected_owner2_trove_ids: Array<u64> = array![second_trove_id, fourth_trove_id];
        let empty_user_trove_ids: Span<u64> = ArrayTrait::new().span();

        assert(abbot.get_user_trove_ids(trove_owner1) == expected_owner1_trove_ids.span(), 'wrong user trove IDs');
        assert(abbot.get_user_trove_ids(trove_owner2) == expected_owner2_trove_ids.span(), 'wrong user trove IDs');
        assert(abbot.get_troves_count() == 4, 'wrong troves count');

        let non_user: ContractAddress = common::TROVE3_OWNER_ADDR;
        assert(abbot.get_user_trove_ids(non_user) == empty_user_trove_ids, 'wrong non user trove IDs');
    }
}
