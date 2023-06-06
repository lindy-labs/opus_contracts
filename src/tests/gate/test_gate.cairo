// NOTE: no need to test access control in Gate because only Sentinel, as
//       decalred in constructor args when deploying, can call the gate

#[cfg(test)]
mod TestGate {
    use integer::BoundedInt;
    use starknet::contract_address_const;
    use starknet::testing::set_contract_address;
    use traits::Into;

    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{WAD_SCALE, Wad};

    use aura::tests::gate::utils::GateUtils;
    
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

        // make user approve the gate for unlimited token ops
        let eth = IERC20Dispatcher { contract_address: eth };
        let user = GateUtils::eth_hoarder();
        set_contract_address(user);
        eth.approve(gate, BoundedInt::max());

        let trove_id = 1_u64;
        let asset_amt = 20_u128 * WAD_SCALE;

        // a gate can only be called from a sentinel
        set_contract_address(GateUtils::sentinel());

        let gate = IGateDispatcher { contract_address: gate };
        let yang_amt: Wad = gate.enter(user, trove_id, asset_amt);

        // check exchange rate and gate asset balance
        assert(yang_amt.val == asset_amt, 'enter return value');
        assert(gate.get_asset_amt_per_yang() == WAD_SCALE.into(), 'get_asset_amt_per_yang');
        assert(eth.balance_of(gate.contract_address) == asset_amt.into(), 'gate balance');
    }

    #[test]
    #[available_gas(10000000000)]
    fn test_wbtc_gate_enter_pass() {
        let (shrine, wbtc, gate) = GateUtils::wbtc_gate_deploy();
        GateUtils::add_wbtc_as_yang(shrine, wbtc);

        // make user approve the gate for unlimited token ops
        let wbtc = IERC20Dispatcher { contract_address: wbtc };
        let user = GateUtils::wbtc_hoarder();
        set_contract_address(user);
        wbtc.approve(gate, BoundedInt::max());

        let trove_id = 1_u64;
        let asset_amt = 3_u128 * 100000000; // 3 WBTC

        // a gate can only be called from a sentinel
        set_contract_address(GateUtils::sentinel());

        let gate = IGateDispatcher { contract_address: gate };
        let yang_amt: Wad = gate.enter(user, trove_id, asset_amt);

        // check exchange rate and gate asset balance
        assert(yang_amt.val == asset_amt * 10000000000, 'enter return value');
        assert(gate.get_asset_amt_per_yang() == WAD_SCALE.into(), 'get_asset_amt_per_yang');
        assert(wbtc.balance_of(gate.contract_address) == asset_amt.into(), 'gate balance');
    }


    // TODO: test preview_enter, preview_exit

    // TODO: test enter, test exit
    //       test enter wrong call on enter, wrong caller on exit

    // TODO: test w/ USDC or WBTC (different decimals than 18)
}
