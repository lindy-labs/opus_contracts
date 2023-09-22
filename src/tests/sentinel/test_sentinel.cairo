mod TestSentinel {
    use debug::PrintTrait;
    use starknet::ContractAddress;
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};

    use aura::core::sentinel::Sentinel;
    use aura::core::roles::SentinelRoles;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::types::YangSuspensionStatus;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, Wad, WAD_ONE};

    use aura::tests::gate::utils::GateUtils;
    use aura::tests::sentinel::utils::SentinelUtils;
    use aura::tests::shrine::utils::ShrineUtils;
    use aura::tests::common;

    #[test]
    #[available_gas(10000000000)]
    fn test_deploy_sentinel_and_add_yang() {
        let (sentinel, shrine, assets, gates) = SentinelUtils::deploy_sentinel_with_gates();

        // Checking that sentinel was set up correctly

        let eth_gate = *gates.at(0);
        let wbtc_gate = *gates.at(1);

        let eth = *assets.at(0);
        let wbtc = *assets.at(1);

        assert(
            sentinel.get_gate_address(*assets.at(0)) == eth_gate.contract_address,
            'Wrong gate address #1'
        );
        assert(
            sentinel.get_gate_address(*assets.at(1)) == wbtc_gate.contract_address,
            'Wrong gate address #2'
        );

        assert(sentinel.get_gate_live(*assets.at(0)), 'Gate not live #1');
        assert(sentinel.get_gate_live(*assets.at(1)), 'Gate not live #2');

        let given_yang_addresses = sentinel.get_yang_addresses();
        assert(
            *given_yang_addresses.at(0) == *assets.at(0)
                && *given_yang_addresses.at(1) == *assets.at(1),
            'Wrong yang addresses'
        );

        assert(sentinel.get_yang(0) == ContractAddressZeroable::zero(), 'Should be zero address');
        assert(sentinel.get_yang(1) == *assets.at(0), 'Wrong yang #1');
        assert(sentinel.get_yang(2) == *assets.at(1), 'Wrong yang #2');

        assert(
            sentinel.get_yang_asset_max(eth) == SentinelUtils::ETH_ASSET_MAX, 'Wrong asset max #1'
        );
        assert(
            sentinel.get_yang_asset_max(wbtc) == SentinelUtils::WBTC_ASSET_MAX, 'Wrong asset max #2'
        );

        assert(sentinel.get_yang_addresses_count() == 2, 'Wrong yang addresses count');

        let sentinel_ac = IAccessControlDispatcher { contract_address: sentinel.contract_address };
        assert(sentinel_ac.get_admin() == SentinelUtils::admin(), 'Wrong admin');
        assert(
            sentinel_ac.get_roles(SentinelUtils::admin()) == SentinelRoles::default_admin_role(),
            'Wrong roles for admin'
        );

        // Checking that the gates were set up correctly

        assert((eth_gate).get_sentinel() == sentinel.contract_address, 'Wrong sentinel #1');
        assert((wbtc_gate).get_sentinel() == sentinel.contract_address, 'Wrong sentinel #2');

        // Checking that shrine was set up correctly

        let (eth_price, _, _) = shrine.get_current_yang_price(eth);
        let (wbtc_price, _, _) = shrine.get_current_yang_price(wbtc);

        assert(eth_price == ShrineUtils::YANG1_START_PRICE.into(), 'Wrong yang price #1');
        assert(wbtc_price == ShrineUtils::YANG2_START_PRICE.into(), 'Wrong yang price #2');

        let (eth_threshold, _) = shrine.get_yang_threshold(eth);
        assert(eth_threshold == ShrineUtils::YANG1_THRESHOLD.into(), 'Wrong yang threshold #1');

        let (wbtc_threshold, _) = shrine.get_yang_threshold(wbtc);
        assert(wbtc_threshold == ShrineUtils::YANG2_THRESHOLD.into(), 'Wrong yang threshold #2');

        let expected_era: u64 = 1;
        assert(
            shrine.get_yang_rate(eth, expected_era) == ShrineUtils::YANG1_BASE_RATE.into(),
            'Wrong yang rate #1'
        );
        assert(
            shrine.get_yang_rate(wbtc, expected_era) == ShrineUtils::YANG2_BASE_RATE.into(),
            'Wrong yang rate #2'
        );

        assert(
            shrine.get_yang_total(eth) == Sentinel::INITIAL_DEPOSIT_AMT.into(),
            'Wrong yang total #1'
        );
        assert(
            shrine
                .get_yang_total(
                    wbtc
                ) == wadray::fixed_point_to_wad(Sentinel::INITIAL_DEPOSIT_AMT, 8),
            'Wrong yang total #2'
        );
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_unauthorized() {
        let (sentinel, shrine_addr) = SentinelUtils::deploy_sentinel();

        sentinel
            .add_yang(
                SentinelUtils::dummy_yang_addr(),
                SentinelUtils::ETH_ASSET_MAX,
                ShrineUtils::YANG1_THRESHOLD.into(),
                ShrineUtils::YANG1_START_PRICE.into(),
                ShrineUtils::YANG1_BASE_RATE.into(),
                SentinelUtils::dummy_yang_gate_addr()
            );
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('SE: Yang cannot be zero address', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_yang_zero_addr() {
        let (sentinel, shrine_addr) = SentinelUtils::deploy_sentinel();
        set_contract_address(SentinelUtils::admin());
        sentinel
            .add_yang(
                ContractAddressZeroable::zero(),
                SentinelUtils::ETH_ASSET_MAX,
                ShrineUtils::YANG1_THRESHOLD.into(),
                ShrineUtils::YANG1_START_PRICE.into(),
                ShrineUtils::YANG1_BASE_RATE.into(),
                SentinelUtils::dummy_yang_gate_addr()
            );
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('SE: Gate cannot be zero address', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_gate_zero_addr() {
        let (sentinel, shrine_addr) = SentinelUtils::deploy_sentinel();
        set_contract_address(SentinelUtils::admin());
        sentinel
            .add_yang(
                SentinelUtils::dummy_yang_addr(),
                SentinelUtils::ETH_ASSET_MAX,
                ShrineUtils::YANG1_THRESHOLD.into(),
                ShrineUtils::YANG1_START_PRICE.into(),
                ShrineUtils::YANG1_BASE_RATE.into(),
                ContractAddressZeroable::zero()
            );
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('SE: Yang already added', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_yang_already_added() {
        let (sentinel, shrine, eth, eth_gate) = SentinelUtils::deploy_sentinel_with_eth_gate();

        set_contract_address(SentinelUtils::admin());
        sentinel
            .add_yang(
                eth,
                SentinelUtils::ETH_ASSET_MAX,
                ShrineUtils::YANG1_THRESHOLD.into(),
                ShrineUtils::YANG1_START_PRICE.into(),
                ShrineUtils::YANG1_BASE_RATE.into(),
                eth_gate.contract_address
            );
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('SE: Asset of gate is not yang', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_gate_yang_mismatch() {
        let (sentinel, shrine, eth, eth_gate) = SentinelUtils::deploy_sentinel_with_eth_gate();
        let wbtc: ContractAddress = GateUtils::wbtc_token_deploy();

        set_contract_address(SentinelUtils::admin());
        sentinel
            .add_yang(
                wbtc,
                SentinelUtils::WBTC_ASSET_MAX,
                ShrineUtils::YANG2_THRESHOLD.into(),
                ShrineUtils::YANG2_START_PRICE.into(),
                ShrineUtils::YANG2_BASE_RATE.into(),
                eth_gate.contract_address
            );
    }

    #[test]
    #[available_gas(10000000000)]
    fn test_set_yang_asset_max() {
        let (sentinel, shrine, eth, eth_gate) = SentinelUtils::deploy_sentinel_with_eth_gate();

        let new_asset_max = SentinelUtils::ETH_ASSET_MAX * 2;

        set_contract_address(SentinelUtils::admin());

        // Test increasing the max
        sentinel.set_yang_asset_max(eth, new_asset_max);
        assert(sentinel.get_yang_asset_max(eth) == new_asset_max, 'Wrong asset max');

        // Test decreasing the max
        sentinel.set_yang_asset_max(eth, new_asset_max - 1);
        assert(sentinel.get_yang_asset_max(eth) == new_asset_max - 1, 'Wrong asset max');

        // Test decreasing the max to below the current yang total
        sentinel.set_yang_asset_max(eth, Sentinel::INITIAL_DEPOSIT_AMT - 1);
        assert(
            sentinel.get_yang_asset_max(eth) == Sentinel::INITIAL_DEPOSIT_AMT - 1, 'Wrong asset max'
        );
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('SE: Yang not added', 'ENTRYPOINT_FAILED'))]
    fn test_set_yang_asset_max_non_existent_yang() {
        let (sentinel, shrine, eth, eth_gate) = SentinelUtils::deploy_sentinel_with_eth_gate();

        set_contract_address(SentinelUtils::admin());
        sentinel.set_yang_asset_max(SentinelUtils::dummy_yang_addr(), SentinelUtils::ETH_ASSET_MAX);
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_yang_asset_max_unauthed() {
        let (sentinel, shrine, eth, eth_gate) = SentinelUtils::deploy_sentinel_with_eth_gate();
        set_contract_address(common::badguy());
        sentinel.set_yang_asset_max(eth, SentinelUtils::ETH_ASSET_MAX);
    }

    #[test]
    #[available_gas(10000000000)]
    fn test_enter_exit() {
        let (sentinel, shrine, eth, eth_gate) = SentinelUtils::deploy_sentinel_with_eth_gate();

        let eth_erc20 = IERC20Dispatcher { contract_address: eth };
        let user: ContractAddress = GateUtils::eth_hoarder();

        SentinelUtils::approve_max(eth_gate, eth, user);

        let deposit_amt: Wad = (2 * WAD_ONE).into();

        set_contract_address(SentinelUtils::mock_abbot());

        let preview_yang_amt: Wad = sentinel.convert_to_yang(eth, deposit_amt.val);
        let yang_amt: Wad = sentinel.enter(eth, user, common::TROVE_1, deposit_amt.val);
        shrine.deposit(eth, common::TROVE_1, yang_amt);

        assert(preview_yang_amt == yang_amt, 'Wrong preview enter yang amt');
        assert(yang_amt == deposit_amt, 'Wrong yang bal after enter');
        assert(
            eth_erc20
                .balance_of(
                    eth_gate.contract_address
                ) == (Sentinel::INITIAL_DEPOSIT_AMT + deposit_amt.val)
                .into(),
            'Wrong eth bal after enter'
        );
        assert(shrine.get_deposit(eth, common::TROVE_1) == yang_amt, 'Wrong yang bal in shrine');

        let preview_eth_amt: u128 = sentinel.convert_to_assets(eth, WAD_ONE.into());
        let eth_amt: u128 = sentinel.exit(eth, user, common::TROVE_1, WAD_ONE.into());
        shrine.withdraw(eth, common::TROVE_1, WAD_ONE.into());

        assert(preview_eth_amt == eth_amt, 'Wrong preview exit eth amt');
        assert(eth_amt == WAD_ONE, 'Wrong yang bal after exit');
        assert(
            eth_erc20
                .balance_of(
                    eth_gate.contract_address
                ) == (Sentinel::INITIAL_DEPOSIT_AMT + deposit_amt.val - WAD_ONE)
                .into(),
            'Wrong eth bal after exit'
        );
        assert(
            shrine.get_deposit(eth, common::TROVE_1) == yang_amt - WAD_ONE.into(),
            'Wrong yang bal in shrine'
        );
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(
        expected: (
            'u256_sub Overflow', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED'
        )
    )]
    fn test_enter_insufficient_balance() {
        let (sentinel, shrine, eth, eth_gate) = SentinelUtils::deploy_sentinel_with_eth_gate();

        let eth_erc20 = IERC20Dispatcher { contract_address: eth };
        let user: ContractAddress = GateUtils::eth_hoarder();

        let deposit_amt: Wad = (2 * WAD_ONE).into();

        // Reduce user's balance to below the deposit amount
        set_contract_address(user);
        eth_erc20
            .transfer(
                common::non_zero_address(),
                eth_erc20.balance_of(user) - (deposit_amt.val - 1).into()
            );

        set_contract_address(SentinelUtils::mock_abbot());

        sentinel.enter(eth, user, common::TROVE_1, deposit_amt.val);
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('SE: Yang not added', 'ENTRYPOINT_FAILED'))]
    fn test_enter_yang_not_added() {
        let (sentinel, shrine_addr) = SentinelUtils::deploy_sentinel();

        let user: ContractAddress = GateUtils::eth_hoarder();
        let deposit_amt: Wad = (2 * WAD_ONE).into();

        set_contract_address(SentinelUtils::mock_abbot());

        sentinel.enter(SentinelUtils::dummy_yang_addr(), user, common::TROVE_1, deposit_amt.val);
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('SE: Exceeds max amount allowed', 'ENTRYPOINT_FAILED'))]
    fn test_enter_exceeds_max_deposit() {
        let (sentinel, shrine, eth, eth_gate) = SentinelUtils::deploy_sentinel_with_eth_gate();

        let user: ContractAddress = GateUtils::eth_hoarder();
        let deposit_amt: Wad = (SentinelUtils::ETH_ASSET_MAX + 1)
            .into(); // Deposit amount exceeds max deposit

        set_contract_address(SentinelUtils::mock_abbot());

        sentinel.enter(eth, user, common::TROVE_1, deposit_amt.val);
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('SE: Yang not added', 'ENTRYPOINT_FAILED'))]
    fn test_exit_yang_not_added() {
        let (sentinel, shrine_addr) = SentinelUtils::deploy_sentinel();

        let user: ContractAddress = GateUtils::eth_hoarder();

        set_contract_address(SentinelUtils::mock_abbot());

        sentinel.exit(SentinelUtils::dummy_yang_addr(), user, common::TROVE_1, WAD_ONE.into());
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(
        expected: (
            'u256_sub Overflow', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED'
        )
    )]
    fn test_exit_insufficient_balance() {
        let (sentinel, shrine, eth, eth_gate) = SentinelUtils::deploy_sentinel_with_eth_gate();

        let user: ContractAddress = GateUtils::eth_hoarder();

        set_contract_address(SentinelUtils::mock_abbot());

        sentinel
            .exit(
                eth, user, common::TROVE_1, WAD_ONE.into()
            ); // User does not have any yang to exit
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_enter_unauthorized() {
        let (sentinel, shrine, eth, eth_gate) = SentinelUtils::deploy_sentinel_with_eth_gate();

        let user: ContractAddress = GateUtils::eth_hoarder();

        let deposit_amt: Wad = (2 * WAD_ONE).into();

        set_contract_address(common::badguy());
        let yang_amt: Wad = sentinel.enter(eth, user, common::TROVE_1, deposit_amt.val);
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_exit_unauthorized() {
        let (sentinel, shrine, eth, eth_gate) = SentinelUtils::deploy_sentinel_with_eth_gate();

        let user: ContractAddress = GateUtils::eth_hoarder();

        set_contract_address(common::badguy());
        let eth_amt: u128 = sentinel.exit(eth, user, common::TROVE_1, WAD_ONE.into());
    }


    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('SE: Gate is not live', 'ENTRYPOINT_FAILED'))]
    fn test_kill_gate_and_enter() {
        let (sentinel, shrine, eth, eth_gate) = SentinelUtils::deploy_sentinel_with_eth_gate();
        let user: ContractAddress = GateUtils::eth_hoarder();
        let deposit_amt: Wad = (2 * WAD_ONE).into();

        // Kill the gate
        set_contract_address(SentinelUtils::admin());
        sentinel.kill_gate(eth);

        assert(!sentinel.get_gate_live(eth), 'Gate should be killed');

        // Attempt to enter a killed gate should fail
        set_contract_address(SentinelUtils::mock_abbot());
        sentinel.enter(eth, user, common::TROVE_1, deposit_amt.val);
    }

    #[test]
    #[available_gas(10000000000)]
    fn test_kill_gate_and_exit() {
        let (sentinel, shrine, eth, eth_gate) = SentinelUtils::deploy_sentinel_with_eth_gate();

        // Making a regular deposit
        let eth_erc20 = IERC20Dispatcher { contract_address: eth };
        let user: ContractAddress = GateUtils::eth_hoarder();

        SentinelUtils::approve_max(eth_gate, eth, user);

        let deposit_amt: Wad = (2 * WAD_ONE).into();

        set_contract_address(SentinelUtils::mock_abbot());

        let yang_amt: Wad = sentinel.enter(eth, user, common::TROVE_1, deposit_amt.val);
        shrine.deposit(eth, common::TROVE_1, yang_amt);

        // Killing the gate
        set_contract_address(SentinelUtils::admin());
        sentinel.kill_gate(eth);

        // Exiting
        set_contract_address(SentinelUtils::mock_abbot());
        sentinel.exit(eth, user, common::TROVE_1, yang_amt);
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('SE: Gate is not live', 'ENTRYPOINT_FAILED'))]
    fn test_kill_gate_and_preview_enter() {
        let (sentinel, shrine, eth, eth_gate) = SentinelUtils::deploy_sentinel_with_eth_gate();
        let user: ContractAddress = GateUtils::eth_hoarder();
        let deposit_amt: Wad = (2 * WAD_ONE).into();

        // Kill the gate
        set_contract_address(SentinelUtils::admin());
        sentinel.kill_gate(eth);

        // Attempt to enter a killed gate should fail
        set_contract_address(SentinelUtils::mock_abbot());
        sentinel.convert_to_yang(eth, deposit_amt.val);
    }

    #[test]
    #[available_gas(10000000000)]
    fn test_suspend_unsuspend_yang() {
        let (sentinel, shrine, eth, _) = SentinelUtils::deploy_sentinel_with_eth_gate();
        set_contract_address(SentinelUtils::admin());
        set_block_timestamp(ShrineUtils::DEPLOYMENT_TIMESTAMP);

        let status = shrine.get_yang_suspension_status(eth);
        assert(status == YangSuspensionStatus::None, 'status 1');

        sentinel.suspend_yang(eth);
        let status = shrine.get_yang_suspension_status(eth);
        assert(status == YangSuspensionStatus::Temporary, 'status 2');

        // move time forward by 1 day
        set_block_timestamp(ShrineUtils::DEPLOYMENT_TIMESTAMP + 86400);

        sentinel.unsuspend_yang(eth);
        let status = shrine.get_yang_suspension_status(eth);
        assert(status == YangSuspensionStatus::None, 'status 3');
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('SE: Yang suspended', 'ENTRYPOINT_FAILED'))]
    fn test_try_enter_when_yang_suspended() {
        let (sentinel, shrine, eth, _) = SentinelUtils::deploy_sentinel_with_eth_gate();
        set_contract_address(SentinelUtils::admin());
        sentinel.suspend_yang(eth);

        let user: ContractAddress = GateUtils::eth_hoarder();
        let deposit_amt: Wad = (2 * WAD_ONE).into();

        set_contract_address(SentinelUtils::mock_abbot());
        sentinel.enter(eth, user, common::TROVE_1, deposit_amt.val);
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_try_suspending_yang_unauthorized() {
        let (sentinel, _, eth, _) = SentinelUtils::deploy_sentinel_with_eth_gate();
        set_contract_address(common::badguy());
        sentinel.suspend_yang(eth);
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_try_unsuspending_yang_unauthorized() {
        let (sentinel, _, eth, _) = SentinelUtils::deploy_sentinel_with_eth_gate();
        set_contract_address(common::badguy());
        sentinel.unsuspend_yang(eth);
    }
}
