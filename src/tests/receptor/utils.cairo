pub mod receptor_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::core::roles::shrine_roles;
    use opus::interfaces::IReceptor::IReceptorDispatcher;
    use opus::interfaces::IShrine::IShrineDispatcher;
    use opus::mock::mock_ekubo_oracle_extension::IMockEkuboOracleExtensionDispatcher;
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{
        ContractClass, ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp_global,
        start_cheat_caller_address, stop_cheat_caller_address,
    };
    use starknet::ContractAddress;
    use wadray::{WAD_DECIMALS, WAD_ONE};

    #[derive(Copy, Drop)]
    pub struct ReceptorTestConfig {
        pub mock_ekubo_oracle_extension: IMockEkuboOracleExtensionDispatcher,
        pub receptor: IReceptorDispatcher,
        pub shrine: IShrineDispatcher,
        pub quote_tokens: Span<ContractAddress>,
    }

    //
    // constants
    //

    pub const INITIAL_TWAP_DURATION: u64 = 10800; // 3 hrs
    pub const INITIAL_UPDATE_FREQUENCY: u64 = 1800; // 30 mins

    pub fn invalid_token(token_class: Option<ContractClass>) -> ContractAddress {
        common::deploy_token(
            'Invalid', 'INV', (WAD_DECIMALS + 1).into(), WAD_ONE.into(), shrine_utils::admin(), token_class,
        )
    }

    pub fn mock_oracle_extension() -> ContractAddress {
        'mock oracle extension'.try_into().unwrap()
    }

    //
    // Test setup helpers
    //

    pub fn mock_ekubo_oracle_extension_deploy(
        mock_ekubo_oracle_extension_class: Option<ContractClass>,
    ) -> ContractAddress {
        let mut calldata: Array<felt252> = ArrayTrait::new();

        let mock_ekubo_oracle_extension_class = match mock_ekubo_oracle_extension_class {
            Option::Some(class) => class,
            Option::None => common::declare_mock_ekubo_oracle_extension(),
        };

        let (mock_ekubo_oracle_extension_addr, _) = mock_ekubo_oracle_extension_class
            .deploy(@calldata)
            .expect('mock ekubo oracle ext failed');

        mock_ekubo_oracle_extension_addr
    }

    pub fn receptor_deploy(
        receptor_class: Option<ContractClass>, token_class: Option<ContractClass>,
    ) -> ReceptorTestConfig {
        start_cheat_block_timestamp_global(shrine_utils::DEPLOYMENT_TIMESTAMP);

        let quote_tokens = common::quote_tokens(token_class);

        let shrine: IShrineDispatcher = shrine_utils::shrine_deploy_and_setup(Option::None);
        let mock_ekubo_oracle_extension_addr: ContractAddress = mock_ekubo_oracle_extension_deploy(Option::None);

        let mut calldata: Array<felt252> = array![
            shrine_utils::admin().into(),
            shrine.contract_address.into(),
            mock_ekubo_oracle_extension_addr.into(),
            INITIAL_UPDATE_FREQUENCY.into(),
            INITIAL_TWAP_DURATION.into(),
            quote_tokens.len().into(),
            (*quote_tokens[0]).into(),
            (*quote_tokens[1]).into(),
            (*quote_tokens[2]).into(),
        ];

        let receptor_class = match receptor_class {
            Option::Some(class) => class,
            Option::None => *declare("receptor").unwrap().contract_class(),
        };
        let (receptor_addr, _) = receptor_class.deploy(@calldata).expect('receptor deploy failed');

        // Grant UPDATE_YIN_SPOT_PRICE role to receptor contract
        start_cheat_caller_address(shrine.contract_address, shrine_utils::admin());
        let shrine_accesscontrol = IAccessControlDispatcher { contract_address: shrine.contract_address };
        shrine_accesscontrol.grant_role(shrine_roles::receptor(), receptor_addr);
        stop_cheat_caller_address(shrine.contract_address);

        ReceptorTestConfig {
            shrine,
            receptor: IReceptorDispatcher { contract_address: receptor_addr },
            mock_ekubo_oracle_extension: IMockEkuboOracleExtensionDispatcher {
                contract_address: mock_ekubo_oracle_extension_addr,
            },
            quote_tokens,
        }
    }
}
