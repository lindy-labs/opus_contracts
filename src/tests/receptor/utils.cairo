pub mod receptor_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::constants::{DAI_DECIMALS, LUSD_DECIMALS, USDC_DECIMALS, USDT_DECIMALS};
    use opus::core::receptor::receptor as receptor_contract;
    use opus::core::roles::shrine_roles;
    use opus::interfaces::IReceptor::{IReceptorDispatcher, IReceptorDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::mock::mock_ekubo_oracle_extension::{
        IMockEkuboOracleExtensionDispatcher, IMockEkuboOracleExtensionDispatcherTrait
    };
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::QuoteTokenInfo;
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, start_warp, CheatTarget};
    use starknet::ContractAddress;
    use wadray::{Wad, WAD_DECIMALS, WAD_ONE};


    //
    // constants
    //

    pub const INITIAL_TWAP_DURATION: u64 = 10800; // 3 hrs
    pub const INITIAL_UPDATE_FREQUENCY: u64 = 1800; // 30 mins

    pub fn mock_usdc(token_class: Option<ContractClass>) -> ContractAddress {
        common::deploy_token(
            'USD Coin', 'USDC', USDC_DECIMALS.into(), WAD_ONE.into(), shrine_utils::admin(), token_class
        )
    }

    pub fn mock_usdt(token_class: Option<ContractClass>) -> ContractAddress {
        common::deploy_token(
            'Tether USD', 'USDT', USDT_DECIMALS.into(), WAD_ONE.into(), shrine_utils::admin(), token_class
        )
    }

    pub fn mock_dai(token_class: Option<ContractClass>) -> ContractAddress {
        common::deploy_token(
            'Dai Stablecoin', 'DAI', DAI_DECIMALS.into(), WAD_ONE.into(), shrine_utils::admin(), token_class
        )
    }

    pub fn mock_lusd(token_class: Option<ContractClass>) -> ContractAddress {
        common::deploy_token(
            'LUSD Stablecoin', 'LUSD', LUSD_DECIMALS.into(), WAD_ONE.into(), shrine_utils::admin(), token_class
        )
    }

    pub fn invalid_token(token_class: Option<ContractClass>) -> ContractAddress {
        common::deploy_token(
            'Invalid', 'INV', (WAD_DECIMALS + 1).into(), WAD_ONE.into(), shrine_utils::admin(), token_class
        )
    }

    pub fn mock_oracle_extension() -> ContractAddress {
        'mock oracle extension'.try_into().unwrap()
    }

    pub fn quote_tokens(token_class: Option<ContractClass>) -> Span<ContractAddress> {
        array![mock_dai(token_class), mock_usdc(token_class), mock_usdt(token_class),].span()
    }

    //
    // Test setup helpers
    //

    pub fn mock_ekubo_oracle_extension_deploy(
        mock_ekubo_oracle_extension_class: Option<ContractClass>
    ) -> ContractAddress {
        let mut calldata: Array<felt252> = ArrayTrait::new();

        let mock_ekubo_oracle_extension_class = match mock_ekubo_oracle_extension_class {
            Option::Some(class) => class,
            Option::None => declare("mock_ekubo_oracle_extension").unwrap(),
        };

        let (mock_ekubo_oracle_extension_addr, _) = mock_ekubo_oracle_extension_class
            .deploy(@calldata)
            .expect('mock ekubo oracle ext failed');

        mock_ekubo_oracle_extension_addr
    }

    pub fn receptor_deploy(
        receptor_class: Option<ContractClass>, token_class: Option<ContractClass>
    ) -> (IShrineDispatcher, IReceptorDispatcher, ContractAddress, Span<ContractAddress>) {
        start_warp(CheatTarget::All, shrine_utils::DEPLOYMENT_TIMESTAMP);

        let quote_tokens = quote_tokens(token_class);

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
            Option::None => declare("receptor").unwrap(),
        };
        let (receptor_addr, _) = receptor_class.deploy(@calldata).expect('receptor deploy failed');

        // Grant UPDATE_YIN_SPOT_PRICE role to receptor contract
        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        let shrine_accesscontrol = IAccessControlDispatcher { contract_address: shrine.contract_address };
        shrine_accesscontrol.grant_role(shrine_roles::receptor(), receptor_addr);
        stop_prank(CheatTarget::One(shrine.contract_address));

        (
            shrine,
            IReceptorDispatcher { contract_address: receptor_addr },
            mock_ekubo_oracle_extension_addr,
            quote_tokens
        )
    }

    pub fn set_next_prices(
        shrine_addr: ContractAddress,
        mock_ekubo_oracle_extension_addr: ContractAddress,
        mut quote_tokens: Span<ContractAddress>,
        mut prices: Span<u256>
    ) {
        let mock_ekubo_oracle_extension_setter = IMockEkuboOracleExtensionDispatcher {
            contract_address: mock_ekubo_oracle_extension_addr
        };

        assert_eq!(quote_tokens.len(), prices.len(), "unequal len");

        loop {
            match quote_tokens.pop_front() {
                Option::Some(quote_token) => {
                    mock_ekubo_oracle_extension_setter
                        .next_get_price_x128_over_last(shrine_addr, *quote_token, *prices.pop_front().unwrap(),);
                },
                Option::None => { break; }
            };
        };
    }
}
