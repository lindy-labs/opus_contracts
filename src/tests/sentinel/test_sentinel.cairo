mod test_sentinel {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::num::traits::Zero;
    use opus::constants::WBTC_DECIMALS;
    use opus::core::roles::sentinel_roles;
    use opus::core::sentinel::sentinel as sentinel_contract;
    use opus::interfaces::IERC20::IERC20DispatcherTrait;
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::ISentinel::ISentinelDispatcherTrait;
    use opus::interfaces::IShrine::IShrineDispatcherTrait;
    use opus::tests::common;
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::sentinel::utils::sentinel_utils::SentinelTestConfig;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::YangSuspensionStatus;
    use opus::utils::math::fixed_point_to_wad;
    use snforge_std::{
        CheatSpan, EventSpyAssertionsTrait, cheat_caller_address, spy_events, start_cheat_block_timestamp_global,
    };
    use starknet::ContractAddress;
    use wadray::{WAD_ONE, Wad};

    #[test]
    fn test_deploy_sentinel_and_add_yang() {
        let mut spy = spy_events();

        let SentinelTestConfig {
            sentinel, shrine, yangs, gates, ..,
        } = sentinel_utils::deploy_sentinel_with_gates(Option::None);

        // Checking that sentinel was set up correctly

        let eth_gate = *gates.at(0);
        let wbtc_gate = *gates.at(1);

        let eth = *yangs.at(0);
        let wbtc = *yangs.at(1);

        let eth_params = common::YANG1_PARAMS;
        let wbtc_params = common::YANG2_PARAMS;

        let wbtc_erc20 = common::erc20(wbtc);

        assert(sentinel.get_gate_address(*yangs.at(0)) == eth_gate.contract_address, 'Wrong gate address #1');
        assert(sentinel.get_gate_address(*yangs.at(1)) == wbtc_gate.contract_address, 'Wrong gate address #2');

        assert(sentinel.get_gate_live(*yangs.at(0)), 'Gate not live #1');
        assert(sentinel.get_gate_live(*yangs.at(1)), 'Gate not live #2');

        let given_yang_addresses = sentinel.get_yang_addresses();
        assert(
            *given_yang_addresses.at(0) == *yangs.at(0) && *given_yang_addresses.at(1) == *yangs.at(1),
            'Wrong yang addresses',
        );

        assert(sentinel.get_yang(0) == Zero::zero(), 'Should be zero address');
        assert(sentinel.get_yang(1) == *yangs.at(0), 'Wrong yang #1');
        assert(sentinel.get_yang(2) == *yangs.at(1), 'Wrong yang #2');

        assert(sentinel.get_yang_asset_max(eth) == sentinel_utils::ETH_ASSET_MAX, 'Wrong asset max #1');
        assert(sentinel.get_yang_asset_max(wbtc) == sentinel_utils::WBTC_ASSET_MAX, 'Wrong asset max #2');

        assert(sentinel.get_yang_addresses_count() == 2, 'Wrong yang addresses count');

        let sentinel_ac = IAccessControlDispatcher { contract_address: sentinel.contract_address };
        assert(sentinel_ac.get_admin() == common::SENTINEL_ADMIN, 'Wrong admin');
        assert(sentinel_ac.get_roles(common::SENTINEL_ADMIN) == sentinel_roles::ADMIN, 'Wrong roles for admin');

        // Checking that the gates were set up correctly

        assert((eth_gate).get_sentinel() == sentinel.contract_address, 'Wrong sentinel #1');
        assert((wbtc_gate).get_sentinel() == sentinel.contract_address, 'Wrong sentinel #2');

        // Checking that shrine was set up correctly

        let (eth_price, _, _) = shrine.get_current_yang_price(eth);
        let (wbtc_price, _, _) = shrine.get_current_yang_price(wbtc);

        assert(eth_price == eth_params.start_price.into(), 'Wrong yang price #1');
        assert(wbtc_price == wbtc_params.start_price.into(), 'Wrong yang price #2');

        let eth_threshold = shrine.get_yang_threshold(eth);
        assert(eth_threshold == eth_params.threshold.into(), 'Wrong yang threshold #1');

        let wbtc_threshold = shrine.get_yang_threshold(wbtc);
        assert(wbtc_threshold == wbtc_params.threshold.into(), 'Wrong yang threshold #2');

        let expected_era: u64 = 1;
        assert(shrine.get_yang_rate(eth, expected_era) == eth_params.base_rate.into(), 'Wrong yang rate #1');
        assert(shrine.get_yang_rate(wbtc, expected_era) == wbtc_params.base_rate.into(), 'Wrong yang rate #2');

        let expected_initial_eth_yang: Wad = sentinel_utils::get_initial_asset_amt(eth).into();
        assert(shrine.get_yang_total(eth) == expected_initial_eth_yang, 'Wrong yang total #1');

        let expected_initial_wbtc_yang: Wad = fixed_point_to_wad(
            sentinel_utils::get_initial_asset_amt(wbtc), wbtc_erc20.decimals(),
        );
        assert(shrine.get_yang_total(wbtc) == expected_initial_wbtc_yang, 'Wrong yang total #2');

        let expected_events = array![
            (
                sentinel.contract_address,
                sentinel_contract::Event::YangAdded(
                    sentinel_contract::YangAdded { yang: eth, gate: eth_gate.contract_address },
                ),
            ),
            (
                sentinel.contract_address,
                sentinel_contract::Event::YangAdded(
                    sentinel_contract::YangAdded { yang: wbtc, gate: wbtc_gate.contract_address },
                ),
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_add_yang_unauthorized() {
        let (sentinel, _) = sentinel_utils::deploy_sentinel(Option::None);
        let valid_params = common::YANG1_PARAMS;
        sentinel
            .add_yang(
                common::DUMMY_YANG_ADDR,
                sentinel_utils::ETH_ASSET_MAX,
                valid_params.threshold.into(),
                valid_params.start_price.into(),
                valid_params.base_rate.into(),
                common::DUMMY_YANG_GATE_ADDR,
            );
    }

    #[test]
    #[should_panic(expected: 'SE: Yang cannot be zero address')]
    fn test_add_yang_yang_zero_addr() {
        let (sentinel, _) = sentinel_utils::deploy_sentinel(Option::None);
        cheat_caller_address(sentinel.contract_address, common::SENTINEL_ADMIN, CheatSpan::TargetCalls(1));
        let valid_params = common::YANG1_PARAMS;
        sentinel
            .add_yang(
                Zero::zero(),
                sentinel_utils::ETH_ASSET_MAX,
                valid_params.threshold.into(),
                valid_params.start_price.into(),
                valid_params.base_rate.into(),
                common::DUMMY_YANG_GATE_ADDR,
            );
    }

    #[test]
    #[should_panic(expected: 'SE: Gate cannot be zero address')]
    fn test_add_yang_gate_zero_addr() {
        let (sentinel, _) = sentinel_utils::deploy_sentinel(Option::None);
        cheat_caller_address(sentinel.contract_address, common::SENTINEL_ADMIN, CheatSpan::TargetCalls(1));
        let valid_params = common::YANG1_PARAMS;
        sentinel
            .add_yang(
                common::DUMMY_YANG_ADDR,
                sentinel_utils::ETH_ASSET_MAX,
                valid_params.threshold.into(),
                valid_params.start_price.into(),
                valid_params.base_rate.into(),
                Zero::zero(),
            );
    }

    #[test]
    #[should_panic(expected: 'SE: Start price cannot be zero')]
    fn test_add_yang_zero_price() {
        let (sentinel, _) = sentinel_utils::deploy_sentinel(Option::None);
        cheat_caller_address(sentinel.contract_address, common::SENTINEL_ADMIN, CheatSpan::TargetCalls(1));
        let valid_params = common::YANG1_PARAMS;
        sentinel
            .add_yang(
                common::DUMMY_YANG_ADDR,
                sentinel_utils::ETH_ASSET_MAX,
                valid_params.threshold.into(),
                Zero::zero(),
                valid_params.base_rate.into(),
                common::DUMMY_YANG_GATE_ADDR,
            );
    }

    #[test]
    #[should_panic(expected: 'SE: Yang already added')]
    fn test_add_yang_yang_already_added() {
        let SentinelTestConfig {
            sentinel, yangs, gates, ..,
        } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let eth = *yangs[0];
        let eth_gate = *gates[0];

        cheat_caller_address(sentinel.contract_address, common::SENTINEL_ADMIN, CheatSpan::TargetCalls(1));
        let eth_params = common::YANG1_PARAMS;
        sentinel
            .add_yang(
                eth,
                sentinel_utils::ETH_ASSET_MAX,
                eth_params.threshold.into(),
                eth_params.start_price.into(),
                eth_params.base_rate.into(),
                eth_gate.contract_address,
            );
    }

    #[test]
    #[should_panic(expected: 'SE: Asset of gate is not yang')]
    fn test_add_yang_gate_yang_mismatch() {
        let classes = sentinel_utils::declare_contracts();
        let SentinelTestConfig {
            sentinel, gates, ..,
        } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::Some(classes));
        let eth_gate = *gates[0];
        let wbtc: ContractAddress = common::wbtc_token_deploy(classes.token);

        cheat_caller_address(sentinel.contract_address, common::SENTINEL_ADMIN, CheatSpan::TargetCalls(1));
        let wbtc_params = common::YANG2_PARAMS;
        sentinel
            .add_yang(
                wbtc,
                sentinel_utils::WBTC_ASSET_MAX,
                wbtc_params.threshold.into(),
                wbtc_params.start_price.into(),
                wbtc_params.base_rate.into(),
                eth_gate.contract_address,
            );
    }

    #[test]
    fn test_set_yang_asset_max() {
        let SentinelTestConfig { sentinel, yangs, .. } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let eth = *yangs[0];
        let mut spy = spy_events();

        let new_asset_max = sentinel_utils::ETH_ASSET_MAX * 2;

        // Test increasing the max
        cheat_caller_address(sentinel.contract_address, common::SENTINEL_ADMIN, CheatSpan::TargetCalls(1));
        sentinel.set_yang_asset_max(eth, new_asset_max);
        assert(sentinel.get_yang_asset_max(eth) == new_asset_max, 'Wrong asset max');

        // Test decreasing the max
        cheat_caller_address(sentinel.contract_address, common::SENTINEL_ADMIN, CheatSpan::TargetCalls(1));
        sentinel.set_yang_asset_max(eth, new_asset_max - 1);
        assert(sentinel.get_yang_asset_max(eth) == new_asset_max - 1, 'Wrong asset max');

        // Test decreasing the max to below the current yang total
        let initial_deposit_amt: u128 = sentinel_utils::get_initial_asset_amt(eth);
        cheat_caller_address(sentinel.contract_address, common::SENTINEL_ADMIN, CheatSpan::TargetCalls(1));
        sentinel.set_yang_asset_max(eth, initial_deposit_amt - 1);
        assert(sentinel.get_yang_asset_max(eth) == initial_deposit_amt - 1, 'Wrong asset max');

        let expected_events = array![
            (
                sentinel.contract_address,
                sentinel_contract::Event::YangAssetMaxUpdated(
                    sentinel_contract::YangAssetMaxUpdated {
                        yang: eth, old_max: sentinel_utils::ETH_ASSET_MAX, new_max: new_asset_max,
                    },
                ),
            ),
            (
                sentinel.contract_address,
                sentinel_contract::Event::YangAssetMaxUpdated(
                    sentinel_contract::YangAssetMaxUpdated {
                        yang: eth, old_max: new_asset_max, new_max: new_asset_max - 1,
                    },
                ),
            ),
            (
                sentinel.contract_address,
                sentinel_contract::Event::YangAssetMaxUpdated(
                    sentinel_contract::YangAssetMaxUpdated {
                        yang: eth, old_max: new_asset_max - 1, new_max: initial_deposit_amt - 1,
                    },
                ),
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: 'SE: Yang not added')]
    fn test_set_yang_asset_max_non_existent_yang() {
        let SentinelTestConfig { sentinel, .. } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);

        cheat_caller_address(sentinel.contract_address, common::SENTINEL_ADMIN, CheatSpan::TargetCalls(1));
        sentinel.set_yang_asset_max(common::DUMMY_YANG_ADDR, sentinel_utils::ETH_ASSET_MAX);
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_set_yang_asset_max_unauthed() {
        let SentinelTestConfig { sentinel, yangs, .. } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let eth = *yangs[0];
        cheat_caller_address(sentinel.contract_address, common::BAD_GUY, CheatSpan::TargetCalls(1));
        sentinel.set_yang_asset_max(eth, sentinel_utils::ETH_ASSET_MAX);
    }

    #[test]
    fn test_eth_enter_exit() {
        let SentinelTestConfig {
            sentinel, shrine, yangs, gates,
        } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let eth = *yangs[0];
        let eth_gate = *gates[0];

        let eth_erc20 = common::erc20(eth);
        let trove_id: u64 = common::TROVE_1;

        let user: ContractAddress = common::TROVE1_OWNER_ADDR;
        common::fund_user(user, yangs, common::LARGE_DEPOSITS.span());
        common::approve_gate_for_token(eth_gate, eth_erc20, user);

        let deposit_amt: Wad = (2 * WAD_ONE).into();
        let preview_yang_amt: Wad = sentinel.convert_to_yang(eth, deposit_amt.into());
        cheat_caller_address(sentinel.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        let yang_amt: Wad = sentinel.enter(eth, user, deposit_amt.into());
        cheat_caller_address(shrine.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        shrine.deposit(eth, trove_id, yang_amt);

        let expected_initial_eth_amt: u128 = sentinel_utils::get_initial_asset_amt(eth);

        assert(preview_yang_amt == yang_amt, 'Wrong preview enter yang amt');
        assert(yang_amt == deposit_amt, 'Wrong yang bal after enter');
        assert(
            eth_erc20.balance_of(eth_gate.contract_address) == expected_initial_eth_amt.into() + deposit_amt.into(),
            'Wrong eth bal after enter',
        );
        assert(shrine.get_deposit(eth, trove_id) == yang_amt, 'Wrong yang bal in shrine');

        let preview_eth_amt: u128 = sentinel.convert_to_assets(eth, WAD_ONE.into());
        cheat_caller_address(sentinel.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        let eth_amt: u128 = sentinel.exit(eth, user, WAD_ONE.into());
        cheat_caller_address(shrine.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        shrine.withdraw(eth, trove_id, WAD_ONE.into());

        assert(preview_eth_amt == eth_amt, 'Wrong preview exit eth amt');
        assert(eth_amt == WAD_ONE, 'Wrong yang bal after exit');
        assert(
            eth_erc20
                .balance_of(eth_gate.contract_address) == (expected_initial_eth_amt + deposit_amt.into() - WAD_ONE)
                .into(),
            'Wrong eth bal after exit',
        );
        assert(shrine.get_deposit(eth, trove_id) == yang_amt - WAD_ONE.into(), 'Wrong yang bal in shrine');
    }

    #[test]
    fn test_wbtc_enter_exit() {
        let SentinelTestConfig {
            sentinel, shrine, yangs, gates,
        } = sentinel_utils::deploy_sentinel_with_gates(Option::None);

        let wbtc: ContractAddress = *yangs[1];
        let wbtc_erc20 = common::erc20(wbtc);
        let wbtc_gate: IGateDispatcher = *gates[1];
        let trove_id: u64 = common::TROVE_1;

        let user: ContractAddress = common::TROVE1_OWNER_ADDR;
        common::fund_user(user, yangs, common::LARGE_DEPOSITS.span());
        common::approve_gate_for_token(wbtc_gate, wbtc_erc20, user);

        let initial_wbtc_amt: u128 = sentinel_utils::get_initial_asset_amt(wbtc);
        // Deposit a very small amount of WBTC
        let deposit_amt: u128 = 9_u128;

        let preview_yang_amt: Wad = sentinel.convert_to_yang(wbtc, deposit_amt);
        cheat_caller_address(sentinel.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        let yang_amt: Wad = sentinel.enter(wbtc, user, deposit_amt);
        cheat_caller_address(shrine.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        shrine.deposit(wbtc, trove_id, yang_amt);

        assert(preview_yang_amt == yang_amt, 'Wrong preview enter yang amt');
        assert(yang_amt == fixed_point_to_wad(deposit_amt, WBTC_DECIMALS), 'Wrong yang bal after enter');
        assert(
            wbtc_erc20.balance_of(wbtc_gate.contract_address) == (initial_wbtc_amt + deposit_amt).into(),
            'Wrong wbtc bal after enter',
        );
        assert(shrine.get_deposit(wbtc, trove_id) == yang_amt, 'Wrong yang bal in shrine');

        let preview_wbtc_amt: u128 = sentinel.convert_to_assets(wbtc, yang_amt);
        cheat_caller_address(sentinel.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        let wbtc_amt: u128 = sentinel.exit(wbtc, user, yang_amt);
        cheat_caller_address(shrine.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        shrine.withdraw(wbtc, trove_id, yang_amt);

        assert(preview_wbtc_amt == deposit_amt, 'Wrong preview exit WBTC amt');
        assert(wbtc_amt == deposit_amt, 'Wrong exit amt');
        assert(
            wbtc_erc20.balance_of(wbtc_gate.contract_address) == initial_wbtc_amt.into(), 'Wrong wbtc bal after exit',
        );
        assert(shrine.get_deposit(wbtc, trove_id).is_zero(), 'Wrong yang bal in shrine');
    }

    #[test]
    #[should_panic(expected: 'u256_sub Overflow')]
    fn test_enter_insufficient_balance() {
        let SentinelTestConfig { sentinel, yangs, .. } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let eth = *yangs[0];

        let eth_erc20 = common::erc20(eth);

        let deposit_amt: Wad = (2 * WAD_ONE).into();

        let user: ContractAddress = common::TROVE1_OWNER_ADDR;
        common::fund_user(user, yangs, common::LARGE_DEPOSITS.span());

        // Reduce user's balance to below the deposit amount
        cheat_caller_address(eth, user, CheatSpan::TargetCalls(1));
        eth_erc20.transfer(common::NON_ZERO_ADDR, eth_erc20.balance_of(user) - deposit_amt.into() - 1);

        cheat_caller_address(sentinel.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        sentinel.enter(eth, user, deposit_amt.into());
    }

    #[test]
    #[should_panic(expected: 'SE: Yang not added')]
    fn test_enter_yang_not_added() {
        let (sentinel, _) = sentinel_utils::deploy_sentinel(Option::None);

        let user: ContractAddress = common::NON_ZERO_ADDR;
        let deposit_amt: Wad = (2 * WAD_ONE).into();

        cheat_caller_address(sentinel.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        sentinel.enter(common::DUMMY_YANG_ADDR, user, deposit_amt.into());
    }

    #[test]
    #[should_panic(expected: 'SE: Exceeds max amount allowed')]
    fn test_enter_exceeds_max_deposit() {
        let SentinelTestConfig { sentinel, yangs, .. } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let eth = *yangs[0];

        let deposit_amt: Wad = (sentinel_utils::ETH_ASSET_MAX + 1).into(); // Deposit amount exceeds max deposit

        let user: ContractAddress = common::TROVE1_OWNER_ADDR;
        common::fund_user(user, yangs, common::LARGE_DEPOSITS.span());

        cheat_caller_address(sentinel.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        sentinel.enter(eth, user, deposit_amt.into());
    }

    #[test]
    #[should_panic(expected: 'SE: Yang not added')]
    fn test_exit_yang_not_added() {
        let (sentinel, _) = sentinel_utils::deploy_sentinel(Option::None);

        let user: ContractAddress = common::NON_ZERO_ADDR;

        cheat_caller_address(sentinel.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        sentinel.exit(common::DUMMY_YANG_ADDR, user, WAD_ONE.into());
    }

    #[test]
    #[should_panic(expected: 'u256_sub Overflow')]
    fn test_exit_insufficient_balance() {
        let SentinelTestConfig { sentinel, yangs, .. } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let eth = *yangs[0];

        cheat_caller_address(sentinel.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        sentinel.exit(eth, common::NON_ZERO_ADDR, WAD_ONE.into()); // User does not have any yang to exit
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_enter_unauthorized() {
        let SentinelTestConfig { sentinel, yangs, .. } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let eth = *yangs[0];

        let deposit_amt: Wad = (2 * WAD_ONE).into();

        cheat_caller_address(sentinel.contract_address, common::BAD_GUY, CheatSpan::TargetCalls(1));
        sentinel.enter(eth, common::NON_ZERO_ADDR, deposit_amt.into());
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_exit_unauthorized() {
        let SentinelTestConfig { sentinel, yangs, .. } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let eth = *yangs[0];

        cheat_caller_address(sentinel.contract_address, common::BAD_GUY, CheatSpan::TargetCalls(1));
        sentinel.exit(eth, common::NON_ZERO_ADDR, WAD_ONE.into());
    }


    #[test]
    #[should_panic(expected: 'SE: Gate is not live')]
    fn test_kill_gate_and_enter() {
        let SentinelTestConfig { sentinel, yangs, .. } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let eth = *yangs[0];

        let deposit_amt: Wad = (2 * WAD_ONE).into();

        // Kill the gate
        cheat_caller_address(sentinel.contract_address, common::SENTINEL_ADMIN, CheatSpan::TargetCalls(1));
        sentinel.kill_gate(eth);

        assert(!sentinel.get_gate_live(eth), 'Gate should be killed');

        let user: ContractAddress = common::TROVE1_OWNER_ADDR;
        common::fund_user(user, yangs, common::LARGE_DEPOSITS.span());

        // Attempt to enter a killed gate should fail
        cheat_caller_address(sentinel.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        sentinel.enter(eth, user, deposit_amt.into());
    }

    #[test]
    fn test_kill_gate_and_exit() {
        let SentinelTestConfig {
            sentinel, shrine, yangs, gates,
        } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let eth = *yangs[0];
        let eth_gate = *gates[0];

        // Making a regular deposit
        let trove_id: u64 = common::TROVE_1;

        let user: ContractAddress = common::TROVE1_OWNER_ADDR;
        common::fund_user(user, yangs, common::LARGE_DEPOSITS.span());
        common::approve_gate_for_token(eth_gate, common::erc20(eth), user);

        let deposit_amt: Wad = (2 * WAD_ONE).into();

        cheat_caller_address(sentinel.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        let yang_amt: Wad = sentinel.enter(eth, user, deposit_amt.into());
        cheat_caller_address(shrine.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        shrine.deposit(eth, trove_id, yang_amt);

        // Killing the gate
        cheat_caller_address(sentinel.contract_address, common::SENTINEL_ADMIN, CheatSpan::TargetCalls(1));
        sentinel.kill_gate(eth);

        // Exiting
        cheat_caller_address(sentinel.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        sentinel.exit(eth, user, yang_amt);
    }

    #[test]
    #[should_panic(expected: 'SE: Gate is not live')]
    fn test_kill_gate_and_preview_enter() {
        let SentinelTestConfig { sentinel, yangs, .. } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let eth = *yangs[0];

        let deposit_amt: Wad = (2 * WAD_ONE).into();

        // Kill the gate
        cheat_caller_address(sentinel.contract_address, common::SENTINEL_ADMIN, CheatSpan::TargetCalls(1));
        sentinel.kill_gate(eth);

        // Attempt to enter a killed gate should fail
        cheat_caller_address(sentinel.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        sentinel.convert_to_yang(eth, deposit_amt.into());
    }

    #[test]
    fn test_suspend_unsuspend_yang() {
        let SentinelTestConfig {
            sentinel, shrine, yangs, ..,
        } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let eth = *yangs[0];
        start_cheat_block_timestamp_global(shrine_utils::DEPLOYMENT_TIMESTAMP);

        let status = shrine.get_yang_suspension_status(eth);
        assert(status == YangSuspensionStatus::None, 'status 1');

        cheat_caller_address(sentinel.contract_address, common::SENTINEL_ADMIN, CheatSpan::TargetCalls(1));
        sentinel.suspend_yang(eth);
        let status = shrine.get_yang_suspension_status(eth);
        assert(status == YangSuspensionStatus::Temporary, 'status 2');

        // move time forward by 1 day
        start_cheat_block_timestamp_global(shrine_utils::DEPLOYMENT_TIMESTAMP + 86400);

        cheat_caller_address(sentinel.contract_address, common::SENTINEL_ADMIN, CheatSpan::TargetCalls(1));
        sentinel.unsuspend_yang(eth);
        let status = shrine.get_yang_suspension_status(eth);
        assert(status == YangSuspensionStatus::None, 'status 3');
    }

    #[test]
    #[should_panic(expected: 'SE: Yang suspended')]
    fn test_try_enter_when_yang_suspended() {
        let SentinelTestConfig { sentinel, yangs, .. } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let eth = *yangs[0];
        cheat_caller_address(sentinel.contract_address, common::SENTINEL_ADMIN, CheatSpan::TargetCalls(1));
        sentinel.suspend_yang(eth);

        let deposit_amt: Wad = (2 * WAD_ONE).into();

        cheat_caller_address(sentinel.contract_address, common::MOCK_ABBOT, CheatSpan::TargetCalls(1));
        sentinel.enter(eth, common::NON_ZERO_ADDR, deposit_amt.into());
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_try_suspending_yang_unauthorized() {
        let SentinelTestConfig { sentinel, yangs, .. } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let eth = *yangs[0];
        cheat_caller_address(sentinel.contract_address, common::BAD_GUY, CheatSpan::TargetCalls(1));
        sentinel.suspend_yang(eth);
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_try_unsuspending_yang_unauthorized() {
        let SentinelTestConfig { sentinel, yangs, .. } = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let eth = *yangs[0];
        cheat_caller_address(sentinel.contract_address, common::BAD_GUY, CheatSpan::TargetCalls(1));
        sentinel.unsuspend_yang(eth);
    }
}
