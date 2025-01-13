mod test_sentinel {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::num::traits::Zero;
    use opus::core::roles::sentinel_roles;
    use opus::core::sentinel::sentinel as sentinel_contract;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::YangSuspensionStatus;
    use opus::utils::math::{fixed_point_to_wad, pow};
    use snforge_std::{
        declare, ContractClass, start_prank, start_warp, CheatTarget, spy_events, SpyOn, EventSpy, EventAssertions,
    };
    use starknet::ContractAddress;
    use wadray::{Ray, Wad, WAD_ONE};

    #[test]
    fn test_deploy_sentinel_and_add_yang() {
        let mut spy = spy_events(SpyOn::All);

        let (sentinel, shrine, assets, gates) = sentinel_utils::deploy_sentinel_with_gates(Option::None);

        // Checking that sentinel was set up correctly

        let eth_gate = *gates.at(0);
        let wbtc_gate = *gates.at(1);

        let eth = *assets.at(0);
        let wbtc = *assets.at(1);

        let wbtc_erc20 = IERC20Dispatcher { contract_address: wbtc };

        assert(sentinel.get_gate_address(*assets.at(0)) == eth_gate.contract_address, 'Wrong gate address #1');
        assert(sentinel.get_gate_address(*assets.at(1)) == wbtc_gate.contract_address, 'Wrong gate address #2');

        assert(sentinel.get_gate_live(*assets.at(0)), 'Gate not live #1');
        assert(sentinel.get_gate_live(*assets.at(1)), 'Gate not live #2');

        let given_yang_addresses = sentinel.get_yang_addresses();
        assert(
            *given_yang_addresses.at(0) == *assets.at(0) && *given_yang_addresses.at(1) == *assets.at(1),
            'Wrong yang addresses'
        );

        assert(sentinel.get_yang(0) == Zero::zero(), 'Should be zero address');
        assert(sentinel.get_yang(1) == *assets.at(0), 'Wrong yang #1');
        assert(sentinel.get_yang(2) == *assets.at(1), 'Wrong yang #2');

        assert(sentinel.get_yang_asset_max(eth) == sentinel_utils::ETH_ASSET_MAX, 'Wrong asset max #1');
        assert(sentinel.get_yang_asset_max(wbtc) == sentinel_utils::WBTC_ASSET_MAX, 'Wrong asset max #2');

        assert(sentinel.get_yang_addresses_count() == 2, 'Wrong yang addresses count');

        let sentinel_ac = IAccessControlDispatcher { contract_address: sentinel.contract_address };
        assert(sentinel_ac.get_admin() == sentinel_utils::admin(), 'Wrong admin');
        assert(
            sentinel_ac.get_roles(sentinel_utils::admin()) == sentinel_roles::default_admin_role(),
            'Wrong roles for admin'
        );

        // Checking that the gates were set up correctly

        assert((eth_gate).get_sentinel() == sentinel.contract_address, 'Wrong sentinel #1');
        assert((wbtc_gate).get_sentinel() == sentinel.contract_address, 'Wrong sentinel #2');

        // Checking that shrine was set up correctly

        let (eth_price, _, _) = shrine.get_current_yang_price(eth);
        let (wbtc_price, _, _) = shrine.get_current_yang_price(wbtc);

        assert(eth_price == shrine_utils::YANG1_START_PRICE.into(), 'Wrong yang price #1');
        assert(wbtc_price == shrine_utils::YANG2_START_PRICE.into(), 'Wrong yang price #2');

        let eth_threshold = shrine.get_yang_threshold(eth);
        assert(eth_threshold == shrine_utils::YANG1_THRESHOLD.into(), 'Wrong yang threshold #1');

        let wbtc_threshold = shrine.get_yang_threshold(wbtc);
        assert(wbtc_threshold == shrine_utils::YANG2_THRESHOLD.into(), 'Wrong yang threshold #2');

        let expected_era: u64 = 1;
        assert(shrine.get_yang_rate(eth, expected_era) == shrine_utils::YANG1_BASE_RATE.into(), 'Wrong yang rate #1');
        assert(shrine.get_yang_rate(wbtc, expected_era) == shrine_utils::YANG2_BASE_RATE.into(), 'Wrong yang rate #2');

        let expected_initial_eth_yang: Wad = sentinel_utils::get_initial_asset_amt(eth).into();
        assert_eq!(shrine.get_yang_total(eth), expected_initial_eth_yang, "Wrong yang total #1");

        let expected_initial_wbtc_yang: Wad = fixed_point_to_wad(
            sentinel_utils::get_initial_asset_amt(wbtc), wbtc_erc20.decimals()
        );
        assert_eq!(shrine.get_yang_total(wbtc), expected_initial_wbtc_yang, "Wrong yang total #2");

        let expected_events = array![
            (
                sentinel.contract_address,
                sentinel_contract::Event::YangAdded(
                    sentinel_contract::YangAdded { yang: eth, gate: eth_gate.contract_address, }
                )
            ),
            (
                sentinel.contract_address,
                sentinel_contract::Event::YangAdded(
                    sentinel_contract::YangAdded { yang: wbtc, gate: wbtc_gate.contract_address, }
                )
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_add_yang_unauthorized() {
        let (sentinel, _) = sentinel_utils::deploy_sentinel(Option::None);

        sentinel
            .add_yang(
                sentinel_utils::dummy_yang_addr(),
                sentinel_utils::ETH_ASSET_MAX,
                shrine_utils::YANG1_THRESHOLD.into(),
                shrine_utils::YANG1_START_PRICE.into(),
                shrine_utils::YANG1_BASE_RATE.into(),
                sentinel_utils::dummy_yang_gate_addr()
            );
    }

    #[test]
    #[should_panic(expected: ('SE: Yang cannot be zero address',))]
    fn test_add_yang_yang_zero_addr() {
        let (sentinel, _) = sentinel_utils::deploy_sentinel(Option::None);
        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::admin());
        sentinel
            .add_yang(
                Zero::zero(),
                sentinel_utils::ETH_ASSET_MAX,
                shrine_utils::YANG1_THRESHOLD.into(),
                shrine_utils::YANG1_START_PRICE.into(),
                shrine_utils::YANG1_BASE_RATE.into(),
                sentinel_utils::dummy_yang_gate_addr()
            );
    }

    #[test]
    #[should_panic(expected: ('SE: Gate cannot be zero address',))]
    fn test_add_yang_gate_zero_addr() {
        let (sentinel, _) = sentinel_utils::deploy_sentinel(Option::None);
        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::admin());
        sentinel
            .add_yang(
                sentinel_utils::dummy_yang_addr(),
                sentinel_utils::ETH_ASSET_MAX,
                shrine_utils::YANG1_THRESHOLD.into(),
                shrine_utils::YANG1_START_PRICE.into(),
                shrine_utils::YANG1_BASE_RATE.into(),
                Zero::zero()
            );
    }

    #[test]
    #[should_panic(expected: ('SE: Start price cannot be zero',))]
    fn test_add_yang_zero_price() {
        let (sentinel, _) = sentinel_utils::deploy_sentinel(Option::None);
        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::admin());
        sentinel
            .add_yang(
                sentinel_utils::dummy_yang_addr(),
                sentinel_utils::ETH_ASSET_MAX,
                shrine_utils::YANG1_THRESHOLD.into(),
                Zero::zero(),
                shrine_utils::YANG1_BASE_RATE.into(),
                sentinel_utils::dummy_yang_gate_addr()
            );
    }

    #[test]
    #[should_panic(expected: ('SE: Yang already added',))]
    fn test_add_yang_yang_already_added() {
        let (sentinel, _, eth, eth_gate) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);

        start_prank(CheatTarget::All, sentinel_utils::admin());
        sentinel
            .add_yang(
                eth,
                sentinel_utils::ETH_ASSET_MAX,
                shrine_utils::YANG1_THRESHOLD.into(),
                shrine_utils::YANG1_START_PRICE.into(),
                shrine_utils::YANG1_BASE_RATE.into(),
                eth_gate.contract_address
            );
    }

    #[test]
    #[should_panic(expected: ('SE: Asset of gate is not yang',))]
    fn test_add_yang_gate_yang_mismatch() {
        let classes = sentinel_utils::declare_contracts();
        let (sentinel, _, _, eth_gate) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::Some(classes));
        let wbtc: ContractAddress = common::wbtc_token_deploy(classes.token);

        start_prank(CheatTarget::All, sentinel_utils::admin());
        sentinel
            .add_yang(
                wbtc,
                sentinel_utils::WBTC_ASSET_MAX,
                shrine_utils::YANG2_THRESHOLD.into(),
                shrine_utils::YANG2_START_PRICE.into(),
                shrine_utils::YANG2_BASE_RATE.into(),
                eth_gate.contract_address
            );
    }

    #[test]
    fn test_set_yang_asset_max() {
        let (sentinel, _, eth, _) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let mut spy = spy_events(SpyOn::One(sentinel.contract_address));

        let new_asset_max = sentinel_utils::ETH_ASSET_MAX * 2;

        start_prank(CheatTarget::All, sentinel_utils::admin());

        // Test increasing the max
        sentinel.set_yang_asset_max(eth, new_asset_max);
        assert(sentinel.get_yang_asset_max(eth) == new_asset_max, 'Wrong asset max');

        // Test decreasing the max
        sentinel.set_yang_asset_max(eth, new_asset_max - 1);
        assert(sentinel.get_yang_asset_max(eth) == new_asset_max - 1, 'Wrong asset max');

        // Test decreasing the max to below the current yang total
        let initial_deposit_amt: u128 = sentinel_utils::get_initial_asset_amt(eth);
        sentinel.set_yang_asset_max(eth, initial_deposit_amt - 1);
        assert(sentinel.get_yang_asset_max(eth) == initial_deposit_amt - 1, 'Wrong asset max');

        let expected_events = array![
            (
                sentinel.contract_address,
                sentinel_contract::Event::YangAssetMaxUpdated(
                    sentinel_contract::YangAssetMaxUpdated {
                        yang: eth, old_max: sentinel_utils::ETH_ASSET_MAX, new_max: new_asset_max,
                    }
                )
            ),
            (
                sentinel.contract_address,
                sentinel_contract::Event::YangAssetMaxUpdated(
                    sentinel_contract::YangAssetMaxUpdated {
                        yang: eth, old_max: new_asset_max, new_max: new_asset_max - 1,
                    }
                )
            ),
            (
                sentinel.contract_address,
                sentinel_contract::Event::YangAssetMaxUpdated(
                    sentinel_contract::YangAssetMaxUpdated {
                        yang: eth, old_max: new_asset_max - 1, new_max: initial_deposit_amt - 1,
                    }
                )
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('SE: Yang not added',))]
    fn test_set_yang_asset_max_non_existent_yang() {
        let (sentinel, _, _, _) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);

        start_prank(CheatTarget::All, sentinel_utils::admin());
        sentinel.set_yang_asset_max(sentinel_utils::dummy_yang_addr(), sentinel_utils::ETH_ASSET_MAX);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_yang_asset_max_unauthed() {
        let (sentinel, _, eth, _) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        start_prank(CheatTarget::One(sentinel.contract_address), common::badguy());
        sentinel.set_yang_asset_max(eth, sentinel_utils::ETH_ASSET_MAX);
    }

    #[test]
    fn test_eth_enter_exit() {
        let (sentinel, shrine, eth, eth_gate) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);

        let eth_erc20 = IERC20Dispatcher { contract_address: eth };
        let user: ContractAddress = common::eth_hoarder();
        let trove_id: u64 = common::TROVE_1;

        sentinel_utils::approve_max(eth_gate, eth, user);

        let deposit_amt: Wad = (2 * WAD_ONE).into();

        start_prank(
            CheatTarget::Multiple(array![sentinel.contract_address, shrine.contract_address]),
            sentinel_utils::mock_abbot()
        );

        let preview_yang_amt: Wad = sentinel.convert_to_yang(eth, deposit_amt.val);
        let yang_amt: Wad = sentinel.enter(eth, user, deposit_amt.val);
        shrine.deposit(eth, trove_id, yang_amt);

        let expected_initial_eth_amt: u128 = sentinel_utils::get_initial_asset_amt(eth);

        assert(preview_yang_amt == yang_amt, 'Wrong preview enter yang amt');
        assert(yang_amt == deposit_amt, 'Wrong yang bal after enter');
        assert(
            eth_erc20.balance_of(eth_gate.contract_address) == (expected_initial_eth_amt + deposit_amt.val).into(),
            'Wrong eth bal after enter'
        );
        assert(shrine.get_deposit(eth, trove_id) == yang_amt, 'Wrong yang bal in shrine');

        let preview_eth_amt: u128 = sentinel.convert_to_assets(eth, WAD_ONE.into());
        let eth_amt: u128 = sentinel.exit(eth, user, WAD_ONE.into());
        shrine.withdraw(eth, trove_id, WAD_ONE.into());

        assert(preview_eth_amt == eth_amt, 'Wrong preview exit eth amt');
        assert(eth_amt == WAD_ONE, 'Wrong yang bal after exit');
        assert(
            eth_erc20
                .balance_of(eth_gate.contract_address) == (expected_initial_eth_amt + deposit_amt.val - WAD_ONE)
                .into(),
            'Wrong eth bal after exit'
        );
        assert(shrine.get_deposit(eth, trove_id) == yang_amt - WAD_ONE.into(), 'Wrong yang bal in shrine');
    }

    #[test]
    fn test_wbtc_enter_exit() {
        let (sentinel, shrine, yangs, gates) = sentinel_utils::deploy_sentinel_with_gates(Option::None);

        let wbtc: ContractAddress = *yangs[1];
        let wbtc_erc20 = IERC20Dispatcher { contract_address: wbtc };
        let wbtc_gate: IGateDispatcher = *gates[1];
        let user: ContractAddress = common::wbtc_hoarder();
        let trove_id: u64 = common::TROVE_1;

        sentinel_utils::approve_max(wbtc_gate, wbtc, user);

        let initial_wbtc_amt: u128 = sentinel_utils::get_initial_asset_amt(wbtc);
        // Deposit a very small amount of WBTC
        let deposit_amt: u128 = 9_u128;

        start_prank(
            CheatTarget::Multiple(array![sentinel.contract_address, shrine.contract_address]),
            sentinel_utils::mock_abbot()
        );

        let preview_yang_amt: Wad = sentinel.convert_to_yang(wbtc, deposit_amt);
        let yang_amt: Wad = sentinel.enter(wbtc, user, deposit_amt);
        shrine.deposit(wbtc, trove_id, yang_amt);

        assert(preview_yang_amt == yang_amt, 'Wrong preview enter yang amt');
        assert(yang_amt == fixed_point_to_wad(deposit_amt, common::WBTC_DECIMALS), 'Wrong yang bal after enter');
        assert(
            wbtc_erc20.balance_of(wbtc_gate.contract_address) == (initial_wbtc_amt + deposit_amt).into(),
            'Wrong wbtc bal after enter'
        );
        assert(shrine.get_deposit(wbtc, trove_id) == yang_amt, 'Wrong yang bal in shrine');

        let preview_wbtc_amt: u128 = sentinel.convert_to_assets(wbtc, yang_amt);
        let wbtc_amt: u128 = sentinel.exit(wbtc, user, yang_amt);
        shrine.withdraw(wbtc, trove_id, yang_amt);

        assert(preview_wbtc_amt == deposit_amt, 'Wrong preview exit WBTC amt');
        assert(wbtc_amt == deposit_amt, 'Wrong exit amt');
        assert(
            wbtc_erc20.balance_of(wbtc_gate.contract_address) == initial_wbtc_amt.into(), 'Wrong wbtc bal after exit'
        );
        assert(shrine.get_deposit(wbtc, trove_id).is_zero(), 'Wrong yang bal in shrine');
    }

    #[test]
    #[should_panic(expected: ('u256_sub Overflow',))]
    fn test_enter_insufficient_balance() {
        let (sentinel, _, eth, _) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);

        let eth_erc20 = IERC20Dispatcher { contract_address: eth };
        let user: ContractAddress = common::eth_hoarder();

        let deposit_amt: Wad = (2 * WAD_ONE).into();

        // Reduce user's balance to below the deposit amount
        start_prank(CheatTarget::One(eth), user);
        eth_erc20.transfer(common::non_zero_address(), eth_erc20.balance_of(user) - (deposit_amt.val - 1).into());

        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::mock_abbot());

        sentinel.enter(eth, user, deposit_amt.val);
    }

    #[test]
    #[should_panic(expected: ('SE: Yang not added',))]
    fn test_enter_yang_not_added() {
        let (sentinel, _) = sentinel_utils::deploy_sentinel(Option::None);

        let user: ContractAddress = common::eth_hoarder();
        let deposit_amt: Wad = (2 * WAD_ONE).into();

        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::mock_abbot());

        sentinel.enter(sentinel_utils::dummy_yang_addr(), user, deposit_amt.val);
    }

    #[test]
    #[should_panic(expected: ('SE: Exceeds max amount allowed',))]
    fn test_enter_exceeds_max_deposit() {
        let (sentinel, _, eth, _) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);

        let user: ContractAddress = common::eth_hoarder();
        let deposit_amt: Wad = (sentinel_utils::ETH_ASSET_MAX + 1).into(); // Deposit amount exceeds max deposit

        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::mock_abbot());

        sentinel.enter(eth, user, deposit_amt.val);
    }

    #[test]
    #[should_panic(expected: ('SE: Yang not added',))]
    fn test_exit_yang_not_added() {
        let (sentinel, _) = sentinel_utils::deploy_sentinel(Option::None);

        let user: ContractAddress = common::eth_hoarder();

        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::mock_abbot());

        sentinel.exit(sentinel_utils::dummy_yang_addr(), user, WAD_ONE.into());
    }

    #[test]
    #[should_panic(expected: ('u256_sub Overflow',))]
    fn test_exit_insufficient_balance() {
        let (sentinel, _, eth, _) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);

        let user: ContractAddress = common::eth_hoarder();

        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::mock_abbot());

        sentinel.exit(eth, user, WAD_ONE.into()); // User does not have any yang to exit
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_enter_unauthorized() {
        let (sentinel, _, eth, _) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);

        let user: ContractAddress = common::eth_hoarder();

        let deposit_amt: Wad = (2 * WAD_ONE).into();

        start_prank(CheatTarget::One(sentinel.contract_address), common::badguy());
        sentinel.enter(eth, user, deposit_amt.val);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_exit_unauthorized() {
        let (sentinel, _, eth, _) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);

        let user: ContractAddress = common::eth_hoarder();

        start_prank(CheatTarget::One(sentinel.contract_address), common::badguy());
        sentinel.exit(eth, user, WAD_ONE.into());
    }


    #[test]
    #[should_panic(expected: ('SE: Gate is not live',))]
    fn test_kill_gate_and_enter() {
        let (sentinel, _, eth, _) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        let user: ContractAddress = common::eth_hoarder();

        let deposit_amt: Wad = (2 * WAD_ONE).into();

        // Kill the gate
        start_prank(CheatTarget::All, sentinel_utils::admin());
        sentinel.kill_gate(eth);

        assert(!sentinel.get_gate_live(eth), 'Gate should be killed');

        // Attempt to enter a killed gate should fail
        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::mock_abbot());
        sentinel.enter(eth, user, deposit_amt.val);
    }

    #[test]
    fn test_kill_gate_and_exit() {
        let (sentinel, shrine, eth, eth_gate) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);

        // Making a regular deposit
        let user: ContractAddress = common::eth_hoarder();
        let trove_id: u64 = common::TROVE_1;

        sentinel_utils::approve_max(eth_gate, eth, user);

        let deposit_amt: Wad = (2 * WAD_ONE).into();

        start_prank(
            CheatTarget::Multiple(array![sentinel.contract_address, shrine.contract_address]),
            sentinel_utils::mock_abbot()
        );

        let yang_amt: Wad = sentinel.enter(eth, user, deposit_amt.val);
        shrine.deposit(eth, trove_id, yang_amt);

        // Killing the gate
        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::admin());
        sentinel.kill_gate(eth);

        // Exiting
        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::mock_abbot());
        sentinel.exit(eth, user, yang_amt);
    }

    #[test]
    #[should_panic(expected: ('SE: Gate is not live',))]
    fn test_kill_gate_and_preview_enter() {
        let (sentinel, _, eth, _) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);

        let deposit_amt: Wad = (2 * WAD_ONE).into();

        // Kill the gate
        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::admin());
        sentinel.kill_gate(eth);

        // Attempt to enter a killed gate should fail
        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::mock_abbot());
        sentinel.convert_to_yang(eth, deposit_amt.val);
    }

    #[test]
    fn test_suspend_unsuspend_yang() {
        let (sentinel, shrine, eth, _) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::admin());
        start_warp(CheatTarget::All, shrine_utils::DEPLOYMENT_TIMESTAMP);

        let status = shrine.get_yang_suspension_status(eth);
        assert(status == YangSuspensionStatus::None, 'status 1');

        sentinel.suspend_yang(eth);
        let status = shrine.get_yang_suspension_status(eth);
        assert(status == YangSuspensionStatus::Temporary, 'status 2');

        // move time forward by 1 day
        start_warp(CheatTarget::All, shrine_utils::DEPLOYMENT_TIMESTAMP + 86400);

        sentinel.unsuspend_yang(eth);
        let status = shrine.get_yang_suspension_status(eth);
        assert(status == YangSuspensionStatus::None, 'status 3');
    }

    #[test]
    #[should_panic(expected: ('SE: Yang suspended',))]
    fn test_try_enter_when_yang_suspended() {
        let (sentinel, _, eth, _) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::admin());
        sentinel.suspend_yang(eth);

        let user: ContractAddress = common::eth_hoarder();
        let deposit_amt: Wad = (2 * WAD_ONE).into();

        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::mock_abbot());
        sentinel.enter(eth, user, deposit_amt.val);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_try_suspending_yang_unauthorized() {
        let (sentinel, _, eth, _) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        start_prank(CheatTarget::One(sentinel.contract_address), common::badguy());
        sentinel.suspend_yang(eth);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_try_unsuspending_yang_unauthorized() {
        let (sentinel, _, eth, _) = sentinel_utils::deploy_sentinel_with_eth_gate(Option::None);
        start_prank(CheatTarget::One(sentinel.contract_address), common::badguy());
        sentinel.unsuspend_yang(eth);
    }
}
