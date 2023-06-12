#[cfg(test)]
mod TestPragma {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::{
        ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_const,
        contract_address_to_felt252, deploy_syscall, get_block_timestamp, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};
    use traits::{Default, Into};

    use aura::core::roles::{PragmaRoles, ShrineRoles};
    use aura::core::shrine::Shrine;
    use aura::external::pragma::Pragma;

    use aura::interfaces::IERC20::{IMintableDispatcher, IMintableDispatcherTrait};
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use aura::interfaces::external::{IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait};
    use aura::interfaces::IPragma::{IPragmaDispatcher, IPragmaDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::pow::pow10;
    use aura::utils::types::Pragma::{DataType, PricesResponse};
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{WadZeroable, WAD_DECIMALS, WAD_SCALE};

    use aura::tests::external::mock_pragma::{
        IMockPragmaDispatcher, IMockPragmaDispatcherTrait, MockPragma
    };
    use aura::tests::gate::utils::GateUtils;
    use aura::tests::sentinel::utils::SentinelUtils;
    use aura::tests::shrine::utils::ShrineUtils;

    //
    // Constants
    //

    const FRESHNESS_THRESHOLD: u64 = 1800; // 30 minutes * 60 seconds
    const SOURCES_THRESHOLD: u64 = 3;
    const UPDATE_FREQUENCY: u64 = 600; // 10 minutes * 60 seconds

    const DEFAULT_NUM_SOURCES: u256 = 5;

    const ETH_USD_PAIR_ID: u256 = 19514442401534788; // str_to_felt("ETH/USD")
    const ETH_INIT_PRICE: u128 = 1888; // raw integer value without fixed point decimals

    const WBTC_USD_PAIR_ID: u256 = 18669995996566340; // str_to_felt("BTC/USD")
    const WBTC_INIT_PRICE: u128 = 20000; // raw integer value without fixed point decimals

    const PEPE_USD_PAIR_ID: u256 = 5784117554504356676; // str_to_felt("PEPE/USD")

    const PRAGMA_DECIMALS: u8 = 8;

    //
    // Helpers
    //

    // Helper function to add a valid price update to the mock Pragma oracle
    // using default values for decimals and number of sources.
    // Note that `price` is the raw integer value without fixed point decimals.
    fn mock_valid_price_update(
        mock_pragma: IMockPragmaDispatcher, pair_id: u256, price: u128, timestamp: u64
    ) {
        let pragma_price_scale: u128 = pow10(PRAGMA_DECIMALS);

        let price: u128 = price * pragma_price_scale;
        let response = PricesResponse {
            price: price.into(),
            decimals: PRAGMA_DECIMALS.into(),
            last_updated_timestamp: timestamp.into(),
            num_sources_aggregated: DEFAULT_NUM_SOURCES,
        };
        mock_pragma.next_get_data_median(pair_id, response);
    }

    //
    // Test setup helpers
    //

    fn mock_pragma_deploy() -> IMockPragmaDispatcher {
        let mut calldata = Default::default();
        let mock_pragma_class_hash: ClassHash = class_hash_try_from_felt252(
            MockPragma::TEST_CLASS_HASH
        )
            .unwrap();
        let (mock_pragma_addr, _) = deploy_syscall(
            mock_pragma_class_hash, 0, calldata.span(), false
        )
            .unwrap_syscall();

        // Add ETH/USD and BTC/USD to mock Pragma oracle
        let mock_pragma: IMockPragmaDispatcher = IMockPragmaDispatcher {
            contract_address: mock_pragma_addr
        };

        let price_ts: u64 = get_block_timestamp() - 1000;
        let pragma_price_scale: u128 = pow10(PRAGMA_DECIMALS);
        mock_valid_price_update(mock_pragma, ETH_USD_PAIR_ID, ETH_INIT_PRICE, price_ts);

        let btc_price: u128 = WBTC_INIT_PRICE * pragma_price_scale;
        mock_valid_price_update(mock_pragma, WBTC_USD_PAIR_ID, WBTC_INIT_PRICE, price_ts);

        mock_pragma
    }

    fn pragma_deploy() -> (
        IShrineDispatcher,
        IPragmaDispatcher,
        ISentinelDispatcher,
        IMockPragmaDispatcher,
        Span<ContractAddress>, // yangs
        Span<IGateDispatcher>,
    ) {
        let (sentinel, shrine, yangs, gates) = SentinelUtils::deploy_sentinel_with_gates();
        let mock_pragma: IMockPragmaDispatcher = mock_pragma_deploy();

        let admin: ContractAddress = ShrineUtils::admin();

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(admin));
        calldata.append(contract_address_to_felt252(mock_pragma.contract_address));
        calldata.append(contract_address_to_felt252(shrine.contract_address));
        calldata.append(contract_address_to_felt252(sentinel.contract_address));
        calldata.append(UPDATE_FREQUENCY.into());
        calldata.append(FRESHNESS_THRESHOLD.into());
        calldata.append(SOURCES_THRESHOLD.into());

        let pragma_class_hash: ClassHash = class_hash_try_from_felt252(Pragma::TEST_CLASS_HASH)
            .unwrap();
        let (pragma_addr, _) = deploy_syscall(pragma_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        // Grant access control
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine.contract_address };
        set_contract_address(admin);
        shrine_ac.grant_role(ShrineRoles::ADVANCE, pragma_addr);
        set_contract_address(ContractAddressZeroable::zero());

        let pragma = IPragmaDispatcher { contract_address: pragma_addr };

        (shrine, pragma, sentinel, mock_pragma, yangs, gates)
    }

    fn pragma_with_yangs() -> (
        IShrineDispatcher,
        IPragmaDispatcher,
        ISentinelDispatcher,
        IMockPragmaDispatcher,
        Span<ContractAddress>, // yang addresses
        Span<IGateDispatcher>
    ) {
        let (shrine, pragma, sentinel, mock_pragma, yangs, gates) = pragma_deploy();

        set_contract_address(ShrineUtils::admin());

        // Add yangs to Pragma
        pragma.add_yang(ETH_USD_PAIR_ID, *yangs.at(0));
        pragma.add_yang(WBTC_USD_PAIR_ID, *yangs.at(1));

        set_contract_address(ContractAddressZeroable::zero());

        (shrine, pragma, sentinel, mock_pragma, yangs, gates)
    }

    //
    // Tests - Deployment and setters
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_setup() {
        let (_, pragma, _, _, _, _) = pragma_deploy();

        // Check permissions
        let pragma_ac = IAccessControlDispatcher { contract_address: pragma.contract_address };
        let admin: ContractAddress = ShrineUtils::admin();

        assert(pragma_ac.get_admin() == admin, 'wrong admin');
        assert(pragma_ac.get_roles(admin) == PragmaRoles::default_admin_role(), 'wrong admin role');
        assert(pragma_ac.has_role(PragmaRoles::default_admin_role(), admin), 'wrong admin role');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_price_validity_thresholds_pass() {
        let (_, pragma, _, _, _, _) = pragma_deploy();

        let new_freshness: u64 = 300; // 5 minutes * 60 seconds
        let new_sources: u64 = 8;

        set_contract_address(ShrineUtils::admin());
        pragma.set_price_validity_thresholds(new_freshness, new_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Freshness out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_freshness_too_low_fail() {
        let (_, pragma, _, _, _, _) = pragma_deploy();

        let invalid_freshness: u64 = Pragma::LOWER_FRESHNESS_BOUND - 1;
        let valid_sources: u64 = SOURCES_THRESHOLD;

        set_contract_address(ShrineUtils::admin());
        pragma.set_price_validity_thresholds(invalid_freshness, valid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Freshness out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_freshness_too_high_fail() {
        let (_, pragma, _, _, _, _) = pragma_deploy();

        let invalid_freshness: u64 = Pragma::UPPER_FRESHNESS_BOUND + 1;
        let valid_sources: u64 = SOURCES_THRESHOLD;

        set_contract_address(ShrineUtils::admin());
        pragma.set_price_validity_thresholds(invalid_freshness, valid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Sources out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_sources_too_low_fail() {
        let (_, pragma, _, _, _, _) = pragma_deploy();

        let valid_freshness: u64 = FRESHNESS_THRESHOLD;
        let invalid_sources: u64 = Pragma::LOWER_SOURCES_BOUND - 1;

        set_contract_address(ShrineUtils::admin());
        pragma.set_price_validity_thresholds(valid_freshness, invalid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Sources out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_sources_too_high_fail() {
        let (_, pragma, _, _, _, _) = pragma_deploy();

        let valid_freshness: u64 = FRESHNESS_THRESHOLD;
        let invalid_sources: u64 = Pragma::UPPER_SOURCES_BOUND + 1;

        set_contract_address(ShrineUtils::admin());
        pragma.set_price_validity_thresholds(valid_freshness, invalid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_unauthorized_fail() {
        let (_, pragma, _, _, _, _) = pragma_deploy();

        let valid_freshness: u64 = FRESHNESS_THRESHOLD;
        let valid_sources: u64 = SOURCES_THRESHOLD;

        set_contract_address(ShrineUtils::badguy());
        pragma.set_price_validity_thresholds(valid_freshness, valid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_oracle_address_pass() {
        let (_, pragma, _, _, _, _) = pragma_deploy();

        let new_address: ContractAddress = contract_address_const::<0x9999>();

        set_contract_address(ShrineUtils::admin());
        pragma.set_oracle(new_address);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_oracle_address_unauthorized_fail() {
        let (_, pragma, _, _, _, _) = pragma_deploy();

        let new_address: ContractAddress = contract_address_const::<0x9999>();

        set_contract_address(ShrineUtils::badguy());
        pragma.set_oracle(new_address);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_update_frequency_pass() {
        let (_, pragma, _, _, _, _) = pragma_deploy();

        let new_frequency: u64 = UPDATE_FREQUENCY * 2;

        set_contract_address(ShrineUtils::admin());
        pragma.set_update_frequency(new_frequency);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Frequency out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_update_frequency_too_low_fail() {
        let (_, pragma, _, _, _, _) = pragma_deploy();

        let invalid_frequency: u64 = Pragma::LOWER_UPDATE_FREQUENCY_BOUND - 1;

        set_contract_address(ShrineUtils::admin());
        pragma.set_update_frequency(invalid_frequency);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Frequency out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_update_frequency_too_high_fail() {
        let (_, pragma, _, _, _, _) = pragma_deploy();

        let invalid_frequency: u64 = Pragma::UPPER_UPDATE_FREQUENCY_BOUND + 1;

        set_contract_address(ShrineUtils::admin());
        pragma.set_update_frequency(invalid_frequency);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_update_frequency_unauthorized_fail() {
        let (_, pragma, _, _, _, _) = pragma_deploy();

        let new_frequency: u64 = UPDATE_FREQUENCY * 2;

        set_contract_address(ShrineUtils::badguy());
        pragma.set_update_frequency(new_frequency);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_add_yang_pass() {
        let (_, pragma, _, _, _, _) = pragma_deploy();
        let eth_token_addr: ContractAddress = GateUtils::eth_token_deploy();
        let wbtc_token_addr: ContractAddress = GateUtils::wbtc_token_deploy();

        set_contract_address(ShrineUtils::admin());

        pragma.add_yang(ETH_USD_PAIR_ID, eth_token_addr);
        pragma.add_yang(WBTC_USD_PAIR_ID, wbtc_token_addr);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_unauthorized_fail() {
        let (_, pragma, _, _, _, _) = pragma_deploy();
        let eth_token_addr: ContractAddress = GateUtils::eth_token_deploy();

        set_contract_address(ShrineUtils::badguy());

        pragma.add_yang(ETH_USD_PAIR_ID, eth_token_addr);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Invalid pair ID', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_invalid_pair_id_fail() {
        let (_, pragma, _, _, _, _) = pragma_deploy();
        let eth_token_addr: ContractAddress = GateUtils::eth_token_deploy();

        set_contract_address(ShrineUtils::admin());

        pragma.add_yang(0, eth_token_addr);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Invalid yang address', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_invalid_yang_address_fail() {
        let (_, pragma, _, _, _, _) = pragma_deploy();

        set_contract_address(ShrineUtils::admin());

        pragma.add_yang(ETH_USD_PAIR_ID, ContractAddressZeroable::zero());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Unknown pair ID', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_unknwon_pair_id_fail() {
        let (_, pragma, _, _, _, _) = pragma_deploy();

        set_contract_address(ShrineUtils::admin());

        pragma.add_yang(PEPE_USD_PAIR_ID, contract_address_const::<0xbebe>());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Too many decimals', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_too_many_decimals_fail() {
        let (_, pragma, _, mock_pragma, _, _) = pragma_deploy();

        let price_ts: u256 = (get_block_timestamp() - 1000).into();
        let pragma_price_scale: u128 = pow10(PRAGMA_DECIMALS);

        let pepe_price: u128 = 1000000 * pragma_price_scale; // random price
        let invalid_decimals: u256 = (WAD_DECIMALS + 1).into();
        let pepe_response = PricesResponse {
            price: pepe_price.into(),
            decimals: invalid_decimals,
            last_updated_timestamp: price_ts,
            num_sources_aggregated: DEFAULT_NUM_SOURCES,
        };
        mock_pragma.next_get_data_median(PEPE_USD_PAIR_ID, pepe_response);

        set_contract_address(ShrineUtils::admin());

        pragma.add_yang(PEPE_USD_PAIR_ID, contract_address_const::<0xbebe>());
    }

    //
    // Tests - Functionality
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_update_prices_pass() {
        let (shrine, pragma, sentinel, mock_pragma, yangs, gates) = pragma_with_yangs();
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };

        // Perform a price update with starting exchange rate of 1 yang to 1 asset
        let first_ts = get_block_timestamp() + 1;
        mock_valid_price_update(mock_pragma, ETH_USD_PAIR_ID, ETH_INIT_PRICE, first_ts);
        mock_valid_price_update(mock_pragma, WBTC_USD_PAIR_ID, WBTC_INIT_PRICE, first_ts);

        let admin: ContractAddress = ShrineUtils::admin();
        set_contract_address(admin);
        pragma_oracle.update_prices();

        let eth_addr: ContractAddress = *yangs.at(0);
        let wbtc_addr: ContractAddress = *yangs.at(1);

        let (eth_price, _, _) = shrine.get_current_yang_price(eth_addr);
        assert(eth_price == (ETH_INIT_PRICE * WAD_SCALE).into(), 'wrong ETH price');

        let (wbtc_price, _, _) = shrine.get_current_yang_price(wbtc_addr);
        assert(wbtc_price == (WBTC_INIT_PRICE * WAD_SCALE).into(), 'wrong WBTC price');

        // Perform another price update after rebasing exchange rate to 1 yang to 2 asset
        let eth_gate: IGateDispatcher = *gates.at(0);
        let wbtc_gate: IGateDispatcher = *gates.at(1);

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
        let new_eth_price = ETH_INIT_PRICE + 10;
        mock_valid_price_update(mock_pragma, ETH_USD_PAIR_ID, new_eth_price, next_ts);
        let new_wbtc_price = WBTC_INIT_PRICE + 10;
        mock_valid_price_update(mock_pragma, WBTC_USD_PAIR_ID, new_wbtc_price, next_ts);
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
        let (_, pragma, _, _, _, _) = pragma_deploy();

        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        pragma_oracle.update_prices();
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Too soon to update prices', 'ENTRYPOINT_FAILED'))]
    fn test_update_prices_too_soon_fail() {
        let (_, pragma, _, mock_pragma, _, _) = pragma_with_yangs();
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };

        let mut new_ts: u64 = get_block_timestamp() + 1;
        let mut price: u128 = ETH_INIT_PRICE + 10;
        set_block_timestamp(new_ts);
        mock_valid_price_update(mock_pragma, ETH_USD_PAIR_ID, price, new_ts);
        pragma_oracle.update_prices();

        price += 10;
        new_ts += 1;
        set_block_timestamp(new_ts);
        mock_valid_price_update(mock_pragma, ETH_USD_PAIR_ID, price, new_ts);
        pragma_oracle.update_prices();
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_update_prices_insufficient_sources_unchanged() {
        let (shrine, pragma, _, mock_pragma, yang_addrs, _) = pragma_with_yangs();
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };

        let eth_token_addr = *yang_addrs.at(0);

        let (before_eth_price, _, _) = shrine.get_current_yang_price(eth_token_addr);

        let pragma_price_scale: u128 = pow10(PRAGMA_DECIMALS);

        let price: u128 = ETH_INIT_PRICE * pragma_price_scale;
        let invalid_num_sources: u64 = Pragma::LOWER_SOURCES_BOUND - 1;
        let response = PricesResponse {
            price: price.into(),
            decimals: PRAGMA_DECIMALS.into(),
            last_updated_timestamp: get_block_timestamp().into(),
            num_sources_aggregated: invalid_num_sources.into(),
        };
        mock_pragma.next_get_data_median(ETH_USD_PAIR_ID, response);

        pragma_oracle.update_prices();

        let (after_eth_price, _, _) = shrine.get_current_yang_price(eth_token_addr);
        assert(before_eth_price == after_eth_price, 'price should not update');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_update_prices_invalid_gate_fail() {}

    #[test]
    #[available_gas(20000000000)]
    fn test_probe_task() {
        let (_, pragma, _, mock_pragma, _, _) = pragma_deploy();
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };

        // last price update should be 0 initially
        assert(pragma.probe_task(), 'should be ready');

        let new_ts: u64 = get_block_timestamp() + 1;
        set_block_timestamp(new_ts);
        mock_valid_price_update(mock_pragma, ETH_USD_PAIR_ID, ETH_INIT_PRICE + 10, new_ts);
        pragma_oracle.update_prices();

        // after update_prices, the last update ts is moved to current block ts
        // as well, so calling probe_task in the same block afterwards should
        // return false
        assert(!pragma.probe_task(), 'should not be ready');

        // moving the block time forward to the next time interval, probeTask
        // should again return true
        set_block_timestamp(new_ts + Shrine::TIME_INTERVAL);
        assert(pragma.probe_task(), 'should be ready');
    }
}
