// NOTE: no need to test access control in Gate because only Sentinel, as
//       decalred in constructor args when deploying, can call the gate

#[cfg(test)]
mod TestGate {
    use integer::BoundedInt;
    use starknet::contract_address_const;
    use starknet::testing::set_contract_address;
    use traits::Into;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{WAD_SCALE, Wad};

    use aura::tests::gate::utils::GateUtils;
    use aura::tests::shrine::utils::ShrineUtils;

    #[test]
    #[available_gas(10000000000)]
    fn test_eth_gate_deploy() {
        let (shrine, eth, gate) = GateUtils::eth_gate_deploy();
        let gate = IGateDispatcher { contract_address: gate };

        assert(gate.get_shrine() == shrine, 'get_shrine');
        assert(gate.get_asset() == eth, 'get_asset');
        assert(gate.get_total_assets() == 0, 'get_total_assets');

        // need to add_yang for the next set of asserts
        GateUtils::add_eth_as_yang(shrine, eth);

        assert(gate.get_total_yang() == 0_u128.into(), 'get_total_yang');
        assert(gate.get_asset_amt_per_yang() == WAD_SCALE.into(), 'get_asset_amt_per_yang');
    }

    #[test]
    #[available_gas(10000000000)]
    fn test_wbtc_gate_deploy() {
        // WBTC has different decimals (8) than ETH / Aura (18)
        let (shrine, wbtc, gate) = GateUtils::wbtc_gate_deploy();
        let gate = IGateDispatcher { contract_address: gate };

        assert(gate.get_shrine() == shrine, 'get_shrine');
        assert(gate.get_asset() == wbtc, 'get_asset');
        assert(gate.get_total_assets() == 0, 'get_total_assets');

        // need to add_yang for the next set of asserts
        GateUtils::add_wbtc_as_yang(shrine, wbtc);

        assert(gate.get_total_yang() == 0_u128.into(), 'get_total_yang');
        assert(gate.get_asset_amt_per_yang() == WAD_SCALE.into(), 'get_asset_amt_per_yang');
    }

    #[test]
    #[available_gas(10000000000)]
    fn test_eth_gate_enter_pass() {
        let (shrine, eth, gate) = GateUtils::eth_gate_deploy();
        GateUtils::add_eth_as_yang(shrine, eth);

        let user = GateUtils::eth_hoarder();
        GateUtils::approve_gate_to_user_token(gate, user, eth);

        let trove_id = 1_u64;
        let asset_amt = 20_u128 * WAD_SCALE;

        // a gate can only be called from a sentinel
        set_contract_address(GateUtils::sentinel());

        let gate = IGateDispatcher { contract_address: gate };
        let enter_amt: Wad = gate.enter(user, trove_id, asset_amt);

        let eth = IERC20Dispatcher { contract_address: eth };

        // check exchange rate and gate asset balance
        assert(enter_amt.val == asset_amt, 'enter amount');
        assert(gate.get_asset_amt_per_yang() == WAD_SCALE.into(), 'get_asset_amt_per_yang');
        assert(eth.balance_of(gate.contract_address) == asset_amt.into(), 'gate balance');
    }

    #[test]
    #[available_gas(10000000000)]
    fn test_wbtc_gate_enter_pass() {
        let (shrine, wbtc, gate) = GateUtils::wbtc_gate_deploy();
        GateUtils::add_wbtc_as_yang(shrine, wbtc);

        let user = GateUtils::wbtc_hoarder();
        GateUtils::approve_gate_to_user_token(gate, user, wbtc);

        let trove_id = 1_u64;
        let asset_amt = 3_u128 * 100000000; // 3 WBTC, BTC has 8 decimals

        // a gate can only be called from a sentinel
        set_contract_address(GateUtils::sentinel());

        let gate = IGateDispatcher { contract_address: gate };
        let enter_amt: Wad = gate.enter(user, trove_id, asset_amt);

        let wbtc = IERC20Dispatcher { contract_address: wbtc };

        // check exchange rate and gate asset balance
        assert(enter_amt.val == asset_amt * 10000000000, 'enter amount');
        assert(gate.get_asset_amt_per_yang() == WAD_SCALE.into(), 'get_asset_amt_per_yang');
        assert(wbtc.balance_of(gate.contract_address) == asset_amt.into(), 'gate balance');
    }

    #[test]
    #[available_gas(10000000000)]
    fn test_eth_gate_exit() {
        let (shrine, eth, gate) = GateUtils::eth_gate_deploy();
        GateUtils::add_eth_as_yang(shrine, eth);

        let user = GateUtils::eth_hoarder();
        GateUtils::approve_gate_to_user_token(gate, user, eth);

        let eth = IERC20Dispatcher { contract_address: eth };

        let trove_id = 1_u64;
        let asset_amt = 10_u128 * WAD_SCALE;
        let exit_yang_amt: Wad = (2_u128 * WAD_SCALE).into();
        let remaining_yang_amt = 8_u128 * WAD_SCALE;

        // a gate can only be called from a sentinel
        set_contract_address(GateUtils::sentinel());

        let gate = IGateDispatcher { contract_address: gate };
        gate.enter(user, trove_id, asset_amt);

        let exit_amt = gate.exit(user, trove_id, exit_yang_amt);
        assert(exit_amt == exit_yang_amt.val, 'exit amount');
        assert(gate.get_total_assets() == remaining_yang_amt, 'get_total_assets');
        assert(eth.balance_of(gate.contract_address) == u256 { low: remaining_yang_amt, high: 0 }, 'gate eth balance');
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('GA: Caller is not authorized', 'ENTRYPOINT_FAILED'))]
    fn test_gate_unauthorized_enter() {
        let (shrine, eth, gate) = GateUtils::eth_gate_deploy();
        GateUtils::add_eth_as_yang(shrine, eth);
        let user = contract_address_const::<0xbeef>();
        IGateDispatcher { contract_address: gate }.enter(user, 1, WAD_SCALE);
    }

    #[test]
    #[available_gas(10000000000)]
    #[should_panic(expected: ('GA: Caller is not authorized', 'ENTRYPOINT_FAILED'))]
    fn test_gate_unauthorized_exit() {
        let (shrine, eth, gate) = GateUtils::eth_gate_deploy();
        GateUtils::add_eth_as_yang(shrine, eth);
        let user = contract_address_const::<0xbeef>();
        IGateDispatcher { contract_address: gate }.exit(user, 1, WAD_SCALE.into());
    }

    use debug::PrintTrait;

    #[test]
    #[available_gas(10000000000)]
    fn test_gate_rebasing() {
        let (shrine, eth, gate) = GateUtils::eth_gate_deploy();
        GateUtils::add_eth_as_yang(shrine, eth);

        let user1 = contract_address_const::<0xaa1>();
        let user2 = contract_address_const::<0xbb2>();
        let trove1 = 1_u64;
        let trove2 = 2_u64;
        let enter_amt1 = 5_u128 * WAD_SCALE;
        let enter_amt2 = 12_u128 * WAD_SCALE;

        GateUtils::approve_gate_to_user_token(gate, user1, eth);
        GateUtils::approve_gate_to_user_token(gate, user2, eth);

        let shrine = IShrineDispatcher { contract_address: shrine };
        let eth = IERC20Dispatcher { contract_address: eth };
        let gate = IGateDispatcher { contract_address: gate };

        set_contract_address(GateUtils::eth_hoarder());
        eth.transfer(user1, u256 { low: 10 * WAD_SCALE, high: 0 });
        eth.transfer(user2, u256 { low: 20 * WAD_SCALE, high: 0 });

        // simulate sentinel calling enter
        set_contract_address(GateUtils::sentinel());
        let yang_amt1 = gate.enter(user1, trove1, enter_amt1);
        let yang_amt2 = gate.enter(user2, trove2, enter_amt2);

        // simulate depositing
        ShrineUtils::make_root(shrine.contract_address, ShrineUtils::admin());
        set_contract_address(ShrineUtils::admin());
        shrine.deposit(eth.contract_address, trove1, yang_amt1);
        shrine.deposit(eth.contract_address, trove2, yang_amt2);

        let gate_yang = gate.get_total_yang();
        assert(gate_yang == yang_amt1 + yang_amt2, 'get_total_yang');

         // TODO: rebase (via mint), test shit
    }
}
