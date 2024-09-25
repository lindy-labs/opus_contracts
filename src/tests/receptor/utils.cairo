pub mod receptor_utils {
    // use opus::interfaces::IERC20::{
    //     IERC20Dispatcher, IERC20DispatcherTrait, IMintableDispatcher, IMintableDispatcherTrait
    // };
    // use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    // use opus::tests::common;
    use opus::constants::{DAI_DECIMALS, USDC_DECIMALS, USDT_DECIMALS};
    //use core::integer::BoundedInt;
    //use core::num::traits::Zero;
    use opus::core::receptor::receptor as receptor_contract;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::QuoteTokenInfo;
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, start_warp, CheatTarget};
    use starknet::ContractAddress;
    use wadray::Wad;


    //
    // Address constants
    //

    pub const INITIAL_TWAP_DURATION: u64 = 10800; // 3 hrs

    pub fn mock_usdc() -> ContractAddress {
        'mock USDC'.try_into().unwrap()
    }

    pub fn mock_usdt() -> ContractAddress {
        'mock USDT'.try_into().unwrap()
    }

    pub fn mock_dai() -> ContractAddress {
        'mock DAI'.try_into().unwrap()
    }

    pub fn mock_oracle_extension() -> ContractAddress {
        'mock oracle extension'.try_into().unwrap()
    }

    //
    // Test setup helpers
    //

    pub fn receptor_deploy(
        shrine: ContractAddress,
        oracle_extension: ContractAddress,
        twap_duration: u64,
        mut quote_tokens: Span<QuoteTokenInfo>,
        receptor_class: Option<ContractClass>
    ) -> ContractAddress {
        start_warp(CheatTarget::All, shrine_utils::DEPLOYMENT_TIMESTAMP);

        let mut calldata: Array<felt252> = array![
            shrine_utils::admin().into(),
            shrine.into(),
            oracle_extension.into(),
            twap_duration.into(),
            quote_tokens.len().into()
        ];
        loop {
            match quote_tokens.pop_front() {
                Option::Some(quote_token) => {
                    calldata.append((*quote_token.address).into());
                    calldata.append((*quote_token.decimals).into());
                },
                Option::None => { break; }
            };
        };

        let receptor_class = match receptor_class {
            Option::Some(class) => class,
            Option::None => declare("receptor").unwrap(),
        };
        let (receptor_addr, _) = receptor_class.deploy(@calldata).expect('receptor deploy failed');
        receptor_addr
    }
}
