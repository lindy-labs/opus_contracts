use starknet::ContractAddress;

pub fn mock_eth_token_addr() -> ContractAddress {
    'ETH'.try_into().unwrap()
}

pub fn pepe_token_addr() -> ContractAddress {
    'PEPE'.try_into().unwrap()
}

pub mod pragma_utils {
    use core::traits::Into;
    use opus::constants::{ETH_USD_PAIR_ID, PRAGMA_DECIMALS, WBTC_USD_PAIR_ID};
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::IPragma::{IPragmaDispatcher, IPragmaDispatcherTrait};
    use opus::mock::mock_pragma::{IMockPragmaDispatcher, IMockPragmaDispatcherTrait};
    use opus::tests::seer::utils::seer_utils::{ETH_INIT_PRICE, WBTC_INIT_PRICE};
    use opus::types::pragma::{AggregationMode, PairSettings, PragmaPricesResponse};
    use opus::utils::math::pow;
    use snforge_std::{
        ContractClass, ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
        stop_cheat_caller_address,
    };
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::{WAD_DECIMALS, Wad};

    #[derive(Copy, Drop)]
    pub struct PragmaTestConfig {
        pub pragma: IPragmaDispatcher,
        pub mock_pragma: IMockPragmaDispatcher,
    }

    #[derive(Copy, Drop)]
    pub struct PragmaTestConfig {
        pub pragma: IPragmaDispatcher,
        pub mock_pragma: IMockPragmaDispatcher,
    }

    //
    // Constants
    //

    pub const FRESHNESS_THRESHOLD: u64 = 30 * 60; // 30 minutes * 60 seconds
    pub const SOURCES_THRESHOLD: u32 = 3;
    pub const UPDATE_FREQUENCY: u64 = 10 * 60; // 10 minutes * 60 seconds
    pub const DEFAULT_NUM_SOURCES: u32 = 5;
    pub const PEPE_USD_PAIR_ID: felt252 = 'PEPE/USD';

    //
    // Constant addresses
    //

    #[inline(always)]
    pub fn admin() -> ContractAddress {
        'pragma owner'.try_into().unwrap()
    }

    //
    // Test setup helpers
    //

    pub fn mock_pragma_deploy(mock_pragma_class: Option<ContractClass>) -> IMockPragmaDispatcher {
        let mut calldata: Array<felt252> = ArrayTrait::new();

        let mock_pragma_class = match mock_pragma_class {
            Option::Some(class) => class,
            Option::None => *declare("mock_pragma").unwrap().contract_class(),
        };

        let (mock_pragma_addr, _) = mock_pragma_class.deploy(@calldata).expect('mock pragma deploy failed');

        IMockPragmaDispatcher { contract_address: mock_pragma_addr }
    }

    pub fn pragma_deploy(
        pragma_class: Option<ContractClass>, mock_pragma_class: Option<ContractClass>,
    ) -> PragmaTestConfig {
        let mock_pragma: IMockPragmaDispatcher = mock_pragma_deploy(mock_pragma_class);
        let mut calldata: Array<felt252> = array![
            admin().into(),
            mock_pragma.contract_address.into(),
            mock_pragma.contract_address.into(),
            FRESHNESS_THRESHOLD.into(),
            SOURCES_THRESHOLD.into(),
        ];

        let pragma_class = match pragma_class {
            Option::Some(class) => class,
            Option::None => *declare("pragma").unwrap().contract_class(),
        };

        let (pragma_addr, _) = pragma_class.deploy(@calldata).expect('pragma  deploy failed');

        let pragma = IPragmaDispatcher { contract_address: pragma_addr };

        PragmaTestConfig { pragma: pragma, mock_pragma }
    }

    pub fn add_yangs(pragma: ContractAddress, yangs: Span<ContractAddress>) {
        // assuming yangs are always ordered as ETH, WBTC
        let eth_yang = *yangs.at(0);
        let wbtc_yang = *yangs.at(1);

        // add_yang does an assert on the response decimals, so we
        // need to provide a valid mock response for it to pass
        let oracle = IOracleDispatcher { contract_address: pragma };
        let mock_pragma = IMockPragmaDispatcher { contract_address: *oracle.get_oracles().at(0) };
        mock_valid_price_update(mock_pragma, eth_yang, ETH_INIT_PRICE.into(), get_block_timestamp());
        mock_valid_price_update(mock_pragma, wbtc_yang, WBTC_INIT_PRICE.into(), get_block_timestamp());

        // Add yangs to Pragma
        start_cheat_caller_address(pragma, admin());
        let pragma_dispatcher = IPragmaDispatcher { contract_address: pragma };
        let eth_pair_settings = PairSettings { pair_id: ETH_USD_PAIR_ID, aggregation_mode: AggregationMode::Median };
        let wbtc_pair_settings = PairSettings { pair_id: WBTC_USD_PAIR_ID, aggregation_mode: AggregationMode::Median };
        pragma_dispatcher.set_yang_pair_settings(eth_yang, eth_pair_settings);
        pragma_dispatcher.set_yang_pair_settings(wbtc_yang, wbtc_pair_settings);
        stop_cheat_caller_address(pragma);
    }

    //
    // Helpers
    //

    pub fn convert_price_to_pragma_scale(price: Wad) -> u128 {
        let scale: u128 = pow(10_u128, WAD_DECIMALS - PRAGMA_DECIMALS);
        price.into() / scale
    }

    pub fn get_pair_id_for_yang(yang: ContractAddress) -> felt252 {
        let erc20 = IERC20Dispatcher { contract_address: yang };
        let symbol: felt252 = erc20.symbol();

        if symbol == 'ETH' {
            ETH_USD_PAIR_ID
        } else if symbol == 'WBTC' {
            WBTC_USD_PAIR_ID
        } else if symbol == 'PEPE' {
            PEPE_USD_PAIR_ID
        } else {
            0
        }
    }

    // Helper function to add a valid price update to the mock Pragma oracle
    // for both `get_data_median()` (v1) and `get_data()` ()
    // using default values for decimals and number of sources.
    pub fn mock_valid_price_update(
        mock_pragma: IMockPragmaDispatcher, yang: ContractAddress, price: Wad, timestamp: u64,
    ) {
        let price = convert_price_to_pragma_scale(price);
        let response = PragmaPricesResponse {
            price,
            decimals: PRAGMA_DECIMALS.into(),
            last_updated_timestamp: timestamp,
            num_sources_aggregated: DEFAULT_NUM_SOURCES,
            expiration_timestamp: Option::None,
        };
        let pair_id: felt252 = get_pair_id_for_yang(yang);
        mock_pragma.next_get_data(pair_id, response);
        mock_pragma.next_get_data_median(pair_id, response);
        mock_pragma.next_calculate_twap(pair_id, (price, PRAGMA_DECIMALS.into()));
    }
}

pub mod ekubo_utils {
    use opus::interfaces::IEkubo::IEkuboDispatcher;
    use opus::mock::mock_ekubo_oracle_extension::IMockEkuboOracleExtensionDispatcher;
    use opus::tests::common;
    use snforge_std::{ContractClass, ContractClassTrait, DeclareResultTrait, declare};
    use starknet::ContractAddress;

    #[derive(Copy, Drop)]
    pub struct EkuboTestConfig {
        pub ekubo: IEkuboDispatcher,
        pub mock_ekubo: IMockEkuboOracleExtensionDispatcher,
        pub quote_tokens: Span<ContractAddress>,
    }

    //
    // Constants
    //

    pub const TWAP_DURATION: u64 = 5 * 60; // 5 minutes * 60 seconds
    pub const PEPE_USD_PAIR_ID: felt252 = 'PEPE/USD';

    //
    // Constant addresses
    //

    #[inline(always)]
    pub fn admin() -> ContractAddress {
        'ekubo owner'.try_into().unwrap()
    }

    //
    // Test setup helpers
    //

    pub fn ekubo_deploy(
        ekubo_class: Option<ContractClass>,
        mock_ekubo_oracle_extension_class: Option<ContractClass>,
        token_class: Option<ContractClass>,
    ) -> EkuboTestConfig {
        let mock_ekubo: IMockEkuboOracleExtensionDispatcher = common::mock_ekubo_oracle_extension_deploy(
            mock_ekubo_oracle_extension_class,
        );
        let quote_tokens: Span<ContractAddress> = common::quote_tokens(token_class);
        let mut calldata: Array<felt252> = array![
            admin().into(),
            mock_ekubo.contract_address.into(),
            TWAP_DURATION.into(),
            quote_tokens.len().into(),
            (*quote_tokens[0]).into(),
            (*quote_tokens[1]).into(),
            (*quote_tokens[2]).into(),
        ];

        let ekubo_class = match ekubo_class {
            Option::Some(class) => class,
            Option::None => *declare("ekubo").unwrap().contract_class(),
        };
        let (ekubo_addr, _) = ekubo_class.deploy(@calldata).expect('ekubo deploy failed');
        let ekubo = IEkuboDispatcher { contract_address: ekubo_addr };

        EkuboTestConfig { ekubo, mock_ekubo, quote_tokens }
    }
}
