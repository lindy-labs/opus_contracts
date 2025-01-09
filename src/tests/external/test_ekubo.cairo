mod test_ekubo {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::num::traits::Zero;
    use core::result::ResultTrait;
    use opus::constants;
    use opus::core::shrine::shrine;
    use opus::external::ekubo::ekubo as ekubo_contract;
    use opus::external::interfaces::{IEkuboOracleExtensionDispatcher, IEkuboOracleExtensionDispatcherTrait};
    use opus::external::roles::ekubo_roles;
    use opus::interfaces::IERC20::{IMintableDispatcher, IMintableDispatcherTrait};
    use opus::interfaces::IEkubo::{IEkuboDispatcher, IEkuboDispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::mock::mock_ekubo_oracle_extension::{
        IMockEkuboOracleExtensionDispatcher, IMockEkuboOracleExtensionDispatcherTrait, set_next_ekubo_prices
    };
    use opus::tests::common;
    use opus::tests::external::utils::{ekubo_utils, mock_eth_token_addr};
    use opus::tests::seer::utils::seer_utils;
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::types::QuoteTokenInfo;
    use opus::utils::ekubo_oracle_config::{
        ekubo_oracle_config_component, IEkuboOracleConfigDispatcher, IEkuboOracleConfigDispatcherTrait
    };
    use opus::utils::math::{convert_ekubo_oracle_price_to_wad, pow};
    use snforge_std::{
        declare, start_prank, stop_prank, start_warp, CheatTarget, spy_events, SpyOn, EventSpy, EventAssertions
    };
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::{Wad, WAD_DECIMALS, WAD_SCALE};

    //
    // Tests - Deployment and setters
    //

    #[test]
    fn test_ekubo_setup() {
        let token_class = declare("erc20_mintable").unwrap();
        let (ekubo, mock_ekubo, _quote_tokens) = ekubo_utils::ekubo_deploy(
            Option::None, Option::None, Option::Some(token_class)
        );

        // Check permissions
        let ekubo_ac = IAccessControlDispatcher { contract_address: ekubo.contract_address };
        let admin: ContractAddress = ekubo_utils::admin();

        assert(ekubo_ac.get_admin() == admin, 'wrong admin');
        assert(ekubo_ac.get_roles(admin) == ekubo_roles::default_admin_role(), 'wrong admin role');

        let oracle = IOracleDispatcher { contract_address: ekubo.contract_address };
        assert(oracle.get_name() == 'Ekubo', 'wrong name');
        let oracles: Span<ContractAddress> = array![mock_ekubo.contract_address].span();
        assert(oracle.get_oracles() == oracles, 'wrong oracle addresses');
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_quote_tokens_unauthorized() {
        let token_class = declare("erc20_mintable").unwrap();
        let (ekubo, _mock_ekubo, quote_tokens) = ekubo_utils::ekubo_deploy(
            Option::None, Option::None, Option::Some(token_class)
        );
        let ekubo_oracle_config = IEkuboOracleConfigDispatcher { contract_address: ekubo.contract_address };

        start_prank(CheatTarget::One(ekubo.contract_address), common::badguy());
        ekubo_oracle_config.set_quote_tokens(quote_tokens);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_twap_duration_unauthorized() {
        let token_class = declare("erc20_mintable").unwrap();
        let (ekubo, _mock_ekubo, _quote_tokens) = ekubo_utils::ekubo_deploy(
            Option::None, Option::None, Option::Some(token_class)
        );
        let ekubo_oracle_config = IEkuboOracleConfigDispatcher { contract_address: ekubo.contract_address };

        start_prank(CheatTarget::One(ekubo.contract_address), common::badguy());
        ekubo_oracle_config.set_twap_duration(ekubo_oracle_config_component::MIN_TWAP_DURATION + 1);
    }

    //
    // Tests - Functionality
    //

    #[test]
    fn test_fetch_price_pass() {
        let token_class = declare("erc20_mintable").unwrap();
        let (ekubo, mock_ekubo, quote_tokens) = ekubo_utils::ekubo_deploy(
            Option::None, Option::None, Option::Some(token_class)
        );
        let oracle = IOracleDispatcher { contract_address: ekubo.contract_address };

        let eth = common::eth_token_deploy(Option::Some(token_class));

        // Use real values to ensure correctness
        let eth_dai_x128_price: u256 = 1136300885434234067297094194169939045041922;
        let eth_usdc_x128_price: u256 = 1135036808904793908619842566045;
        let eth_usdt_x128_price: u256 = 1134582885198987280493503591381;
        let prices = array![eth_dai_x128_price, eth_usdc_x128_price, eth_usdt_x128_price].span();

        set_next_ekubo_prices(mock_ekubo.contract_address, eth, quote_tokens, prices);

        let exact_price: Wad = convert_ekubo_oracle_price_to_wad(
            eth_usdc_x128_price, WAD_DECIMALS, constants::USDC_DECIMALS
        );
        let result: Result<Wad, felt252> = oracle.fetch_price(eth);
        assert(result.is_ok(), 'fetch price failed');
        let actual_price: Wad = result.unwrap();
        assert_eq!(actual_price, exact_price, "wrong price");

        let expected_price: Wad = 3335573392107353791360_u128.into();
        let error_margin: Wad = 1000_u128.into();
        println!("actual price: {}", actual_price);
        println!("expected_price: {}", expected_price);
        common::assert_equalish(actual_price, expected_price, error_margin, 'wrong converted price');
    }

    #[test]
    fn test_fetch_price_more_than_one_invalid_price_fail() {
        let token_class = declare("erc20_mintable").unwrap();
        let (ekubo, mock_ekubo, quote_tokens) = ekubo_utils::ekubo_deploy(
            Option::None, Option::None, Option::Some(token_class)
        );
        let oracle = IOracleDispatcher { contract_address: ekubo.contract_address };

        let mut spy = spy_events(SpyOn::One(ekubo.contract_address));

        let eth = common::eth_token_deploy(Option::Some(token_class));

        // Use real values to ensure correctness
        let eth_dai_x128_price: u256 = 0;
        let eth_usdc_x128_price: u256 = 1135036808904793908619842566045;
        let eth_usdt_x128_price: u256 = 0;
        let prices = array![eth_dai_x128_price, eth_usdc_x128_price, eth_usdt_x128_price].span();

        set_next_ekubo_prices(mock_ekubo.contract_address, eth, quote_tokens, prices);

        let expected_usdc_price: Wad = convert_ekubo_oracle_price_to_wad(
            eth_usdc_x128_price, WAD_DECIMALS, constants::USDC_DECIMALS
        );
        let result: Result<Wad, felt252> = oracle.fetch_price(eth);
        assert(result.is_err(), 'fetch price should fail');
        assert(result.unwrap_err() == 'EKB: Invalid price update', 'wrong err');

        spy
            .assert_emitted(
                @array![
                    (
                        ekubo.contract_address,
                        ekubo_contract::Event::InvalidPriceUpdate(
                            ekubo_contract::InvalidPriceUpdate {
                                yang: eth, quotes: array![Zero::zero(), expected_usdc_price, Zero::zero()].span()
                            }
                        )
                    )
                ]
            );
    }
}
