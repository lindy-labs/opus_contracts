pub mod seer_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::core::roles::shrine_roles;
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::ISeer::{ISeerDispatcher, ISeerDispatcherTrait};
    use opus::interfaces::ISentinel::ISentinelDispatcher;
    use opus::interfaces::IShrine::IShrineDispatcher;
    use opus::mock::mock_pragma::IMockPragmaDispatcher;
    use opus::tests::external::utils::{ekubo_utils, pragma_utils};
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::PriceType;
    use snforge_std::{
        ContractClass, ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
        stop_cheat_caller_address,
    };
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::Wad;

    #[derive(Copy, Drop)]
    pub struct SeerTestConfig {
        pub shrine: IShrineDispatcher,
        pub seer: ISeerDispatcher,
        pub sentinel: ISentinelDispatcher,
    }

    #[derive(Copy, Drop)]
    pub struct OracleTestClasses {
        pub pragma: Option<ContractClass>,
        pub mock_pragma: Option<ContractClass>,
        pub ekubo: Option<ContractClass>,
        pub mock_ekubo: Option<ContractClass>,
    }

    //
    // Constants
    //

    pub const ETH_INIT_PRICE: u128 = 1888000000000000000000; // Wad scale
    pub const WBTC_INIT_PRICE: u128 = 20000000000000000000000; // Wad scale

    pub const UPDATE_FREQUENCY: u64 = 30 * 60; // 30 minutes

    //
    // Address constants
    //

    pub fn admin() -> ContractAddress {
        'seer owner'.try_into().unwrap()
    }

    pub fn dummy_eth() -> ContractAddress {
        'eth token'.try_into().unwrap()
    }

    pub fn dummy_wbtc() -> ContractAddress {
        'wbtc token'.try_into().unwrap()
    }

    //
    // Test setup helpers
    //

    pub fn declare_oracles() -> OracleTestClasses {
        OracleTestClasses {
            pragma: Option::Some(*declare("pragma").unwrap().contract_class()),
            mock_pragma: Option::Some(*declare("mock_pragma").unwrap().contract_class()),
            ekubo: Option::Some(*declare("ekubo").unwrap().contract_class()),
            mock_ekubo: Option::Some(common::declare_mock_ekubo_oracle_extension()),
        }
    }

    pub fn deploy_seer(
        seer_class: Option<ContractClass>, sentinel_classes: Option<sentinel_utils::SentinelTestClasses>,
    ) -> SeerTestConfig {
        let (sentinel_dispatcher, shrine) = sentinel_utils::deploy_sentinel(sentinel_classes);
        let calldata: Array<felt252> = array![
            admin().into(), shrine.into(), sentinel_dispatcher.contract_address.into(), UPDATE_FREQUENCY.into(),
        ];

        let seer_class = match seer_class {
            Option::Some(class) => class,
            Option::None => *declare("seer").unwrap().contract_class(),
        };

        let (seer_addr, _) = seer_class.deploy(@calldata).expect('failed seer deploy');

        // Allow Seer to advance Shrine
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine };
        start_cheat_caller_address(shrine, shrine_utils::admin());
        shrine_ac.grant_role(shrine_roles::seer(), seer_addr);
        stop_cheat_caller_address(shrine);

        SeerTestConfig {
            seer: ISeerDispatcher { contract_address: seer_addr },
            sentinel: sentinel_dispatcher,
            shrine: IShrineDispatcher { contract_address: shrine },
        }
    }

    pub fn deploy_seer_using(
        seer_class: Option<ContractClass>, shrine: ContractAddress, sentinel: ContractAddress,
    ) -> ISeerDispatcher {
        let mut calldata: Array<felt252> = array![
            admin().into(), shrine.into(), sentinel.into(), UPDATE_FREQUENCY.into(),
        ];

        let seer_class = match seer_class {
            Option::Some(class) => class,
            Option::None => *declare("seer").unwrap().contract_class(),
        };

        let (seer_addr, _) = seer_class.deploy(@calldata).expect('failed seer deploy');

        // Allow Seer to advance Shrine
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine };
        start_cheat_caller_address(shrine, shrine_utils::admin());
        shrine_ac.grant_role(shrine_roles::seer(), seer_addr);
        stop_cheat_caller_address(shrine);

        ISeerDispatcher { contract_address: seer_addr }
    }

    pub fn set_price_types_to_vault(seer: ISeerDispatcher, mut vaults: Span<ContractAddress>) {
        start_cheat_caller_address(seer.contract_address, admin());
        loop {
            match vaults.pop_front() {
                Option::Some(vault) => { seer.set_yang_price_type(*vault, PriceType::Vault); },
                Option::None => { break; },
            };
        }
        stop_cheat_caller_address(seer.contract_address);
    }

    pub fn add_oracles(
        seer: ISeerDispatcher, oracle_classes: Option<OracleTestClasses>, token_class: Option<ContractClass>,
    ) -> Span<ContractAddress> {
        let oracle_classes = match oracle_classes {
            Option::Some(classes) => classes,
            Option::None => declare_oracles(),
        };

        let mut oracles: Array<ContractAddress> = ArrayTrait::new();

        let pragma_utils::PragmaTestConfig {
            pragma, ..,
        } = pragma_utils::pragma_deploy(oracle_classes.pragma, oracle_classes.mock_pragma);
        oracles.append(pragma.contract_address);

        let ekubo_utils::EkuboTestConfig {
            ekubo, ..,
        } = ekubo_utils::ekubo_deploy(oracle_classes.ekubo, oracle_classes.mock_ekubo, token_class);
        oracles.append(ekubo.contract_address);

        start_cheat_caller_address(seer.contract_address, admin());
        seer.set_oracles(oracles.span());
        stop_cheat_caller_address(seer.contract_address);

        oracles.span()
    }

    pub fn mock_valid_price_update(seer: ISeerDispatcher, yang: ContractAddress, price: Wad) {
        let current_ts: u64 = get_block_timestamp();
        let oracles: Span<ContractAddress> = seer.get_oracles();

        // assuming first oracle is Pragma
        let pragma = IOracleDispatcher { contract_address: *oracles.at(0) };
        let mock_pragma = IMockPragmaDispatcher { contract_address: *pragma.get_oracles().at(0) };
        pragma_utils::mock_valid_price_update(mock_pragma, yang, price, current_ts);
    }
}
