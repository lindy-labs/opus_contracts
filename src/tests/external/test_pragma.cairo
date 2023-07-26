#[cfg(test)]
mod TestPragma {
    use array::{ArrayTrait, SpanTrait};
    use integer::U256Zeroable;
    use option::OptionTrait;
    use starknet::{
        ContractAddress, contract_address_const, contract_address_try_from_felt252,
        get_block_timestamp
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};
    use traits::{Default, Into};

    use aura::core::roles::PragmaRoles;
    use aura::core::shrine::Shrine;
    use aura::external::pragma::Pragma;

    use aura::interfaces::external::{IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait};
    use aura::interfaces::IERC20::{IMintableDispatcher, IMintableDispatcherTrait};
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use aura::interfaces::IPragma::{IPragmaDispatcher, IPragmaDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::pow::pow10;
    use aura::utils::types::Pragma::PricesResponse;
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{WadZeroable, WAD_DECIMALS, WAD_SCALE};

    use aura::tests::common;
    use aura::tests::external::mock_pragma::{
        IMockPragmaDispatcher, IMockPragmaDispatcherTrait, MockPragma
    };
    use aura::tests::external::utils::PragmaUtils;
    use aura::tests::sentinel::utils::SentinelUtils;

    //
    // Constants
    //

    const PEPE_USD_PAIR_ID: u256 = 5784117554504356676; // str_to_felt("PEPE/USD")     

    //
    // Address constants
    //

    #[inline(always)]
    fn pepe_token_addr() -> ContractAddress {
        contract_address_try_from_felt252('PEPE').unwrap()
    }

    //
    // Tests - Deployment and setters
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_setup() {
        let (_, pragma, _, _, _, _) = PragmaUtils::pragma_with_yangs();

        // Check permissions
        let pragma_ac = IAccessControlDispatcher { contract_address: pragma.contract_address };
        let admin: ContractAddress = PragmaUtils::admin();

        assert(pragma_ac.get_admin() == admin, 'wrong admin');
        assert(pragma_ac.get_roles(admin) == PragmaRoles::default_admin_role(), 'wrong admin role');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_price_validity_thresholds_pass() {
        let (_, pragma, _, _, _, _) = PragmaUtils::pragma_with_yangs();

        let new_freshness: u64 = 300; // 5 minutes * 60 seconds
        let new_sources: u64 = 8;

        set_contract_address(PragmaUtils::admin());
        pragma.set_price_validity_thresholds(new_freshness, new_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Freshness out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_freshness_too_low_fail() {
        let (_, pragma, _, _, _, _) = PragmaUtils::pragma_with_yangs();

        let invalid_freshness: u64 = Pragma::LOWER_FRESHNESS_BOUND - 1;
        let valid_sources: u64 = PragmaUtils::SOURCES_THRESHOLD;

        set_contract_address(PragmaUtils::admin());
        pragma.set_price_validity_thresholds(invalid_freshness, valid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Freshness out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_freshness_too_high_fail() {
        let (_, pragma, _, _, _, _) = PragmaUtils::pragma_with_yangs();

        let invalid_freshness: u64 = Pragma::UPPER_FRESHNESS_BOUND + 1;
        let valid_sources: u64 = PragmaUtils::SOURCES_THRESHOLD;

        set_contract_address(PragmaUtils::admin());
        pragma.set_price_validity_thresholds(invalid_freshness, valid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Sources out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_sources_too_low_fail() {
        let (_, pragma, _, _, _, _) = PragmaUtils::pragma_with_yangs();

        let valid_freshness: u64 = PragmaUtils::FRESHNESS_THRESHOLD;
        let invalid_sources: u64 = Pragma::LOWER_SOURCES_BOUND - 1;

        set_contract_address(PragmaUtils::admin());
        pragma.set_price_validity_thresholds(valid_freshness, invalid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Sources out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_sources_too_high_fail() {
        let (_, pragma, _, _, _, _) = PragmaUtils::pragma_with_yangs();

        let valid_freshness: u64 = PragmaUtils::FRESHNESS_THRESHOLD;
        let invalid_sources: u64 = Pragma::UPPER_SOURCES_BOUND + 1;

        set_contract_address(PragmaUtils::admin());
        pragma.set_price_validity_thresholds(valid_freshness, invalid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_unauthorized_fail() {
        let (_, pragma, _, _, _, _) = PragmaUtils::pragma_with_yangs();

        let valid_freshness: u64 = PragmaUtils::FRESHNESS_THRESHOLD;
        let valid_sources: u64 = PragmaUtils::SOURCES_THRESHOLD;

        set_contract_address(common::badguy());
        pragma.set_price_validity_thresholds(valid_freshness, valid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_oracle_address_pass() {
        let (_, pragma, _, _, _, _) = PragmaUtils::pragma_with_yangs();

        let new_address: ContractAddress = contract_address_const::<0x9999>();

        set_contract_address(PragmaUtils::admin());
        pragma.set_oracle(new_address);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Address cannot be zero', 'ENTRYPOINT_FAILED'))]
    fn test_set_oracle_zero_address_fail() {
        let (_, pragma, _, _, _, _) = PragmaUtils::pragma_with_yangs();

        set_contract_address(PragmaUtils::admin());
        pragma.set_oracle(ContractAddressZeroable::zero());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_oracle_address_unauthorized_fail() {
        let (_, pragma, _, _, _, _) = PragmaUtils::pragma_with_yangs();

        let new_address: ContractAddress = contract_address_const::<0x9999>();

        set_contract_address(common::badguy());
        pragma.set_oracle(new_address);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_update_frequency_pass() {
        let (_, pragma, _, _, _, _) = PragmaUtils::pragma_with_yangs();

        let new_frequency: u64 = PragmaUtils::UPDATE_FREQUENCY * 2;

        set_contract_address(PragmaUtils::admin());
        pragma.set_update_frequency(new_frequency);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Frequency out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_update_frequency_too_low_fail() {
        let (_, pragma, _, _, _, _) = PragmaUtils::pragma_with_yangs();

        let invalid_frequency: u64 = Pragma::LOWER_UPDATE_FREQUENCY_BOUND - 1;

        set_contract_address(PragmaUtils::admin());
        pragma.set_update_frequency(invalid_frequency);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Frequency out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_update_frequency_too_high_fail() {
        let (_, pragma, _, _, _, _) = PragmaUtils::pragma_with_yangs();

        let invalid_frequency: u64 = Pragma::UPPER_UPDATE_FREQUENCY_BOUND + 1;

        set_contract_address(PragmaUtils::admin());
        pragma.set_update_frequency(invalid_frequency);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_update_frequency_unauthorized_fail() {
        let (_, pragma, _, _, _, _) = PragmaUtils::pragma_with_yangs();

        let new_frequency: u64 = PragmaUtils::UPDATE_FREQUENCY * 2;

        set_contract_address(common::badguy());
        pragma.set_update_frequency(new_frequency);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_unauthorized_fail() {
        let (shrine, pragma, sentinel, _) = PragmaUtils::pragma_deploy();
        let (eth_token_addr, eth_gate) = SentinelUtils::add_eth_yang(
            sentinel, shrine.contract_address
        );

        set_contract_address(common::badguy());

        pragma.add_yang(PragmaUtils::ETH_USD_PAIR_ID, eth_token_addr);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Yang already present', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_non_unique_address_fail() {
        let (shrine, pragma, sentinel, _) = PragmaUtils::pragma_deploy();
        let (eth_token_addr, eth_gate) = SentinelUtils::add_eth_yang(
            sentinel, shrine.contract_address
        );

        set_contract_address(PragmaUtils::admin());
        pragma.add_yang(PragmaUtils::ETH_USD_PAIR_ID, eth_token_addr);
        pragma.add_yang(PragmaUtils::WBTC_USD_PAIR_ID, eth_token_addr);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Pair ID already present', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_non_unique_pair_id_fail() {
        let (shrine, pragma, sentinel, _) = PragmaUtils::pragma_deploy();
        let (eth_token_addr, eth_gate) = SentinelUtils::add_eth_yang(
            sentinel, shrine.contract_address
        );

        set_contract_address(PragmaUtils::admin());
        pragma.add_yang(PragmaUtils::ETH_USD_PAIR_ID, eth_token_addr);
        pragma.add_yang(PragmaUtils::ETH_USD_PAIR_ID, pepe_token_addr());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Invalid pair ID', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_invalid_pair_id_fail() {
        let (shrine, pragma, sentinel, _) = PragmaUtils::pragma_deploy();
        let (eth_token_addr, eth_gate) = SentinelUtils::add_eth_yang(
            sentinel, shrine.contract_address
        );

        set_contract_address(PragmaUtils::admin());

        let invalid_pair_id = U256Zeroable::zero();
        pragma.add_yang(invalid_pair_id, eth_token_addr);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Invalid yang address', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_invalid_yang_address_fail() {
        let (_, pragma, _, _) = PragmaUtils::pragma_deploy();

        set_contract_address(PragmaUtils::admin());

        let invalid_yang_addr = ContractAddressZeroable::zero();
        pragma.add_yang(PragmaUtils::ETH_USD_PAIR_ID, invalid_yang_addr);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Unknown pair ID', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_unknown_pair_id_fail() {
        let (_, pragma, _, _) = PragmaUtils::pragma_deploy();

        set_contract_address(PragmaUtils::admin());

        pragma.add_yang(PEPE_USD_PAIR_ID, pepe_token_addr());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Too many decimals', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_too_many_decimals_fail() {
        let (_, pragma, _, mock_pragma, _, _) = PragmaUtils::pragma_with_yangs();

        let price_ts: u256 = (get_block_timestamp() - 1000).into();
        let pragma_price_scale: u128 = pow10(PragmaUtils::PRAGMA_DECIMALS);

        let pepe_price: u128 = 1000000 * pragma_price_scale; // random price
        let invalid_decimals: u256 = (WAD_DECIMALS + 1).into();
        let pepe_response = PricesResponse {
            price: pepe_price.into(),
            decimals: invalid_decimals,
            last_updated_timestamp: price_ts,
            num_sources_aggregated: PragmaUtils::DEFAULT_NUM_SOURCES,
        };
        mock_pragma.next_get_data_median(PEPE_USD_PAIR_ID, pepe_response);

        set_contract_address(PragmaUtils::admin());

        pragma.add_yang(PEPE_USD_PAIR_ID, pepe_token_addr());
    }

    //
    // Tests - Functionality
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_update_prices_pass() {
        let (shrine, pragma, _, mock_pragma, yangs, gates) = PragmaUtils::pragma_with_yangs();

        let eth_addr = *yangs.at(0);
        let wbtc_addr = *yangs.at(1);

        let eth_gate = *gates.at(0);
        let wbtc_gate = *gates.at(1);

        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };

        // Perform a price update with starting exchange rate of 1 yang to 1 asset
        let first_ts = get_block_timestamp() + 1;
        PragmaUtils::mock_valid_price_update(
            mock_pragma, PragmaUtils::ETH_USD_PAIR_ID, PragmaUtils::ETH_INIT_PRICE, first_ts
        );
        PragmaUtils::mock_valid_price_update(
            mock_pragma, PragmaUtils::WBTC_USD_PAIR_ID, PragmaUtils::WBTC_INIT_PRICE, first_ts
        );

        pragma_oracle.update_prices();

        let (eth_price, _, _) = shrine.get_current_yang_price(eth_addr);
        assert(eth_price == (PragmaUtils::ETH_INIT_PRICE * WAD_SCALE).into(), 'wrong ETH price');

        let (wbtc_price, _, _) = shrine.get_current_yang_price(wbtc_addr);
        assert(wbtc_price == (PragmaUtils::WBTC_INIT_PRICE * WAD_SCALE).into(), 'wrong WBTC price');

        let gate_eth_bal: u128 = eth_gate.get_total_assets();
        let gate_wbtc_bal: u128 = wbtc_gate.get_total_assets();
        let rebase_multiplier: u128 = 2;

        IMintableDispatcher {
            contract_address: eth_addr
        }.mint(eth_gate.contract_address, gate_eth_bal.into());
        IMintableDispatcher {
            contract_address: wbtc_addr
        }.mint(wbtc_gate.contract_address, gate_wbtc_bal.into());

        let next_ts = first_ts + Shrine::TIME_INTERVAL;
        set_block_timestamp(next_ts);
        let new_eth_price = PragmaUtils::ETH_INIT_PRICE + 10;
        PragmaUtils::mock_valid_price_update(
            mock_pragma, PragmaUtils::ETH_USD_PAIR_ID, new_eth_price, next_ts
        );
        let new_wbtc_price = PragmaUtils::WBTC_INIT_PRICE + 10;
        PragmaUtils::mock_valid_price_update(
            mock_pragma, PragmaUtils::WBTC_USD_PAIR_ID, new_wbtc_price, next_ts
        );
        pragma_oracle.update_prices();

        let (eth_price, _, _) = shrine.get_current_yang_price(eth_addr);
        assert(eth_price == (new_eth_price * 2 * WAD_SCALE).into(), 'wrong rebased ETH price');

        let (wbtc_price, _, _) = shrine.get_current_yang_price(wbtc_addr);
        assert(wbtc_price == (new_wbtc_price * 2 * WAD_SCALE).into(), 'wrong rebased WBTC price');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_update_prices_pass_without_yangs() {
        // just to test the module works well even if no yangs were added yet
        let (_, pragma, _, _) = PragmaUtils::pragma_deploy();

        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        pragma_oracle.update_prices();
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Too soon to update prices', 'ENTRYPOINT_FAILED'))]
    fn test_update_prices_too_soon_fail() {
        let (_, pragma, _, mock_pragma, _, _) = PragmaUtils::pragma_with_yangs();
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };

        let mut new_ts: u64 = get_block_timestamp() + 1;
        let mut price: u128 = PragmaUtils::ETH_INIT_PRICE + 10;
        set_block_timestamp(new_ts);
        PragmaUtils::mock_valid_price_update(
            mock_pragma, PragmaUtils::ETH_USD_PAIR_ID, price, new_ts
        );
        pragma_oracle.update_prices();

        price += 10;
        new_ts += Pragma::LOWER_UPDATE_FREQUENCY_BOUND - 1;
        set_block_timestamp(new_ts);
        PragmaUtils::mock_valid_price_update(
            mock_pragma, PragmaUtils::ETH_USD_PAIR_ID, price, new_ts
        );
        pragma_oracle.update_prices();
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_update_prices_insufficient_sources_unchanged() {
        let (shrine, pragma, _, mock_pragma, yangs, _) = PragmaUtils::pragma_with_yangs();
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };

        let eth_token_addr = *yangs.at(0);
        let wbtc_token_addr = *yangs.at(1);

        let (before_eth_price, _, _) = shrine.get_current_yang_price(eth_token_addr);
        let (before_wbtc_price, _, _) = shrine.get_current_yang_price(wbtc_token_addr);

        let pragma_price_scale: u128 = pow10(PragmaUtils::PRAGMA_DECIMALS);

        let price: u128 = PragmaUtils::ETH_INIT_PRICE * pragma_price_scale;
        let invalid_num_sources: u64 = Pragma::LOWER_SOURCES_BOUND - 1;
        let current_ts: u64 = get_block_timestamp();
        let mut eth_response = PricesResponse {
            price: price.into(),
            decimals: PragmaUtils::PRAGMA_DECIMALS.into(),
            last_updated_timestamp: current_ts.into(),
            num_sources_aggregated: invalid_num_sources.into(),
        };
        mock_pragma.next_get_data_median(PragmaUtils::ETH_USD_PAIR_ID, eth_response);

        let price: u128 = PragmaUtils::WBTC_INIT_PRICE * pragma_price_scale;
        let mut wbtc_response = PricesResponse {
            price: price.into(),
            decimals: PragmaUtils::PRAGMA_DECIMALS.into(),
            last_updated_timestamp: current_ts.into(),
            num_sources_aggregated: invalid_num_sources.into(),
        };
        mock_pragma.next_get_data_median(PragmaUtils::WBTC_USD_PAIR_ID, wbtc_response);

        pragma_oracle.update_prices();

        let (after_eth_price, _, _) = shrine.get_current_yang_price(eth_token_addr);
        assert(before_eth_price == after_eth_price, 'price should not be updated #1');
        let (after_wbtc_price, _, _) = shrine.get_current_yang_price(wbtc_token_addr);
        assert(before_wbtc_price == after_wbtc_price, 'price should not be updated #2');

        assert(!pragma.probe_task(), 'should not be ready');

        // TODO: check that `PricesUpdated` event is not emitted
    }

    // TODO: This can only be completed when we are able to test if an event is emitted
    #[ignore]
    #[test]
    #[available_gas(20000000000)]
    fn test_update_prices_invalid_gate_fail() {}

    #[test]
    #[available_gas(20000000000)]
    fn test_probe_task() {
        let (_, pragma, _, mock_pragma, _, _) = PragmaUtils::pragma_with_yangs();
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };

        // last price update should be 0 initially
        assert(pragma.probe_task(), 'should be ready');

        let new_ts: u64 = get_block_timestamp() + 1;
        set_block_timestamp(new_ts);
        PragmaUtils::mock_valid_price_update(
            mock_pragma, PragmaUtils::ETH_USD_PAIR_ID, PragmaUtils::ETH_INIT_PRICE + 10, new_ts
        );
        pragma_oracle.update_prices();

        // after update_prices, the last update ts is moved to current block ts
        // as well, so calling probe_task in the same block afterwards should
        // return false
        assert(!pragma.probe_task(), 'should not be ready');

        // moving the block time forward to the next time interval, 
        // probe_task should again return true
        set_block_timestamp(new_ts + Shrine::TIME_INTERVAL);
        assert(pragma.probe_task(), 'should be ready');
    }
}
