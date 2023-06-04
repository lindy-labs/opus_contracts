#[cfg(test)]
mod TestGate {
    use traits::Into;
    use starknet::contract_address_const;
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{WAD_SCALE, Wad};

    use aura::tests::gate::utils::GateUtils;
    
    #[test]
    #[available_gas(10000000000)]
    fn test_gate_deploy() {
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
}
