mod pragma_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use debug::PrintTrait;
    use opus::core::roles::{pragma_roles, shrine_roles};
    use opus::external::pragma::pragma as pragma_contract;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::IPragma::{IPragmaDispatcher, IPragmaDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::external::{IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait};
    use opus::mock::mock_spot_pragma::{
        mock_spot_pragma as mock_spot_pragma_contract, IMockSpotPragmaDispatcher, IMockSpotPragmaDispatcherTrait
    };
    use opus::mock::mock_twap_pragma::{
        mock_twap_pragma as mock_twap_pragma_contract, IMockTwapPragmaDispatcher, IMockTwapPragmaDispatcherTrait
    };
    use opus::tests::seer::utils::seer_utils::{ETH_INIT_PRICE, WBTC_INIT_PRICE};
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::pragma::PragmaPricesResponse;
    use opus::utils::math::pow;
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, CheatTarget};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::{
        ContractAddress, contract_address_to_felt252, contract_address_try_from_felt252, get_block_timestamp,
    };
    use wadray::{Wad, WAD_DECIMALS, WAD_SCALE};

    //
    // Constants
    //

    const FRESHNESS_THRESHOLD: u64 = consteval_int!(30 * 60); // 30 minutes * 60 seconds
    const SOURCES_THRESHOLD: u32 = 3;
    const UPDATE_FREQUENCY: u64 = consteval_int!(10 * 60); // 10 minutes * 60 seconds
    const DEFAULT_NUM_SOURCES: u32 = 5;
    const ETH_USD_PAIR_ID: felt252 = 'ETH/USD';
    const WBTC_USD_PAIR_ID: felt252 = 'BTC/USD';
    const PEPE_USD_PAIR_ID: felt252 = 'PEPE/USD';
    const PRAGMA_DECIMALS: u8 = 8;

    //
    // Constant addresses
    //

    #[inline(always)]
    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('pragma owner').unwrap()
    }

    //
    // Test setup helpers
    //

    fn mock_spot_pragma_deploy(mock_spot_pragma_class: Option<ContractClass>) -> IMockSpotPragmaDispatcher {
        let mut calldata: Array<felt252> = ArrayTrait::new();

        let mock_spot_pragma_class = match mock_spot_pragma_class {
            Option::Some(class) => class,
            Option::None => declare('mock_spot_pragma'),
        };

        let mock_spot_pragma_addr = mock_spot_pragma_class.deploy(@calldata).expect('failed deploy spot pragma');

        IMockSpotPragmaDispatcher { contract_address: mock_spot_pragma_addr }
    }

    fn mock_twap_pragma_deploy(mock_twap_pragma_class: Option<ContractClass>) -> IMockTwapPragmaDispatcher {
        let mut calldata: Array<felt252> = ArrayTrait::new();

        let mock_twap_pragma_class = match mock_twap_pragma_class {
            Option::Some(class) => class,
            Option::None => declare('mock_twap_pragma'),
        };

        let mock_twap_pragma_addr = mock_twap_pragma_class.deploy(@calldata).expect('failed deploy twap pragma');

        IMockTwapPragmaDispatcher { contract_address: mock_twap_pragma_addr }
    }

    fn pragma_deploy(
        pragma_class: Option<ContractClass>,
        mock_spot_pragma_class: Option<ContractClass>,
        mock_twap_pragma_class: Option<ContractClass>
    ) -> (IPragmaDispatcher, IMockSpotPragmaDispatcher, IMockTwapPragmaDispatcher) {
        let mock_spot_pragma: IMockSpotPragmaDispatcher = mock_spot_pragma_deploy(mock_spot_pragma_class);
        let mock_twap_pragma: IMockTwapPragmaDispatcher = mock_twap_pragma_deploy(mock_twap_pragma_class);
        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(admin()),
            contract_address_to_felt252(mock_spot_pragma.contract_address),
            contract_address_to_felt252(mock_twap_pragma.contract_address),
            FRESHNESS_THRESHOLD.into(),
            SOURCES_THRESHOLD.into(),
        ];

        let pragma_class = match pragma_class {
            Option::Some(class) => class,
            Option::None => declare('pragma'),
        };

        let pragma_addr = pragma_class.deploy(@calldata).expect('failed deploy pragma');

        let pragma = IPragmaDispatcher { contract_address: pragma_addr };

        (pragma, mock_spot_pragma, mock_twap_pragma)
    }

    fn add_yangs_to_pragma(pragma: IPragmaDispatcher, yangs: Span<ContractAddress>) {
        let eth_yang = *yangs.at(0);
        let wbtc_yang = *yangs.at(1);

        // add_yang does an assert on the response decimals, so we
        // need to provide a valid mock response for it to pass
        let oracle = IOracleDispatcher { contract_address: pragma.contract_address };

        let mock_pragmas: Span<ContractAddress> = oracle.get_oracles();

        let mock_spot_pragma = IMockSpotPragmaDispatcher { contract_address: *mock_pragmas[0] };
        mock_valid_spot_price_update(mock_spot_pragma, eth_yang, ETH_INIT_PRICE.into(), get_block_timestamp());
        mock_valid_spot_price_update(mock_spot_pragma, wbtc_yang, WBTC_INIT_PRICE.into(), get_block_timestamp());

        let mock_twap_pragma = IMockTwapPragmaDispatcher { contract_address: *mock_pragmas[1] };
        mock_valid_twap_update(mock_twap_pragma, eth_yang, ETH_INIT_PRICE.into());
        mock_valid_twap_update(mock_twap_pragma, wbtc_yang, WBTC_INIT_PRICE.into());

        // Add yangs to Pragma
        start_prank(CheatTarget::One(pragma.contract_address), admin());
        pragma.set_yang_pair_id(eth_yang, ETH_USD_PAIR_ID);
        pragma.set_yang_pair_id(wbtc_yang, WBTC_USD_PAIR_ID);
        stop_prank(CheatTarget::One(pragma.contract_address));
    }

    //
    // Helpers
    //

    fn convert_price_to_pragma_scale(price: Wad) -> u128 {
        let scale: u128 = pow(10_u128, WAD_DECIMALS - PRAGMA_DECIMALS);
        price.val / scale
    }

    fn get_pair_id_for_yang(yang: ContractAddress) -> felt252 {
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

    // Helper function to add a valid price update to the mock Pragma spot oracle
    // using default values for decimals and number of sources.
    fn mock_valid_spot_price_update(
        mock_spot_pragma: IMockSpotPragmaDispatcher, yang: ContractAddress, price: Wad, timestamp: u64
    ) {
        let response = PragmaPricesResponse {
            price: convert_price_to_pragma_scale(price),
            decimals: PRAGMA_DECIMALS.into(),
            last_updated_timestamp: timestamp,
            num_sources_aggregated: DEFAULT_NUM_SOURCES,
            expiration_timestamp: Option::None,
        };
        let pair_id: felt252 = get_pair_id_for_yang(yang);
        mock_spot_pragma.next_get_data_median(pair_id, response);
    }

    // Helper function to add a valid price update to the mock Pragma TWAP oracle
    // using default values for decimals.
    fn mock_valid_twap_update(mock_twap_pragma: IMockTwapPragmaDispatcher, yang: ContractAddress, price: Wad) {
        let price: u128 = convert_price_to_pragma_scale(price);
        let decimals: u32 = PRAGMA_DECIMALS.into();

        let pair_id: felt252 = get_pair_id_for_yang(yang);
        mock_twap_pragma.next_calculate_twap(pair_id, price, decimals);
    }
}
