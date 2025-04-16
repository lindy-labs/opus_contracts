mod test_pragma {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::num::traits::Zero;
    use core::result::ResultTrait;
    use opus::constants::{ETH_USD_PAIR_ID, PRAGMA_DECIMALS};
    use opus::core::shrine::shrine;
    use opus::external::pragma::pragma as pragma_contract;
    use opus::external::roles::pragma_roles;
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::IPragma::IPragmaDispatcherTrait;
    use opus::mock::mock_pragma::IMockPragmaDispatcherTrait;
    use opus::tests::common;
    use opus::tests::external::utils::{
        mock_eth_token_addr, pepe_token_addr, pragma_utils, pragma_utils::PragmaTestConfig,
    };
    use opus::tests::seer::utils::seer_utils;
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::types::pragma::{AggregationMode, PairSettings, PragmaPricesResponse, PriceValidityThresholds};
    use opus::utils::math::pow;
    use snforge_std::{
        EventSpyAssertionsTrait, spy_events, start_cheat_block_timestamp_global, start_cheat_caller_address,
        stop_cheat_caller_address,
    };
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::{WAD_DECIMALS, WAD_SCALE, Wad};

    const TS: u64 = 1700000000; // arbitrary timestamp

    //
    // Tests - Deployment and setters
    //

    #[test]
    fn test_pragma_setup() {
        let mut spy = spy_events();
        let PragmaTestConfig { pragma, mock_pragma } = pragma_utils::pragma_deploy(Option::None, Option::None);

        // Check permissions
        let pragma_ac = IAccessControlDispatcher { contract_address: pragma.contract_address };
        let admin: ContractAddress = pragma_utils::admin();

        assert(pragma_ac.get_admin() == admin, 'wrong admin');
        assert(pragma_ac.get_roles(admin) == pragma_roles::default_admin_role(), 'wrong admin role');

        let oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        assert(oracle.get_name() == 'Pragma', 'wrong name');
        let oracles: Span<ContractAddress> = array![mock_pragma.contract_address, mock_pragma.contract_address].span();
        assert(oracle.get_oracles() == oracles, 'wrong oracle addresses');

        let expected_events = array![
            (
                pragma.contract_address,
                pragma_contract::Event::PriceValidityThresholdsUpdated(
                    pragma_contract::PriceValidityThresholdsUpdated {
                        old_thresholds: PriceValidityThresholds { freshness: 0, sources: 0 },
                        new_thresholds: PriceValidityThresholds {
                            freshness: pragma_utils::FRESHNESS_THRESHOLD, sources: pragma_utils::SOURCES_THRESHOLD,
                        },
                    },
                ),
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_set_price_validity_thresholds_pass() {
        let PragmaTestConfig { pragma, .. } = pragma_utils::pragma_deploy(Option::None, Option::None);
        let mut spy = spy_events();

        let new_freshness: u64 = 5 * 60; // 5 minutes * 60 seconds
        let new_sources: u32 = 8;

        start_cheat_caller_address(pragma.contract_address, pragma_utils::admin());
        pragma.set_price_validity_thresholds(new_freshness, new_sources);

        let expected_events = array![
            (
                pragma.contract_address,
                pragma_contract::Event::PriceValidityThresholdsUpdated(
                    pragma_contract::PriceValidityThresholdsUpdated {
                        old_thresholds: PriceValidityThresholds {
                            freshness: pragma_utils::FRESHNESS_THRESHOLD, sources: pragma_utils::SOURCES_THRESHOLD,
                        },
                        new_thresholds: PriceValidityThresholds { freshness: new_freshness, sources: new_sources },
                    },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: 'PGM: Freshness out of bounds')]
    fn test_set_price_validity_threshold_freshness_too_low_fail() {
        let PragmaTestConfig { pragma, .. } = pragma_utils::pragma_deploy(Option::None, Option::None);

        let invalid_freshness: u64 = pragma_contract::LOWER_FRESHNESS_BOUND - 1;
        let valid_sources: u32 = pragma_utils::SOURCES_THRESHOLD;

        start_cheat_caller_address(pragma.contract_address, pragma_utils::admin());
        pragma.set_price_validity_thresholds(invalid_freshness, valid_sources);
    }

    #[test]
    #[should_panic(expected: 'PGM: Freshness out of bounds')]
    fn test_set_price_validity_threshold_freshness_too_high_fail() {
        let PragmaTestConfig { pragma, .. } = pragma_utils::pragma_deploy(Option::None, Option::None);

        let invalid_freshness: u64 = pragma_contract::UPPER_FRESHNESS_BOUND + 1;
        let valid_sources: u32 = pragma_utils::SOURCES_THRESHOLD;

        start_cheat_caller_address(pragma.contract_address, pragma_utils::admin());
        pragma.set_price_validity_thresholds(invalid_freshness, valid_sources);
    }

    #[test]
    #[should_panic(expected: 'PGM: Sources out of bounds')]
    fn test_set_price_validity_threshold_sources_too_low_fail() {
        let PragmaTestConfig { pragma, .. } = pragma_utils::pragma_deploy(Option::None, Option::None);

        let valid_freshness: u64 = pragma_utils::FRESHNESS_THRESHOLD;
        let invalid_sources: u32 = pragma_contract::LOWER_SOURCES_BOUND - 1;

        start_cheat_caller_address(pragma.contract_address, pragma_utils::admin());
        pragma.set_price_validity_thresholds(valid_freshness, invalid_sources);
    }

    #[test]
    #[should_panic(expected: 'PGM: Sources out of bounds')]
    fn test_set_price_validity_threshold_sources_too_high_fail() {
        let PragmaTestConfig { pragma, .. } = pragma_utils::pragma_deploy(Option::None, Option::None);

        let valid_freshness: u64 = pragma_utils::FRESHNESS_THRESHOLD;
        let invalid_sources: u32 = pragma_contract::UPPER_SOURCES_BOUND + 1;

        start_cheat_caller_address(pragma.contract_address, pragma_utils::admin());
        pragma.set_price_validity_thresholds(valid_freshness, invalid_sources);
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_set_price_validity_threshold_unauthorized_fail() {
        let PragmaTestConfig { pragma, .. } = pragma_utils::pragma_deploy(Option::None, Option::None);

        let valid_freshness: u64 = pragma_utils::FRESHNESS_THRESHOLD;
        let valid_sources: u32 = pragma_utils::SOURCES_THRESHOLD;

        start_cheat_caller_address(pragma.contract_address, common::badguy());
        pragma.set_price_validity_thresholds(valid_freshness, valid_sources);
    }

    #[test]
    fn test_set_yang_pair_settings_pass() {
        let PragmaTestConfig { pragma, mock_pragma } = pragma_utils::pragma_deploy(Option::None, Option::None);
        let mut spy = spy_events();

        // PEPE token is not added to sentinel, just needs to be deployed for the test to work
        let pepe_token: ContractAddress = common::deploy_token(
            'Pepe', 'PEPE', 18, 0.into(), common::non_zero_address(), Option::None,
        );
        let pepe_token_pair_id: felt252 = pragma_utils::PEPE_USD_PAIR_ID;
        let price: u128 = 999 * pow(10_u128, PRAGMA_DECIMALS);
        let current_ts: u64 = get_block_timestamp();
        // Seed first price update for PEPE token so that `Pragma.set_yang_pair_settings` passes
        pragma_utils::mock_valid_price_update(mock_pragma, pepe_token, price.into(), current_ts);

        let pair_settings = PairSettings { pair_id: pepe_token_pair_id, aggregation_mode: AggregationMode::Median };

        start_cheat_block_timestamp_global(TS);
        start_cheat_caller_address(pragma.contract_address, pragma_utils::admin());
        pragma.set_yang_pair_settings(pepe_token, pair_settings);
        stop_cheat_caller_address(pragma.contract_address);
        let expected_events = array![
            (
                pragma.contract_address,
                pragma_contract::Event::YangPairSettingsUpdated(
                    pragma_contract::YangPairSettingsUpdated { address: pepe_token, pair_settings },
                ),
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_set_yang_pair_settings_overwrite_pass() {
        let PragmaTestConfig { pragma, mock_pragma } = pragma_utils::pragma_deploy(Option::None, Option::None);
        let mut spy = spy_events();
        start_cheat_block_timestamp_global(TS);

        // PEPE token is not added to sentinel, just needs to be deployed for the test to work
        let pepe_token: ContractAddress = common::deploy_token(
            'Pepe', 'PEPE', 18, 0.into(), common::non_zero_address(), Option::None,
        );
        let pepe_token_pair_id: felt252 = pragma_utils::PEPE_USD_PAIR_ID;
        let pair_settings = PairSettings { pair_id: pepe_token_pair_id, aggregation_mode: AggregationMode::Median };

        let price: u128 = 999 * pow(10_u128, PRAGMA_DECIMALS);
        let current_ts: u64 = get_block_timestamp();
        // Seed first price update for PEPE token so that `Pragma.set_yang_pair_settings` passes
        pragma_utils::mock_valid_price_update(mock_pragma, pepe_token, price.into(), current_ts);

        start_cheat_caller_address(pragma.contract_address, pragma_utils::admin());
        pragma.set_yang_pair_settings(pepe_token, pair_settings);

        // fake data for a second set_yang_pair_settings, so its distinct from the first call
        let pepe_token_pair_id_2: felt252 = 'WILDPEPE/USD';
        let new_pair_settings = PairSettings {
            pair_id: pepe_token_pair_id_2, aggregation_mode: AggregationMode::Median,
        };

        let response = PragmaPricesResponse {
            price: price,
            decimals: PRAGMA_DECIMALS.into(),
            last_updated_timestamp: current_ts + 100,
            num_sources_aggregated: pragma_utils::DEFAULT_NUM_SOURCES,
            expiration_timestamp: Option::None,
        };
        mock_pragma.next_get_data(pepe_token_pair_id_2, response);
        let twap_response: (u128, u32) = (price, PRAGMA_DECIMALS.into());
        mock_pragma.next_calculate_twap(pepe_token_pair_id_2, twap_response);

        pragma.set_yang_pair_settings(pepe_token, new_pair_settings);
        let expected_events = array![
            (
                pragma.contract_address,
                pragma_contract::Event::YangPairSettingsUpdated(
                    pragma_contract::YangPairSettingsUpdated { address: pepe_token, pair_settings },
                ),
            ),
            (
                pragma.contract_address,
                pragma_contract::Event::YangPairSettingsUpdated(
                    pragma_contract::YangPairSettingsUpdated { address: pepe_token, pair_settings: new_pair_settings },
                ),
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_set_yang_pair_settings_unauthorized_fail() {
        let PragmaTestConfig { pragma, .. } = pragma_utils::pragma_deploy(Option::None, Option::None);
        let pair_settings = PairSettings { pair_id: ETH_USD_PAIR_ID, aggregation_mode: AggregationMode::Median };
        start_cheat_caller_address(pragma.contract_address, common::badguy());
        pragma.set_yang_pair_settings(mock_eth_token_addr(), pair_settings);
    }

    #[test]
    #[should_panic(expected: 'PGM: Invalid pair ID')]
    fn test_set_yang_pair_settings_invalid_pair_id_fail() {
        let PragmaTestConfig { pragma, .. } = pragma_utils::pragma_deploy(Option::None, Option::None);
        start_cheat_caller_address(pragma.contract_address, pragma_utils::admin());
        let invalid_pair_id = 0;
        let pair_settings = PairSettings { pair_id: invalid_pair_id, aggregation_mode: AggregationMode::Median };
        pragma.set_yang_pair_settings(mock_eth_token_addr(), pair_settings);
    }

    #[test]
    #[should_panic(expected: 'PGM: Invalid yang address')]
    fn test_set_yang_pair_settings_invalid_yang_address_fail() {
        let PragmaTestConfig { pragma, .. } = pragma_utils::pragma_deploy(Option::None, Option::None);
        start_cheat_caller_address(pragma.contract_address, pragma_utils::admin());
        let invalid_yang_addr = Zero::zero();
        let pair_settings = PairSettings { pair_id: ETH_USD_PAIR_ID, aggregation_mode: AggregationMode::Median };
        pragma.set_yang_pair_settings(invalid_yang_addr, pair_settings);
    }

    #[test]
    #[should_panic(expected: 'PGM: Spot unknown pair ID')]
    fn test_set_yang_pair_settings_unknown_spot_pair_id_fail() {
        let PragmaTestConfig { pragma, .. } = pragma_utils::pragma_deploy(Option::None, Option::None);
        let pair_settings = PairSettings {
            pair_id: pragma_utils::PEPE_USD_PAIR_ID, aggregation_mode: AggregationMode::Median,
        };
        start_cheat_caller_address(pragma.contract_address, pragma_utils::admin());
        pragma.set_yang_pair_settings(pepe_token_addr(), pair_settings);
    }

    #[test]
    #[should_panic(expected: 'PGM: TWAP unknown pair ID')]
    fn test_set_yang_pair_settings_unknown_twap_pair_id_fail() {
        let PragmaTestConfig { pragma, mock_pragma } = pragma_utils::pragma_deploy(Option::None, Option::None);
        let pepe_spot_response = PragmaPricesResponse {
            price: 1000,
            decimals: PRAGMA_DECIMALS.into(),
            last_updated_timestamp: TS,
            num_sources_aggregated: pragma_utils::DEFAULT_NUM_SOURCES,
            expiration_timestamp: Option::None,
        };
        mock_pragma.next_get_data(pragma_utils::PEPE_USD_PAIR_ID, pepe_spot_response);

        let pair_settings = PairSettings {
            pair_id: pragma_utils::PEPE_USD_PAIR_ID, aggregation_mode: AggregationMode::Median,
        };

        start_cheat_caller_address(pragma.contract_address, pragma_utils::admin());
        start_cheat_block_timestamp_global(TS);
        pragma.set_yang_pair_settings(pepe_token_addr(), pair_settings);
    }

    #[test]
    #[should_panic(expected: 'PGM: Spot too many decimals')]
    fn test_set_yang_pair_settings_spot_too_many_decimals_fail() {
        let PragmaTestConfig { pragma, mock_pragma } = pragma_utils::pragma_deploy(Option::None, Option::None);

        let pragma_price_scale: u128 = pow(10_u128, PRAGMA_DECIMALS);

        let pepe_price: u128 = 1000000 * pragma_price_scale; // random price
        let invalid_decimals: u32 = (WAD_DECIMALS + 1).into();
        let pepe_response = PragmaPricesResponse {
            price: pepe_price,
            decimals: invalid_decimals,
            last_updated_timestamp: 10000000,
            num_sources_aggregated: pragma_utils::DEFAULT_NUM_SOURCES,
            expiration_timestamp: Option::None,
        };
        mock_pragma.next_get_data(pragma_utils::PEPE_USD_PAIR_ID, pepe_response);

        let pair_settings = PairSettings {
            pair_id: pragma_utils::PEPE_USD_PAIR_ID, aggregation_mode: AggregationMode::Median,
        };

        start_cheat_caller_address(pragma.contract_address, pragma_utils::admin());
        pragma.set_yang_pair_settings(pepe_token_addr(), pair_settings);
    }

    #[test]
    #[should_panic(expected: 'PGM: TWAP too many decimals')]
    fn test_set_yang_pair_settings_twap_too_many_decimals_fail() {
        let PragmaTestConfig { pragma, mock_pragma } = pragma_utils::pragma_deploy(Option::None, Option::None);

        let pragma_price_scale: u128 = pow(10_u128, PRAGMA_DECIMALS);

        let pepe_price: u128 = 1000000 * pragma_price_scale; // random price
        let pepe_spot_response = PragmaPricesResponse {
            price: pepe_price,
            decimals: PRAGMA_DECIMALS.into(),
            last_updated_timestamp: 10000000,
            num_sources_aggregated: pragma_utils::DEFAULT_NUM_SOURCES,
            expiration_timestamp: Option::None,
        };
        mock_pragma.next_get_data(pragma_utils::PEPE_USD_PAIR_ID, pepe_spot_response);

        let pepe_twap_response: (u128, u32) = (pepe_price, 20);
        mock_pragma.next_calculate_twap(pragma_utils::PEPE_USD_PAIR_ID, pepe_twap_response);

        let pair_settings = PairSettings {
            pair_id: pragma_utils::PEPE_USD_PAIR_ID, aggregation_mode: AggregationMode::Median,
        };

        start_cheat_caller_address(pragma.contract_address, pragma_utils::admin());
        start_cheat_block_timestamp_global(TS);
        pragma.set_yang_pair_settings(pepe_token_addr(), pair_settings);
    }


    //
    // Tests - Functionality
    //

    #[test]
    fn test_fetch_price_pass() {
        let PragmaTestConfig { pragma, mock_pragma } = pragma_utils::pragma_deploy(Option::None, Option::None);
        let sentinel_utils::SentinelTestConfig { yangs, .. } = sentinel_utils::deploy_sentinel_with_gates(Option::None);
        pragma_utils::add_yangs(pragma.contract_address, yangs);

        let eth_addr = *yangs.at(0);
        let wbtc_addr = *yangs.at(1);

        // Perform a price update with starting exchange rate of 1 yang to 1 asset
        let first_ts = get_block_timestamp() + 1;
        start_cheat_block_timestamp_global(first_ts);

        let mut eth_price: Wad = seer_utils::ETH_INIT_PRICE.into();
        pragma_utils::mock_valid_price_update(mock_pragma, eth_addr, eth_price, first_ts);

        let mut wbtc_price: Wad = seer_utils::WBTC_INIT_PRICE.into();
        pragma_utils::mock_valid_price_update(mock_pragma, wbtc_addr, wbtc_price, first_ts);

        start_cheat_caller_address(pragma.contract_address, common::non_zero_address());
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr);
        let fetched_wbtc: Result<Wad, felt252> = pragma_oracle.fetch_price(wbtc_addr);

        assert(eth_price == fetched_eth.unwrap(), 'wrong ETH price 1');
        assert(wbtc_price == fetched_wbtc.unwrap(), 'wrong WBTC price 1');

        let next_ts = first_ts + shrine::TIME_INTERVAL;
        start_cheat_block_timestamp_global(next_ts);
        eth_price += (10 * WAD_SCALE).into();
        pragma_utils::mock_valid_price_update(mock_pragma, eth_addr, eth_price, next_ts);
        wbtc_price += (10 * WAD_SCALE).into();
        pragma_utils::mock_valid_price_update(mock_pragma, wbtc_addr, wbtc_price, next_ts);
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr);
        let fetched_wbtc: Result<Wad, felt252> = pragma_oracle.fetch_price(wbtc_addr);

        assert(eth_price == fetched_eth.unwrap(), 'wrong ETH price 2');
        assert(wbtc_price == fetched_wbtc.unwrap(), 'wrong WBTC price 2');
    }

    #[test]
    fn test_fetch_price_return_min_spot() {
        let PragmaTestConfig { pragma, mock_pragma } = pragma_utils::pragma_deploy(Option::None, Option::None);
        let sentinel_utils::SentinelTestConfig { yangs, .. } = sentinel_utils::deploy_sentinel_with_gates(Option::None);
        pragma_utils::add_yangs(pragma.contract_address, yangs);

        let eth_addr = *yangs.at(0);
        // make spot price be lower than twap price
        let spot_eth_price: u128 = 1500 * WAD_SCALE;
        let twap_eth_price: u128 = 1650 * WAD_SCALE;
        mock_pragma
            .next_get_data(
                ETH_USD_PAIR_ID,
                PragmaPricesResponse {
                    price: spot_eth_price,
                    decimals: WAD_DECIMALS.into(),
                    last_updated_timestamp: TS,
                    num_sources_aggregated: pragma_utils::DEFAULT_NUM_SOURCES,
                    expiration_timestamp: Option::None,
                },
            );
        mock_pragma.next_calculate_twap(ETH_USD_PAIR_ID, (twap_eth_price, WAD_DECIMALS.into()));

        start_cheat_caller_address(pragma.contract_address, common::non_zero_address());
        start_cheat_block_timestamp_global(TS);

        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr);

        assert(fetched_eth.unwrap() == spot_eth_price.into(), 'wrong ETH price');
    }

    #[test]
    fn test_fetch_price_return_min_twap() {
        let PragmaTestConfig { pragma, mock_pragma } = pragma_utils::pragma_deploy(Option::None, Option::None);
        let sentinel_utils::SentinelTestConfig { yangs, .. } = sentinel_utils::deploy_sentinel_with_gates(Option::None);
        pragma_utils::add_yangs(pragma.contract_address, yangs);

        let eth_addr = *yangs.at(0);
        // make twap price be lower than twap price
        let spot_eth_price: u128 = 1700 * WAD_SCALE;
        let twap_eth_price: u128 = 1650 * WAD_SCALE;
        mock_pragma
            .next_get_data(
                ETH_USD_PAIR_ID,
                PragmaPricesResponse {
                    price: spot_eth_price,
                    decimals: WAD_DECIMALS.into(),
                    last_updated_timestamp: TS,
                    num_sources_aggregated: pragma_utils::DEFAULT_NUM_SOURCES,
                    expiration_timestamp: Option::None,
                },
            );
        mock_pragma.next_calculate_twap(ETH_USD_PAIR_ID, (twap_eth_price, WAD_DECIMALS.into()));

        start_cheat_caller_address(pragma.contract_address, common::non_zero_address());
        start_cheat_block_timestamp_global(TS);

        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr);

        assert(fetched_eth.unwrap() == twap_eth_price.into(), 'wrong ETH price');
    }


    #[test]
    fn test_fetch_price_too_soon() {
        let PragmaTestConfig { pragma, mock_pragma } = pragma_utils::pragma_deploy(Option::None, Option::None);
        let mut spy = spy_events();

        let sentinel_utils::SentinelTestConfig { yangs, .. } = sentinel_utils::deploy_sentinel_with_gates(Option::None);
        pragma_utils::add_yangs(pragma.contract_address, yangs);

        let eth_addr = *yangs.at(0);
        let now: u64 = 100000000;
        start_cheat_block_timestamp_global(now);

        let eth_price: Wad = seer_utils::ETH_INIT_PRICE.into();
        pragma_utils::mock_valid_price_update(mock_pragma, eth_addr, eth_price, now);

        start_cheat_caller_address(pragma.contract_address, common::non_zero_address());
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr);

        // check if first fetch works, advance block time to be out of freshness range
        // and check if there's a error and if an event was emitted
        assert(eth_price == fetched_eth.unwrap(), 'wrong ETH price 1');
        start_cheat_block_timestamp_global(now + pragma_utils::FRESHNESS_THRESHOLD + 1);
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr);
        assert(fetched_eth.unwrap_err() == 'PGM: Invalid price update', 'wrong result');

        let expected_events = array![
            (
                pragma.contract_address,
                pragma_contract::Event::InvalidSpotPriceUpdate(
                    pragma_contract::InvalidSpotPriceUpdate {
                        pair_id: ETH_USD_PAIR_ID,
                        aggregation_mode: AggregationMode::Median,
                        price: eth_price,
                        pragma_last_updated_ts: now,
                        pragma_num_sources: pragma_utils::DEFAULT_NUM_SOURCES,
                    },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_fetch_price_insufficient_sources() {
        let PragmaTestConfig { pragma, mock_pragma } = pragma_utils::pragma_deploy(Option::None, Option::None);
        let mut spy = spy_events();

        let sentinel_utils::SentinelTestConfig { yangs, .. } = sentinel_utils::deploy_sentinel_with_gates(Option::None);
        pragma_utils::add_yangs(pragma.contract_address, yangs);

        let eth_addr = *yangs.at(0);
        let now: u64 = 100000000;
        start_cheat_block_timestamp_global(now);

        let eth_price: Wad = seer_utils::ETH_INIT_PRICE.into();

        // prepare the response from mock oracle in such a way
        // that it has less than the required number of sources
        let num_sources: u32 = pragma_utils::SOURCES_THRESHOLD - 1;
        mock_pragma
            .next_get_data(
                pragma_utils::get_pair_id_for_yang(eth_addr),
                PragmaPricesResponse {
                    price: pragma_utils::convert_price_to_pragma_scale(eth_price),
                    decimals: PRAGMA_DECIMALS.into(),
                    last_updated_timestamp: now,
                    num_sources_aggregated: num_sources,
                    expiration_timestamp: Option::None,
                },
            );

        start_cheat_caller_address(pragma.contract_address, common::non_zero_address());
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr);

        assert(fetched_eth.unwrap_err() == 'PGM: Invalid price update', 'wrong result');

        let expected_events = array![
            (
                pragma.contract_address,
                pragma_contract::Event::InvalidSpotPriceUpdate(
                    pragma_contract::InvalidSpotPriceUpdate {
                        pair_id: ETH_USD_PAIR_ID,
                        aggregation_mode: AggregationMode::Median,
                        price: eth_price,
                        pragma_last_updated_ts: now,
                        pragma_num_sources: num_sources,
                    },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }
}
