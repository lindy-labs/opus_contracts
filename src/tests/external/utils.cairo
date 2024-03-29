pub mod pragma_utils {
    use core::num::traits::Zero;
    use core::traits::Into;
    use opus::core::roles::shrine_roles;
    use opus::external::pragma::pragma as pragma_contract;
    use opus::external::roles::pragma_roles;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::IPragma::{IPragmaDispatcher, IPragmaDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::mock::mock_pragma::{
        mock_pragma as mock_pragma_contract, IMockPragmaDispatcher, IMockPragmaDispatcherTrait
    };
    use opus::tests::seer::utils::seer_utils::{ETH_INIT_PRICE, WBTC_INIT_PRICE};
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::pragma::PragmaPricesResponse;
    use opus::utils::math::pow;
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, CheatTarget};
    use starknet::{ContractAddress, get_block_timestamp,};
    use wadray::{Wad, WAD_DECIMALS, WAD_SCALE};

    //
    // Constants
    //

    pub const FRESHNESS_THRESHOLD: u64 = 30 * 60; // 30 minutes * 60 seconds
    pub const SOURCES_THRESHOLD: u32 = 3;
    pub const UPDATE_FREQUENCY: u64 = 10 * 60; // 10 minutes * 60 seconds
    pub const DEFAULT_NUM_SOURCES: u32 = 5;
    pub const ETH_USD_PAIR_ID: felt252 = 'ETH/USD';
    pub const WBTC_USD_PAIR_ID: felt252 = 'BTC/USD';
    pub const PEPE_USD_PAIR_ID: felt252 = 'PEPE/USD';
    pub const PRAGMA_DECIMALS: u8 = 8;

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
            Option::None => declare("mock_pragma"),
        };

        let mock_pragma_addr = mock_pragma_class.deploy(@calldata).expect('failed deploy mock pragma');

        IMockPragmaDispatcher { contract_address: mock_pragma_addr }
    }

    pub fn pragma_deploy(
        pragma_class: Option<ContractClass>, mock_pragma_class: Option<ContractClass>
    ) -> (IPragmaDispatcher, IMockPragmaDispatcher) {
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
            Option::None => declare("pragma"),
        };

        let pragma_addr = pragma_class.deploy(@calldata).expect('failed deploy pragma');

        let pragma = IPragmaDispatcher { contract_address: pragma_addr };

        (pragma, mock_pragma)
    }

    pub fn add_yangs(pragma: ContractAddress, yangs: Span<ContractAddress>) {
        // assuming yangs are always ordered as ETH, WBTC
        let eth_yang = *yangs.at(0);
        let wbtc_yang = *yangs.at(1);

        // add_yang does an assert on the response decimals, so we
        // need to provide a valid mock response for it to pass
        let oracle = IOracleDispatcher { contract_address: pragma };
        let mock_pragma = IMockPragmaDispatcher { contract_address: oracle.get_oracle() };
        mock_valid_price_update(mock_pragma, eth_yang, ETH_INIT_PRICE.into(), get_block_timestamp());
        mock_valid_price_update(mock_pragma, wbtc_yang, WBTC_INIT_PRICE.into(), get_block_timestamp());

        // Add yangs to Pragma
        start_prank(CheatTarget::One(pragma), admin());
        let pragma_dispatcher = IPragmaDispatcher { contract_address: pragma };
        pragma_dispatcher.set_yang_pair_id(eth_yang, ETH_USD_PAIR_ID);
        pragma_dispatcher.set_yang_pair_id(wbtc_yang, WBTC_USD_PAIR_ID);
        stop_prank(CheatTarget::One(pragma));
    }

    //
    // Helpers
    //

    pub fn convert_price_to_pragma_scale(price: Wad) -> u128 {
        let scale: u128 = pow(10_u128, WAD_DECIMALS - PRAGMA_DECIMALS);
        price.val / scale
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
    // using default values for decimals and number of sources.
    pub fn mock_valid_price_update(
        mock_pragma: IMockPragmaDispatcher, yang: ContractAddress, price: Wad, timestamp: u64
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
        mock_pragma.next_get_data_median(pair_id, response);
        mock_pragma.next_calculate_twap(pair_id, (price, PRAGMA_DECIMALS.into()));
    }
}

pub mod switchboard_utils {
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::ISwitchboard::{ISwitchboardDispatcher, ISwitchboardDispatcherTrait};
    use opus::mock::mock_switchboard::{IMockSwitchboardDispatcher, IMockSwitchboardDispatcherTrait};
    use opus::tests::seer::utils::seer_utils::{ETH_INIT_PRICE, WBTC_INIT_PRICE};
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, CheatTarget};
    use starknet::ContractAddress;

    pub const ETH_USD_PAIR_ID: felt252 = 'ETH/USD';
    pub const WBTC_USD_PAIR_ID: felt252 = 'BTC/USD';
    pub const TIMESTAMP: u64 = 1710000000;

    pub fn admin() -> ContractAddress {
        'switchboard owner'.try_into().unwrap()
    }

    pub fn mock_eth_token_addr() -> ContractAddress {
        'ETH'.try_into().unwrap()
    }

    fn mock_switchboard_deploy() -> IMockSwitchboardDispatcher {
        let mut calldata: Array<felt252> = ArrayTrait::new();
        let mock_switchboard_addr = declare("mock_switchboard")
            .deploy(@calldata)
            .expect('failed deploy mock switchboard');
        IMockSwitchboardDispatcher { contract_address: mock_switchboard_addr }
    }

    pub fn switchboard_deploy() -> (ISwitchboardDispatcher, IMockSwitchboardDispatcher) {
        let mock_switchboard: IMockSwitchboardDispatcher = mock_switchboard_deploy();

        let mut calldata: Array<felt252> = array![admin().into(), mock_switchboard.contract_address.into()];

        let switchboard_addr = declare("switchboard").deploy(@calldata).expect('failed deploy switchboard');

        let switchboard = ISwitchboardDispatcher { contract_address: switchboard_addr };

        (switchboard, mock_switchboard)
    }

    pub fn add_yangs(switchboard: ContractAddress, yangs: Span<ContractAddress>) {
        // assuming yangs are always orderd as ETH, WBTC
        let eth_yang = *yangs.at(0);
        let wbtc_yang = *yangs.at(1);

        // setting a yang pair_id does a sanity check, so we need
        // to mock valid values
        let oracle = IOracleDispatcher { contract_address: switchboard };
        let mock_switchboard = IMockSwitchboardDispatcher { contract_address: oracle.get_oracle() };
        mock_switchboard.next_get_latest_result(ETH_USD_PAIR_ID, ETH_INIT_PRICE, TIMESTAMP);
        mock_switchboard.next_get_latest_result(WBTC_USD_PAIR_ID, WBTC_INIT_PRICE, TIMESTAMP);

        // set up yangs in Switchboard
        start_prank(CheatTarget::One(switchboard), admin());
        let switchboard_dispatcher = ISwitchboardDispatcher { contract_address: switchboard };
        switchboard_dispatcher.set_yang_pair_id(eth_yang, ETH_USD_PAIR_ID);
        switchboard_dispatcher.set_yang_pair_id(wbtc_yang, WBTC_USD_PAIR_ID);
        stop_prank(CheatTarget::One(switchboard));
    }
}
