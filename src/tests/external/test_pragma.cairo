mod test_pragma {
    use debug::PrintTrait;
    use integer::U256Zeroable;
    use opus::core::roles::pragma_roles;
    use opus::core::shrine::shrine;
    use opus::external::pragma::pragma as pragma_contract;
    use opus::interfaces::IERC20::{IMintableDispatcher, IMintableDispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::IPragma::{IPragmaDispatcher, IPragmaDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::external::{IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait};
    use opus::tests::common;
    use opus::tests::external::mock_pragma::{IMockPragmaDispatcher, IMockPragmaDispatcherTrait};
    use opus::tests::external::utils::pragma_utils;
    use opus::tests::seer::utils::seer_utils;
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::types::pragma::{PricesResponse, PriceValidityThresholds};
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::utils::math::pow;
    use opus::utils::wadray::{Wad, WadZeroable, WAD_DECIMALS, WAD_ONE, WAD_SCALE};
    use opus::utils::wadray;
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};
    use starknet::{ContractAddress, contract_address_try_from_felt252, get_block_timestamp};

    //
    // Address constants
    //

    // TODO: this is not inlined as it would result in `Unknown ap change` error
    //       for `test_update_prices_invalid_gate`
    fn pepe_token_addr() -> ContractAddress {
        contract_address_try_from_felt252('PEPE').unwrap()
    }

    fn mock_eth_token_addr() -> ContractAddress {
        contract_address_try_from_felt252('ETH').unwrap()
    }

    //
    // Tests - Deployment and setters
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_pragma_setup() {
        let (pragma, mock_pragma) = pragma_utils::pragma_deploy();

        // Check permissions
        let pragma_ac = IAccessControlDispatcher { contract_address: pragma.contract_address };
        let admin: ContractAddress = pragma_utils::admin();

        assert(pragma_ac.get_admin() == admin, 'wrong admin');
        assert(
            pragma_ac.get_roles(admin) == pragma_roles::default_admin_role(), 'wrong admin role'
        );

        let oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        assert(oracle.get_name() == 'Pragma', 'wrong name');
        assert(oracle.get_oracle() == mock_pragma.contract_address, 'wrong oracle address');

        let mut expected_events: Span<pragma_contract::Event> = array![
            pragma_contract::Event::PriceValidityThresholdsUpdated(
                pragma_contract::PriceValidityThresholdsUpdated {
                    old_thresholds: PriceValidityThresholds { freshness: 0, sources: 0 },
                    new_thresholds: PriceValidityThresholds {
                        freshness: pragma_utils::FRESHNESS_THRESHOLD,
                        sources: pragma_utils::SOURCES_THRESHOLD
                    },
                }
            ),
        ]
            .span();
        common::assert_events_emitted(pragma.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_price_validity_thresholds_pass() {
        let (pragma, _) = pragma_utils::pragma_deploy();

        let new_freshness: u64 = consteval_int!(5 * 60); // 5 minutes * 60 seconds
        let new_sources: u64 = 8;

        set_contract_address(pragma_utils::admin());
        pragma.set_price_validity_thresholds(new_freshness, new_sources);

        let mut expected_events: Span<pragma_contract::Event> = array![
            pragma_contract::Event::PriceValidityThresholdsUpdated(
                pragma_contract::PriceValidityThresholdsUpdated {
                    old_thresholds: PriceValidityThresholds {
                        freshness: pragma_utils::FRESHNESS_THRESHOLD,
                        sources: pragma_utils::SOURCES_THRESHOLD
                    },
                    new_thresholds: PriceValidityThresholds {
                        freshness: new_freshness, sources: new_sources
                    },
                }
            ),
        ]
            .span();
        common::assert_events_emitted(pragma.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Freshness out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_freshness_too_low_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy();

        let invalid_freshness: u64 = pragma_contract::LOWER_FRESHNESS_BOUND - 1;
        let valid_sources: u64 = pragma_utils::SOURCES_THRESHOLD;

        set_contract_address(pragma_utils::admin());
        pragma.set_price_validity_thresholds(invalid_freshness, valid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Freshness out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_freshness_too_high_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy();

        let invalid_freshness: u64 = pragma_contract::UPPER_FRESHNESS_BOUND + 1;
        let valid_sources: u64 = pragma_utils::SOURCES_THRESHOLD;

        set_contract_address(pragma_utils::admin());
        pragma.set_price_validity_thresholds(invalid_freshness, valid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Sources out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_sources_too_low_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy();

        let valid_freshness: u64 = pragma_utils::FRESHNESS_THRESHOLD;
        let invalid_sources: u64 = pragma_contract::LOWER_SOURCES_BOUND - 1;

        set_contract_address(pragma_utils::admin());
        pragma.set_price_validity_thresholds(valid_freshness, invalid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Sources out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_sources_too_high_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy();

        let valid_freshness: u64 = pragma_utils::FRESHNESS_THRESHOLD;
        let invalid_sources: u64 = pragma_contract::UPPER_SOURCES_BOUND + 1;

        set_contract_address(pragma_utils::admin());
        pragma.set_price_validity_thresholds(valid_freshness, invalid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_unauthorized_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy();

        let valid_freshness: u64 = pragma_utils::FRESHNESS_THRESHOLD;
        let valid_sources: u64 = pragma_utils::SOURCES_THRESHOLD;

        set_contract_address(common::badguy());
        pragma.set_price_validity_thresholds(valid_freshness, valid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_add_yang_pass() {
        let (pragma, mock_pragma) = pragma_utils::pragma_deploy();

        // PEPE token is not added to sentinel, just needs to be deployed for the test to work
        let pepe_token: ContractAddress = common::deploy_token(
            'Pepe', 'PEPE', 18, 0.into(), common::non_zero_address()
        );
        let pepe_token_pair_id: u256 = pragma_utils::PEPE_USD_PAIR_ID;
        let price: u128 = 999 * pow(10_u128, pragma_utils::PRAGMA_DECIMALS);
        let current_ts: u64 = get_block_timestamp();
        // Seed first price update for PEPE token so that `Pragma.add_yang` passes
        pragma_utils::mock_valid_price_update(mock_pragma, pepe_token, price.into(), current_ts);

        set_contract_address(pragma_utils::admin());
        pragma.add_yang(pepe_token, pepe_token_pair_id);

        let expected_events: Span<pragma_contract::Event> = array![
            pragma_contract::Event::YangAdded(
                pragma_contract::YangAdded { address: pepe_token, pair_id: pepe_token_pair_id },
            ),
        ]
            .span();
        common::assert_events_emitted(pragma.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_add_yang_overwrite_pass() {
        let (pragma, mock_pragma) = pragma_utils::pragma_deploy();

        // PEPE token is not added to sentinel, just needs to be deployed for the test to work
        let pepe_token: ContractAddress = common::deploy_token(
            'Pepe', 'PEPE', 18, 0.into(), common::non_zero_address()
        );
        let pepe_token_pair_id: u256 = pragma_utils::PEPE_USD_PAIR_ID;
        let price: u128 = 999 * pow(10_u128, pragma_utils::PRAGMA_DECIMALS);
        let current_ts: u64 = get_block_timestamp();
        // Seed first price update for PEPE token so that `Pragma.add_yang` passes
        pragma_utils::mock_valid_price_update(mock_pragma, pepe_token, price.into(), current_ts);

        set_contract_address(pragma_utils::admin());
        pragma.add_yang(pepe_token, pepe_token_pair_id);

        // fake data for a second add yang, so its distinct from the first call
        let pepe_token_pair_id_2: u256 = 'WILDPEPE/USD'.into();
        let response = PricesResponse {
            price: price.into(),
            decimals: pragma_utils::PRAGMA_DECIMALS.into(),
            last_updated_timestamp: (current_ts + 100).into(),
            num_sources_aggregated: pragma_utils::DEFAULT_NUM_SOURCES
        };
        mock_pragma.next_get_data_median(pepe_token_pair_id_2, response);

        pragma.add_yang(pepe_token, pepe_token_pair_id_2);

        let expected_events: Span<pragma_contract::Event> = array![
            pragma_contract::Event::YangAdded(
                pragma_contract::YangAdded { address: pepe_token, pair_id: pepe_token_pair_id },
            ),
            pragma_contract::Event::YangAdded(
                pragma_contract::YangAdded { address: pepe_token, pair_id: pepe_token_pair_id_2 },
            ),
        ]
            .span();
        common::assert_events_emitted(pragma.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_unauthorized_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy();
        set_contract_address(common::badguy());
        pragma.add_yang(mock_eth_token_addr(), pragma_utils::ETH_USD_PAIR_ID);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Invalid pair ID', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_invalid_pair_id_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy();
        set_contract_address(pragma_utils::admin());
        let invalid_pair_id = U256Zeroable::zero();
        pragma.add_yang(mock_eth_token_addr(), invalid_pair_id);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Invalid yang address', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_invalid_yang_address_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy();
        set_contract_address(pragma_utils::admin());
        let invalid_yang_addr = ContractAddressZeroable::zero();
        pragma.add_yang(invalid_yang_addr, pragma_utils::ETH_USD_PAIR_ID);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Unknown pair ID', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_unknown_pair_id_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy();
        set_contract_address(pragma_utils::admin());
        pragma.add_yang(pepe_token_addr(), pragma_utils::PEPE_USD_PAIR_ID);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Too many decimals', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_too_many_decimals_fail() {
        let (pragma, mock_pragma) = pragma_utils::pragma_deploy();

        let pragma_price_scale: u128 = pow(10_u128, pragma_utils::PRAGMA_DECIMALS);

        let pepe_price: u128 = 1000000 * pragma_price_scale; // random price
        let invalid_decimals: u256 = (WAD_DECIMALS + 1).into();
        let pepe_response = PricesResponse {
            price: pepe_price.into(),
            decimals: invalid_decimals,
            last_updated_timestamp: 10000000,
            num_sources_aggregated: pragma_utils::DEFAULT_NUM_SOURCES,
        };
        mock_pragma.next_get_data_median(pragma_utils::PEPE_USD_PAIR_ID, pepe_response);

        set_contract_address(pragma_utils::admin());
        pragma.add_yang(pepe_token_addr(), pragma_utils::PEPE_USD_PAIR_ID);
    }

    //
    // Tests - Functionality
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_fetch_price_pass() {
        let (pragma, mock_pragma) = pragma_utils::pragma_deploy();
        let (_sentinel, _shrine, yangs, _gates) = sentinel_utils::deploy_sentinel_with_gates(Option::None);
        pragma_utils::add_yangs_to_pragma(pragma, yangs);

        let eth_addr = *yangs.at(0);
        let wbtc_addr = *yangs.at(1);

        // Perform a price update with starting exchange rate of 1 yang to 1 asset
        let first_ts = get_block_timestamp() + 1;
        set_block_timestamp(first_ts);
        let mut eth_price: Wad = seer_utils::ETH_INIT_PRICE.into();
        pragma_utils::mock_valid_price_update(mock_pragma, eth_addr, eth_price, first_ts);

        let mut wbtc_price: Wad = seer_utils::WBTC_INIT_PRICE.into();
        pragma_utils::mock_valid_price_update(mock_pragma, wbtc_addr, wbtc_price.into(), first_ts);

        set_contract_address(common::non_zero_address());
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr, false);
        let fetched_wbtc: Result<Wad, felt252> = pragma_oracle.fetch_price(wbtc_addr, false);

        assert(eth_price == fetched_eth.unwrap(), 'wrong ETH price 1');
        assert(wbtc_price == fetched_wbtc.unwrap(), 'wrong WBTC price 1');

        let next_ts = first_ts + shrine::TIME_INTERVAL;
        set_block_timestamp(next_ts);
        eth_price += (10 * WAD_SCALE).into();
        pragma_utils::mock_valid_price_update(mock_pragma, eth_addr, eth_price, next_ts);
        wbtc_price += (10 * WAD_SCALE).into();
        pragma_utils::mock_valid_price_update(mock_pragma, wbtc_addr, wbtc_price, next_ts);
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr, false);
        let fetched_wbtc: Result<Wad, felt252> = pragma_oracle.fetch_price(wbtc_addr, false);

        assert(eth_price == fetched_eth.unwrap(), 'wrong ETH price 2');
        assert(wbtc_price == fetched_wbtc.unwrap(), 'wrong WBTC price 2');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_fetch_price_too_soon() {
        let (pragma, mock_pragma) = pragma_utils::pragma_deploy();
        let (_sentinel, _shrine, yangs, _gates) = sentinel_utils::deploy_sentinel_with_gates(Option::None);
        pragma_utils::add_yangs_to_pragma(pragma, yangs);

        let eth_addr = *yangs.at(0);
        let now: u64 = 100000000;
        set_block_timestamp(now);

        let eth_price: Wad = seer_utils::ETH_INIT_PRICE.into();
        pragma_utils::mock_valid_price_update(mock_pragma, eth_addr, eth_price, now);

        set_contract_address(common::non_zero_address());
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr, false);

        // check if first fetch works, advance block time to be out of freshness range
        // and check if there's a error and if an event was emitted
        assert(eth_price == fetched_eth.unwrap(), 'wrong ETH price 1');
        set_block_timestamp(now + pragma_utils::FRESHNESS_THRESHOLD + 1);
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr, false);
        assert(fetched_eth.unwrap_err() == 'PGM: Invalid price update', 'wrong result');

        let mut expected_events: Span<pragma_contract::Event> = array![
            pragma_contract::Event::InvalidPriceUpdate(
                pragma_contract::InvalidPriceUpdate {
                    yang: eth_addr,
                    price: eth_price,
                    pragma_last_updated_ts: now.into(),
                    pragma_num_sources: pragma_utils::DEFAULT_NUM_SOURCES.into(),
                }
            ),
        ]
            .span();
        common::assert_events_emitted(pragma.contract_address, expected_events, Option::None);

        // now try forcing the fetch
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr, true);
        assert(eth_price == fetched_eth.unwrap(), 'wrong ETH price 2');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_fetch_price_insufficient_sources() {
        let (pragma, mock_pragma) = pragma_utils::pragma_deploy();
        let (_sentinel, _shrine, yangs, _gates) = sentinel_utils::deploy_sentinel_with_gates(Option::None);
        pragma_utils::add_yangs_to_pragma(pragma, yangs);

        let eth_addr = *yangs.at(0);
        let now: u64 = 100000000;
        set_block_timestamp(now);

        let eth_price: Wad = seer_utils::ETH_INIT_PRICE.into();

        // prepare the response from mock oracle in such a way
        // that it has less than the required number of sources
        let num_sources: u256 = (pragma_utils::SOURCES_THRESHOLD - 1).into();
        mock_pragma
            .next_get_data_median(
                pragma_utils::get_pair_id_for_yang(eth_addr),
                PricesResponse {
                    price: pragma_utils::convert_price_to_pragma_scale(eth_price).into(),
                    decimals: pragma_utils::PRAGMA_DECIMALS.into(),
                    last_updated_timestamp: now.into(),
                    num_sources_aggregated: num_sources
                }
            );

        set_contract_address(common::non_zero_address());
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr, false);

        assert(fetched_eth.unwrap_err() == 'PGM: Invalid price update', 'wrong result');
        let mut expected_events: Span<pragma_contract::Event> = array![
            pragma_contract::Event::InvalidPriceUpdate(
                pragma_contract::InvalidPriceUpdate {
                    yang: eth_addr,
                    price: eth_price,
                    pragma_last_updated_ts: now.into(),
                    pragma_num_sources: num_sources
                }
            ),
        ]
            .span();
        common::assert_events_emitted(pragma.contract_address, expected_events, Option::None);

        // now try forcing the fetch
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr, true);
        assert(eth_price == fetched_eth.unwrap(), 'wrong ETH price 2');
    }
}
