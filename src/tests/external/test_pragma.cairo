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
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::types::pragma::{PricesResponse, PriceValidityThresholds, YangSettings};
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::utils::math::pow;
    use opus::utils::wadray::{WadZeroable, WAD_DECIMALS, WAD_ONE, WAD_SCALE};
    use opus::utils::wadray;
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};
    use starknet::{ContractAddress, contract_address_try_from_felt252, get_block_timestamp};

    //
    // Constants
    //

    const PEPE_USD_PAIR_ID: u256 = 'PEPE/USD';

    //
    // Address constants
    //

    // TODO: this is not inlined as it would result in `Unknown ap change` error
    //       for `test_update_prices_invalid_gate`
    fn pepe_token_addr() -> ContractAddress {
        contract_address_try_from_felt252('PEPE').unwrap()
    }

    //
    // Tests - Deployment and setters
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_pragma_setup() {
        let (_, pragma, _, mock_pragma, yangs, _) = pragma_utils::pragma_with_yangs();

        // Check permissions
        let pragma_ac = IAccessControlDispatcher { contract_address: pragma.contract_address };
        let admin: ContractAddress = pragma_utils::admin();

        assert(pragma_ac.get_admin() == admin, 'wrong admin');
        assert(
            pragma_ac.get_roles(admin) == pragma_roles::default_admin_role(), 'wrong admin role'
        );

        let mut expected_events: Span<pragma_contract::Event> = array![
            pragma_contract::Event::OracleAddressUpdated(
                pragma_contract::OracleAddressUpdated {
                    old_address: ContractAddressZeroable::zero(),
                    new_address: mock_pragma.contract_address,
                }
            ),
            pragma_contract::Event::UpdateFrequencyUpdated(
                pragma_contract::UpdateFrequencyUpdated {
                    old_frequency: 0, new_frequency: pragma_utils::UPDATE_FREQUENCY,
                }
            ),
            pragma_contract::Event::PriceValidityThresholdsUpdated(
                pragma_contract::PriceValidityThresholdsUpdated {
                    old_thresholds: PriceValidityThresholds { freshness: 0, sources: 0 },
                    new_thresholds: PriceValidityThresholds {
                        freshness: pragma_utils::FRESHNESS_THRESHOLD,
                        sources: pragma_utils::SOURCES_THRESHOLD
                    },
                }
            ),
            pragma_contract::Event::YangAdded(
                pragma_contract::YangAdded {
                    index: 1,
                    settings: YangSettings {
                        pair_id: pragma_utils::ETH_USD_PAIR_ID, yang: *yangs.at(0),
                    },
                }
            ),
            pragma_contract::Event::YangAdded(
                pragma_contract::YangAdded {
                    index: 2,
                    settings: YangSettings {
                        pair_id: pragma_utils::WBTC_USD_PAIR_ID, yang: *yangs.at(1),
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
        let (_, pragma, _, _, _, _) = pragma_utils::pragma_with_yangs();

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
        let (_, pragma, _, _, _, _) = pragma_utils::pragma_with_yangs();

        let invalid_freshness: u64 = pragma_contract::LOWER_FRESHNESS_BOUND - 1;
        let valid_sources: u64 = pragma_utils::SOURCES_THRESHOLD;

        set_contract_address(pragma_utils::admin());
        pragma.set_price_validity_thresholds(invalid_freshness, valid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Freshness out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_freshness_too_high_fail() {
        let (_, pragma, _, _, _, _) = pragma_utils::pragma_with_yangs();

        let invalid_freshness: u64 = pragma_contract::UPPER_FRESHNESS_BOUND + 1;
        let valid_sources: u64 = pragma_utils::SOURCES_THRESHOLD;

        set_contract_address(pragma_utils::admin());
        pragma.set_price_validity_thresholds(invalid_freshness, valid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Sources out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_sources_too_low_fail() {
        let (_, pragma, _, _, _, _) = pragma_utils::pragma_with_yangs();

        let valid_freshness: u64 = pragma_utils::FRESHNESS_THRESHOLD;
        let invalid_sources: u64 = pragma_contract::LOWER_SOURCES_BOUND - 1;

        set_contract_address(pragma_utils::admin());
        pragma.set_price_validity_thresholds(valid_freshness, invalid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Sources out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_sources_too_high_fail() {
        let (_, pragma, _, _, _, _) = pragma_utils::pragma_with_yangs();

        let valid_freshness: u64 = pragma_utils::FRESHNESS_THRESHOLD;
        let invalid_sources: u64 = pragma_contract::UPPER_SOURCES_BOUND + 1;

        set_contract_address(pragma_utils::admin());
        pragma.set_price_validity_thresholds(valid_freshness, invalid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_unauthorized_fail() {
        let (_, pragma, _, _, _, _) = pragma_utils::pragma_with_yangs();

        let valid_freshness: u64 = pragma_utils::FRESHNESS_THRESHOLD;
        let valid_sources: u64 = pragma_utils::SOURCES_THRESHOLD;

        set_contract_address(common::badguy());
        pragma.set_price_validity_thresholds(valid_freshness, valid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_oracle_address_pass() {
        let (_, pragma, _, mock_pragma, _, _) = pragma_utils::pragma_with_yangs();

        let new_address: ContractAddress = common::non_zero_address();

        set_contract_address(pragma_utils::admin());
        pragma.set_oracle(new_address);

        let mut expected_events: Span<pragma_contract::Event> = array![
            pragma_contract::Event::OracleAddressUpdated(
                pragma_contract::OracleAddressUpdated {
                    old_address: mock_pragma.contract_address, new_address,
                }
            ),
        ]
            .span();
        common::assert_events_emitted(pragma.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Address cannot be zero', 'ENTRYPOINT_FAILED'))]
    fn test_set_oracle_zero_address_fail() {
        let (_, pragma, _, _, _, _) = pragma_utils::pragma_with_yangs();

        set_contract_address(pragma_utils::admin());
        pragma.set_oracle(ContractAddressZeroable::zero());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_oracle_address_unauthorized_fail() {
        let (_, pragma, _, _, _, _) = pragma_utils::pragma_with_yangs();

        let new_address: ContractAddress = common::non_zero_address();

        set_contract_address(common::badguy());
        pragma.set_oracle(new_address);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_update_frequency_pass() {
        let (_, pragma, _, _, _, _) = pragma_utils::pragma_with_yangs();

        let new_frequency: u64 = pragma_utils::UPDATE_FREQUENCY * 2;

        set_contract_address(pragma_utils::admin());
        pragma.set_update_frequency(new_frequency);

        let mut expected_events: Span<pragma_contract::Event> = array![
            pragma_contract::Event::UpdateFrequencyUpdated(
                pragma_contract::UpdateFrequencyUpdated {
                    old_frequency: pragma_utils::UPDATE_FREQUENCY, new_frequency,
                }
            ),
        ]
            .span();
        common::assert_events_emitted(pragma.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Frequency out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_update_frequency_too_low_fail() {
        let (_, pragma, _, _, _, _) = pragma_utils::pragma_with_yangs();

        let invalid_frequency: u64 = pragma_contract::LOWER_UPDATE_FREQUENCY_BOUND - 1;

        set_contract_address(pragma_utils::admin());
        pragma.set_update_frequency(invalid_frequency);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Frequency out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_update_frequency_too_high_fail() {
        let (_, pragma, _, _, _, _) = pragma_utils::pragma_with_yangs();

        let invalid_frequency: u64 = pragma_contract::UPPER_UPDATE_FREQUENCY_BOUND + 1;

        set_contract_address(pragma_utils::admin());
        pragma.set_update_frequency(invalid_frequency);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_update_frequency_unauthorized_fail() {
        let (_, pragma, _, _, _, _) = pragma_utils::pragma_with_yangs();

        let new_frequency: u64 = pragma_utils::UPDATE_FREQUENCY * 2;

        set_contract_address(common::badguy());
        pragma.set_update_frequency(new_frequency);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_add_yang_pass() {
        let (_, pragma, _, mock_pragma) = pragma_utils::pragma_deploy();

        // PEPE token is not added to sentinel
        let pepe_token: ContractAddress = pepe_token_addr();
        let pepe_token_pair_id: u256 = PEPE_USD_PAIR_ID;
        let pepe_token_init_price: u128 = 999;

        let pragma_price_scale: u128 = pow(10_u128, pragma_utils::PRAGMA_DECIMALS);

        // Seed first price update for PEPE token so that `Pragma.add_yang` passes
        let price: u128 = pepe_token_init_price * pragma_price_scale;
        let current_ts: u64 = get_block_timestamp();
        pragma_utils::mock_valid_price_update(mock_pragma, pepe_token_pair_id, price, current_ts);

        set_contract_address(pragma_utils::admin());
        pragma.add_yang(pepe_token_pair_id, pepe_token);

        let expected_events: Span<pragma_contract::Event> = array![
            pragma_contract::Event::YangAdded(
                pragma_contract::YangAdded {
                    index: 1,
                    settings: YangSettings { pair_id: pepe_token_pair_id, yang: pepe_token, },
                }
            ),
        ]
            .span();
        common::assert_events_emitted(pragma.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_unauthorized_fail() {
        let (shrine, pragma, sentinel, _) = pragma_utils::pragma_deploy();
        let (eth_token_addr, _) = sentinel_utils::add_eth_yang(sentinel, shrine.contract_address);

        set_contract_address(common::badguy());

        pragma.add_yang(pragma_utils::ETH_USD_PAIR_ID, eth_token_addr);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Yang already present', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_non_unique_address_fail() {
        let (shrine, pragma, sentinel, _) = pragma_utils::pragma_deploy();
        let (eth_token_addr, _) = sentinel_utils::add_eth_yang(sentinel, shrine.contract_address);

        set_contract_address(pragma_utils::admin());
        pragma.add_yang(pragma_utils::ETH_USD_PAIR_ID, eth_token_addr);
        pragma.add_yang(pragma_utils::WBTC_USD_PAIR_ID, eth_token_addr);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Pair ID already present', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_non_unique_pair_id_fail() {
        let (shrine, pragma, sentinel, _) = pragma_utils::pragma_deploy();
        let (eth_token_addr, _) = sentinel_utils::add_eth_yang(sentinel, shrine.contract_address);

        set_contract_address(pragma_utils::admin());
        pragma.add_yang(pragma_utils::ETH_USD_PAIR_ID, eth_token_addr);
        pragma.add_yang(pragma_utils::ETH_USD_PAIR_ID, pepe_token_addr());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Invalid pair ID', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_invalid_pair_id_fail() {
        let (shrine, pragma, sentinel, _) = pragma_utils::pragma_deploy();
        let (eth_token_addr, _) = sentinel_utils::add_eth_yang(sentinel, shrine.contract_address);

        set_contract_address(pragma_utils::admin());

        let invalid_pair_id = U256Zeroable::zero();
        pragma.add_yang(invalid_pair_id, eth_token_addr);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Invalid yang address', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_invalid_yang_address_fail() {
        let (_, pragma, _, _) = pragma_utils::pragma_deploy();

        set_contract_address(pragma_utils::admin());

        let invalid_yang_addr = ContractAddressZeroable::zero();
        pragma.add_yang(pragma_utils::ETH_USD_PAIR_ID, invalid_yang_addr);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Unknown pair ID', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_unknown_pair_id_fail() {
        let (_, pragma, _, _) = pragma_utils::pragma_deploy();

        set_contract_address(pragma_utils::admin());

        pragma.add_yang(PEPE_USD_PAIR_ID, pepe_token_addr());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Too many decimals', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_too_many_decimals_fail() {
        let (_, pragma, _, mock_pragma, _, _) = pragma_utils::pragma_with_yangs();

        let price_ts: u256 = (get_block_timestamp() - 1000).into();
        let pragma_price_scale: u128 = pow(10_u128, pragma_utils::PRAGMA_DECIMALS);

        let pepe_price: u128 = 1000000 * pragma_price_scale; // random price
        let invalid_decimals: u256 = (WAD_DECIMALS + 1).into();
        let pepe_response = PricesResponse {
            price: pepe_price.into(),
            decimals: invalid_decimals,
            last_updated_timestamp: price_ts,
            num_sources_aggregated: pragma_utils::DEFAULT_NUM_SOURCES,
        };
        mock_pragma.next_get_data_median(PEPE_USD_PAIR_ID, pepe_response);

        set_contract_address(pragma_utils::admin());

        pragma.add_yang(PEPE_USD_PAIR_ID, pepe_token_addr());
    }

    //
    // Tests - Functionality
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_update_prices_pass() {
        let (shrine, pragma, _, mock_pragma, yangs, gates) = pragma_utils::pragma_with_yangs();

        let eth_addr = *yangs.at(0);
        let wbtc_addr = *yangs.at(1);

        let eth_gate = *gates.at(0);
        let wbtc_gate = *gates.at(1);

        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };

        // Perform a price update with starting exchange rate of 1 yang to 1 asset
        let first_ts = get_block_timestamp() + 1;
        set_block_timestamp(first_ts);
        let mut raw_eth_price: u128 = pragma_utils::ETH_INIT_PRICE;
        pragma_utils::mock_valid_price_update(
            mock_pragma,
            pragma_utils::ETH_USD_PAIR_ID,
            pragma_utils::convert_price_to_pragma_scale(raw_eth_price),
            first_ts
        );

        let mut raw_wbtc_price: u128 = pragma_utils::WBTC_INIT_PRICE;
        pragma_utils::mock_valid_price_update(
            mock_pragma,
            pragma_utils::WBTC_USD_PAIR_ID,
            pragma_utils::convert_price_to_pragma_scale(raw_wbtc_price),
            first_ts
        );

        set_contract_address(common::non_zero_address());
        pragma_oracle.update_prices();

        let (eth_price, _, _) = shrine.get_current_yang_price(eth_addr);
        assert(eth_price == (raw_eth_price * WAD_SCALE).into(), 'wrong ETH price');

        let (wbtc_price, _, _) = shrine.get_current_yang_price(wbtc_addr);
        assert(wbtc_price == (raw_wbtc_price * WAD_SCALE).into(), 'wrong WBTC price');

        let gate_eth_bal: u128 = eth_gate.get_total_assets();
        let gate_wbtc_bal: u128 = wbtc_gate.get_total_assets();
        let rebase_multiplier: u128 = 2;

        IMintableDispatcher { contract_address: eth_addr }
            .mint(eth_gate.contract_address, gate_eth_bal.into());
        IMintableDispatcher { contract_address: wbtc_addr }
            .mint(wbtc_gate.contract_address, gate_wbtc_bal.into());

        let next_ts = first_ts + shrine::TIME_INTERVAL;
        set_block_timestamp(next_ts);
        raw_eth_price += 10;
        pragma_utils::mock_valid_price_update(
            mock_pragma,
            pragma_utils::ETH_USD_PAIR_ID,
            pragma_utils::convert_price_to_pragma_scale(raw_eth_price),
            next_ts
        );
        raw_wbtc_price += 10;
        pragma_utils::mock_valid_price_update(
            mock_pragma,
            pragma_utils::WBTC_USD_PAIR_ID,
            pragma_utils::convert_price_to_pragma_scale(raw_wbtc_price),
            next_ts
        );
        pragma_oracle.update_prices();

        let (eth_price, _, _) = shrine.get_current_yang_price(eth_addr);
        assert(
            eth_price == (raw_eth_price * rebase_multiplier * WAD_SCALE).into(),
            'wrong rebased ETH price'
        );

        let (wbtc_price, _, _) = shrine.get_current_yang_price(wbtc_addr);
        assert(
            wbtc_price == (raw_wbtc_price * rebase_multiplier * WAD_SCALE).into(),
            'wrong rebased WBTC price'
        );

        let mut expected_events: Span<pragma_contract::Event> = array![
            pragma_contract::Event::PricesUpdated(
                pragma_contract::PricesUpdated {
                    timestamp: first_ts, caller: common::non_zero_address(),
                }
            ),
            pragma_contract::Event::PricesUpdated(
                pragma_contract::PricesUpdated {
                    timestamp: next_ts, caller: common::non_zero_address(),
                }
            ),
        ]
            .span();
        common::assert_events_emitted(pragma.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_update_prices_pass_without_yangs() {
        // just to test the module works well even if no yangs were added yet
        let (_, pragma, _, _) = pragma_utils::pragma_deploy();

        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        pragma_oracle.update_prices();
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Too soon to update prices', 'ENTRYPOINT_FAILED'))]
    fn test_update_prices_too_soon_fail() {
        let (_, pragma, _, mock_pragma, _, _) = pragma_utils::pragma_with_yangs();
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };

        let mut new_ts: u64 = get_block_timestamp() + 1;
        let mut price: u128 = pragma_utils::convert_price_to_pragma_scale(
            pragma_utils::ETH_INIT_PRICE + 10
        );
        set_block_timestamp(new_ts);
        pragma_utils::mock_valid_price_update(
            mock_pragma, pragma_utils::ETH_USD_PAIR_ID, price, new_ts
        );
        pragma_oracle.update_prices();

        price += pragma_utils::convert_price_to_pragma_scale(10);
        new_ts += pragma_contract::LOWER_UPDATE_FREQUENCY_BOUND - 1;
        set_block_timestamp(new_ts);
        pragma_utils::mock_valid_price_update(
            mock_pragma, pragma_utils::ETH_USD_PAIR_ID, price, new_ts
        );
        pragma_oracle.update_prices();
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_update_prices_insufficient_sources_unchanged() {
        let (shrine, pragma, _, mock_pragma, yangs, _) = pragma_utils::pragma_with_yangs();
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };

        let eth_token_addr = *yangs.at(0);
        let wbtc_token_addr = *yangs.at(1);

        let (before_eth_price, _, _) = shrine.get_current_yang_price(eth_token_addr);
        let (before_wbtc_price, _, _) = shrine.get_current_yang_price(wbtc_token_addr);

        let pragma_price_scale: u128 = pow(10_u128, pragma_utils::PRAGMA_DECIMALS);

        let price: u128 = pragma_utils::ETH_INIT_PRICE * pragma_price_scale;
        let invalid_num_sources: u64 = pragma_contract::LOWER_SOURCES_BOUND - 1;
        let current_ts: u64 = get_block_timestamp();
        let mut eth_response = PricesResponse {
            price: price.into(),
            decimals: pragma_utils::PRAGMA_DECIMALS.into(),
            last_updated_timestamp: current_ts.into(),
            num_sources_aggregated: invalid_num_sources.into(),
        };
        mock_pragma.next_get_data_median(pragma_utils::ETH_USD_PAIR_ID, eth_response);

        let price: u128 = pragma_utils::WBTC_INIT_PRICE * pragma_price_scale;
        let mut wbtc_response = PricesResponse {
            price: price.into(),
            decimals: pragma_utils::PRAGMA_DECIMALS.into(),
            last_updated_timestamp: current_ts.into(),
            num_sources_aggregated: invalid_num_sources.into(),
        };
        mock_pragma.next_get_data_median(pragma_utils::WBTC_USD_PAIR_ID, wbtc_response);

        set_contract_address(common::non_zero_address());
        pragma_oracle.update_prices();

        let (after_eth_price, _, _) = shrine.get_current_yang_price(eth_token_addr);
        assert(before_eth_price == after_eth_price, 'price should not be updated #1');
        let (after_wbtc_price, _, _) = shrine.get_current_yang_price(wbtc_token_addr);
        assert(before_wbtc_price == after_wbtc_price, 'price should not be updated #2');

        assert(!pragma.probe_task(), 'should not be ready');
        let mut expected_events: Span<pragma_contract::Event> = array![
            pragma_contract::Event::InvalidPriceUpdate(
                pragma_contract::InvalidPriceUpdate {
                    yang: *yangs.at(0),
                    price: (pragma_utils::ETH_INIT_PRICE * WAD_ONE).into(),
                    pragma_last_updated_ts: current_ts.into(),
                    pragma_num_sources: invalid_num_sources.into(),
                    asset_amt_per_yang: WAD_ONE.into(),
                }
            ),
            pragma_contract::Event::InvalidPriceUpdate(
                pragma_contract::InvalidPriceUpdate {
                    yang: *yangs.at(1),
                    price: (pragma_utils::WBTC_INIT_PRICE * WAD_ONE).into(),
                    pragma_last_updated_ts: current_ts.into(),
                    pragma_num_sources: invalid_num_sources.into(),
                    asset_amt_per_yang: WAD_ONE.into(),
                }
            ),
        ]
            .span();
        let mut should_not_emit: Span<pragma_contract::Event> = array![
            pragma_contract::Event::PricesUpdated(
                pragma_contract::PricesUpdated {
                    timestamp: current_ts, caller: common::non_zero_address(),
                }
            ),
        ]
            .span();
        common::assert_events_emitted(
            pragma.contract_address, expected_events, Option::Some(should_not_emit)
        );
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_update_prices_invalid_gate() {
        let (shrine, pragma, _, mock_pragma, yangs, _) = pragma_utils::pragma_with_yangs();
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };

        // PEPE token is not added to sentinel
        let pepe_token: ContractAddress = pepe_token_addr();
        let pepe_token_pair_id: u256 = PEPE_USD_PAIR_ID;
        let pepe_token_init_price: u128 = 999;

        let pragma_price_scale: u128 = pow(10_u128, pragma_utils::PRAGMA_DECIMALS);

        // Seed first price update for PEPE token so that `Pragma.add_yang` passes
        let price: u128 = pepe_token_init_price * pragma_price_scale;
        let current_ts: u64 = get_block_timestamp();
        pragma_utils::mock_valid_price_update(mock_pragma, pepe_token_pair_id, price, current_ts);

        set_contract_address(pragma_utils::admin());
        pragma.add_yang(pepe_token_pair_id, pepe_token);

        let eth_token_addr = *yangs.at(0);
        let wbtc_token_addr = *yangs.at(1);

        let (before_eth_price, _, _) = shrine.get_current_yang_price(eth_token_addr);
        let (before_wbtc_price, _, _) = shrine.get_current_yang_price(wbtc_token_addr);

        let next_ts: u64 = current_ts + shrine::TIME_INTERVAL;
        set_block_timestamp(next_ts);

        let pepe_token_raw_price: u128 = pepe_token_init_price + 1;
        let pepe_token_price: u128 = pepe_token_raw_price * pragma_price_scale;
        pragma_utils::mock_valid_price_update(
            mock_pragma, pepe_token_pair_id, pepe_token_price, next_ts
        );

        let price: u128 = (pragma_utils::ETH_INIT_PRICE + 1) * pragma_price_scale;
        pragma_utils::mock_valid_price_update(
            mock_pragma, pragma_utils::ETH_USD_PAIR_ID, price, next_ts
        );

        let price: u128 = (pragma_utils::WBTC_INIT_PRICE + 1) * pragma_price_scale;
        pragma_utils::mock_valid_price_update(
            mock_pragma, pragma_utils::WBTC_USD_PAIR_ID, price, next_ts
        );

        set_contract_address(common::non_zero_address());
        pragma_oracle.update_prices();

        let (after_eth_price, _, _) = shrine.get_current_yang_price(eth_token_addr);
        assert(before_eth_price != after_eth_price, 'price should be updated #1');
        let (after_wbtc_price, _, _) = shrine.get_current_yang_price(wbtc_token_addr);
        assert(before_wbtc_price != after_wbtc_price, 'price should be updated #2');

        assert(!pragma.probe_task(), 'should not be ready');

        let mut expected_events: Span<pragma_contract::Event> = array![
            pragma_contract::Event::InvalidPriceUpdate(
                pragma_contract::InvalidPriceUpdate {
                    yang: pepe_token,
                    price: (pepe_token_raw_price * WAD_ONE).into(),
                    pragma_last_updated_ts: next_ts.into(),
                    pragma_num_sources: pragma_utils::DEFAULT_NUM_SOURCES.into(),
                    asset_amt_per_yang: WadZeroable::zero(),
                }
            ),
            pragma_contract::Event::PricesUpdated(
                pragma_contract::PricesUpdated {
                    timestamp: next_ts, caller: common::non_zero_address()
                }
            ),
        ]
            .span();
        common::assert_events_emitted(pragma.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_probe_task() {
        let (_, pragma, _, mock_pragma, _, _) = pragma_utils::pragma_with_yangs();
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };

        // last price update should be 0 initially
        assert(pragma.probe_task(), 'should be ready');

        let new_ts: u64 = get_block_timestamp() + 1;
        set_block_timestamp(new_ts);
        pragma_utils::mock_valid_price_update(
            mock_pragma,
            pragma_utils::ETH_USD_PAIR_ID,
            pragma_utils::convert_price_to_pragma_scale(pragma_utils::ETH_INIT_PRICE + 10),
            new_ts
        );
        pragma_oracle.update_prices();

        // after update_prices, the last update ts is moved to current block ts
        // as well, so calling probe_task in the same block afterwards should
        // return false
        assert(!pragma.probe_task(), 'should not be ready');

        // moving the block time forward to the next time interval,
        // probe_task should again return true
        set_block_timestamp(new_ts + shrine::TIME_INTERVAL);
        assert(pragma.probe_task(), 'should be ready');
    }
}
