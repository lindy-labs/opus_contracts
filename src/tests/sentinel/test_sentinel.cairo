#[cfg(test)]
mod TestSentinel {
    use array::SpanTrait;
    use debug::PrintTrait; 
    use option::OptionTrait;
    use traits::Into;

    use aura::core::sentinel::Sentinel;

    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::tests::sentinel::utils::SentinelUtils;
    use aura::tests::shrine::utils::ShrineUtils;
    use aura::utils::wadray;
    use aura::utils::wadray::{Wad, Ray};
    
    #[test]
    #[available_gas(10000000000)]
    fn test_deploy_sentinel_and_add_yang() {
        let (sentinel, shrine, assets, gates) = SentinelUtils::deploy_sentinel_with_gates();

        // Checking that sentinel was set up correctly 

        let eth_gate = *gates.at(0);
        let wbtc_gate = *gates.at(1);

        let eth = *assets.at(0);
        let wbtc = *assets.at(1);

        assert(sentinel.get_gate_address(*assets.at(0)) == eth_gate.contract_address, 'Wrong gate address #1');
        assert(sentinel.get_gate_address(*assets.at(1)) == wbtc_gate.contract_address, 'Wrong gate address #2');

        assert(sentinel.get_gate_live(*assets.at(0)), 'Gate not live #1');
        assert(sentinel.get_gate_live(*assets.at(1)), 'Gate not live #2');

        let given_yang_addresses = sentinel.get_yang_addresses();
        assert(*given_yang_addresses.at(0) == *assets.at(0) & *given_yang_addresses.at(1) == *assets.at(1), 'Wrong yang addresses');

        assert(sentinel.get_yang(0) == *assets.at(0), 'Wrong yang #1');
        assert(sentinel.get_yang(1) == *assets.at(1), 'Wrong yang #2');

        assert(sentinel.get_yang_asset_max(eth) == SentinelUtils::ETH_ASSET_MAX, 'Wrong asset max #1');
        assert(sentinel.get_yang_asset_max(wbtc) == SentinelUtils::WBTC_ASSET_MAX, 'Wrong asset max #2');

        assert(sentinel.get_yang_addresses_count() == 2, 'Wrong yang addresses count');

        // Checking that the gates were set up correctly 

        assert((eth_gate).get_sentinel() == sentinel.contract_address, 'Wrong sentinel');
        assert((wbtc_gate).get_sentinel() == sentinel.contract_address, 'Wrong sentinel');

        // Checking that shrine was set up correctly

        let (eth_price, _, _) = shrine.get_current_yang_price(eth);
        let (wbtc_price, _, _) = shrine.get_current_yang_price(wbtc);

        assert(eth_price == ShrineUtils::YANG1_START_PRICE.into(), 'Wrong yang price #1');
        assert(wbtc_price == ShrineUtils::YANG2_START_PRICE.into(), 'Wrong yang price #2');

        assert(shrine.get_yang_threshold(eth) == ShrineUtils::YANG1_THRESHOLD.into(), 'Wrong yang threshold #1');
        assert(shrine.get_yang_threshold(wbtc) == ShrineUtils::YANG2_THRESHOLD.into(), 'Wrong yang threshold #2');

        assert(shrine.get_yang_rate(eth, 0) == ShrineUtils::YANG1_BASE_RATE.into(), 'Wrong yang rate #1');
        assert(shrine.get_yang_rate(wbtc, 0) == ShrineUtils::YANG2_BASE_RATE.into(), 'Wrong yang rate #2');

        assert(shrine.get_yang_total(eth) == Sentinel::INITIAL_DEPOSIT_AMT.into(), 'Wrong yang total #1');
        assert(shrine.get_yang_total(wbtc) == wadray::fixed_point_to_wad(Sentinel::INITIAL_DEPOSIT_AMT, 8), 'Wrong yang total #2');
    }
}
