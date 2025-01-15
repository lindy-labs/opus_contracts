mod test_ekubo {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::num::traits::Zero;
    use core::result::ResultTrait;
    use opus::constants;
    use opus::core::shrine::shrine;
    use opus::external::ekubo::ekubo as ekubo_contract;
    use opus::external::interfaces::{IEkuboOracleExtensionDispatcher, IEkuboOracleExtensionDispatcherTrait};
    use opus::external::roles::ekubo_roles;
    use opus::interfaces::IEkubo::{IEkuboDispatcher, IEkuboDispatcherTrait};
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::mock::mock_ekubo_oracle_extension::{
        IMockEkuboOracleExtensionDispatcher, IMockEkuboOracleExtensionDispatcherTrait, set_next_ekubo_prices
    };
    use opus::tests::common;
    use opus::tests::external::utils::{ekubo_utils, mock_eth_token_addr, ekubo_utils::EkuboTestConfig};
    use opus::utils::ekubo_oracle_adapter::{
        ekubo_oracle_adapter_component, IEkuboOracleAdapterDispatcher, IEkuboOracleAdapterDispatcherTrait
    };
    use opus::utils::math::convert_ekubo_oracle_price_to_wad;
    use snforge_std::{declare, start_prank, CheatTarget, spy_events, SpyOn, EventSpy, EventAssertions};
    use starknet::ContractAddress;
    use wadray::{Wad, WAD_DECIMALS, WAD_SCALE};

    //
    // Tests - Deployment and setters
    //

    #[test]
    fn test_ekubo_setup() {
        let EkuboTestConfig { ekubo, mock_ekubo, .. } = ekubo_utils::ekubo_deploy(
            Option::None, Option::None, Option::None
        );
        let oracle = IOracleDispatcher { contract_address: ekubo.contract_address };

        // Check permissions
        let ekubo_ac = IAccessControlDispatcher { contract_address: ekubo.contract_address };
        let admin: ContractAddress = ekubo_utils::admin();

        assert(ekubo_ac.get_admin() == admin, 'wrong admin');
        assert(ekubo_ac.get_roles(admin) == ekubo_roles::default_admin_role(), 'wrong admin role');

        assert(oracle.get_name() == 'Ekubo', 'wrong name');
        let oracles: Span<ContractAddress> = array![mock_ekubo.contract_address].span();
        assert(oracle.get_oracles() == oracles, 'wrong oracle addresses');
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_oracle_extension_unauthorized() {
        let EkuboTestConfig { ekubo, .. } = ekubo_utils::ekubo_deploy(Option::None, Option::None, Option::None);
        let ekubo_oracle_adapter = IEkuboOracleAdapterDispatcher { contract_address: ekubo.contract_address };

        start_prank(CheatTarget::One(ekubo.contract_address), common::badguy());
        ekubo_oracle_adapter.set_oracle_extension(Zero::zero());
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_quote_tokens_unauthorized() {
        let EkuboTestConfig { ekubo, quote_tokens, .. } = ekubo_utils::ekubo_deploy(
            Option::None, Option::None, Option::None
        );
        let ekubo_oracle_adapter = IEkuboOracleAdapterDispatcher { contract_address: ekubo.contract_address };

        start_prank(CheatTarget::One(ekubo.contract_address), common::badguy());
        ekubo_oracle_adapter.set_quote_tokens(quote_tokens);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_twap_duration_unauthorized() {
        let EkuboTestConfig { ekubo, .. } = ekubo_utils::ekubo_deploy(Option::None, Option::None, Option::None);
        let ekubo_oracle_adapter = IEkuboOracleAdapterDispatcher { contract_address: ekubo.contract_address };

        start_prank(CheatTarget::One(ekubo.contract_address), common::badguy());
        ekubo_oracle_adapter.set_twap_duration(ekubo_oracle_adapter_component::MIN_TWAP_DURATION + 1);
    }

    //
    // Tests - Functionality
    //

    #[test]
    fn test_fetch_price_pass() {
        let token_class = declare("erc20_mintable").unwrap();
        let EkuboTestConfig { ekubo, mock_ekubo, quote_tokens } = ekubo_utils::ekubo_deploy(
            Option::None, Option::None, Option::Some(token_class)
        );
        let oracle = IOracleDispatcher { contract_address: ekubo.contract_address };

        let eth = common::eth_token_deploy(Option::Some(token_class));

        // Use real values to ensure correctness
        let eth_dai_x128_price: u256 = 1136300885434234067297094194169939045041922;
        let eth_usdc_x128_price: u256 = 1135036808904793908619842566045;
        let eth_usdt_x128_price: u256 = 1134582885198987280493503591381;
        let prices = array![eth_dai_x128_price, eth_usdc_x128_price, eth_usdt_x128_price].span();

        set_next_ekubo_prices(mock_ekubo, eth, quote_tokens, prices);

        let result: Result<Wad, felt252> = oracle.fetch_price(eth);
        assert(result.is_ok(), 'fetch price failed #1');
        let actual_price: Wad = result.unwrap();
        let exact_eth_usdc_price: Wad = convert_ekubo_oracle_price_to_wad(
            eth_usdc_x128_price, WAD_DECIMALS, constants::USDC_DECIMALS
        );
        assert_eq!(actual_price, exact_eth_usdc_price, "wrong price #1");

        let expected_price: Wad = 3335573392107353791360_u128.into();
        let error_margin: Wad = 1_u128.into();
        common::assert_equalish(actual_price, expected_price, error_margin, 'wrong converted price #1');

        let wbtc = common::wbtc_token_deploy(Option::Some(token_class));

        // Use real values to ensure correctness
        let wbtc_dai_x128_price: u256 = 318614252893849538883488508055166997992904971664081878;
        let wbtc_usdc_x128_price: u256 = 318205074905452844409073501798802864775508;
        let wbtc_usdt_x128_price: u256 = 317746236343423991390061019847542458957558;
        let prices = array![wbtc_dai_x128_price, wbtc_usdc_x128_price, wbtc_usdt_x128_price].span();

        set_next_ekubo_prices(mock_ekubo, wbtc, quote_tokens, prices);

        let exact_wbtc_usdc_price: Wad = convert_ekubo_oracle_price_to_wad(
            wbtc_usdc_x128_price, constants::WBTC_DECIMALS, constants::USDC_DECIMALS
        );
        let result: Result<Wad, felt252> = oracle.fetch_price(wbtc);
        assert(result.is_ok(), 'fetch price failed #2');
        let actual_price: Wad = result.unwrap();
        assert_eq!(actual_price, exact_wbtc_usdc_price, "wrong price #2");

        let expected_price: Wad = 93512066988585665215326_u128.into();
        let error_margin: Wad = 1_u128.into();
        common::assert_equalish(actual_price, expected_price, error_margin, 'wrong converted price #2');
    }

    #[test]
    fn test_fetch_price_more_than_one_invalid_price_fail() {
        let token_class = declare("erc20_mintable").unwrap();
        let EkuboTestConfig { ekubo, mock_ekubo, quote_tokens } = ekubo_utils::ekubo_deploy(
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

        set_next_ekubo_prices(mock_ekubo, eth, quote_tokens, prices);

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
