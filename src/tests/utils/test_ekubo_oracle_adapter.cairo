mod test_ekubo_oracle_adapter {
    use core::num::traits::Zero;
    use opus::constants;
    use opus::mock::mock_ekubo_oracle_extension::{
        IMockEkuboOracleExtensionDispatcher, IMockEkuboOracleExtensionDispatcherTrait, set_next_ekubo_prices
    };
    use opus::tests::common;
    use opus::tests::utils::mock_ekubo_oracle_adapter::mock_ekubo_oracle_adapter;
    use opus::utils::ekubo_oracle_adapter::ekubo_oracle_adapter_component::{
        EkuboOracleAdapterHelpers, MIN_TWAP_DURATION
    };
    use opus::utils::math::convert_ekubo_oracle_price_to_wad;
    use snforge_std::{declare, ContractClass, spy_events, SpyOn, EventSpy, EventAssertions, EventFetcher, test_address};
    use starknet::ContractAddress;
    use wadray::{Wad, WAD_DECIMALS, WAD_ONE};

    fn state() -> mock_ekubo_oracle_adapter::ContractState {
        mock_ekubo_oracle_adapter::contract_state_for_testing()
    }

    fn invalid_token(token_class: Option<ContractClass>) -> ContractAddress {
        common::deploy_token('Invalid', 'INV', (WAD_DECIMALS + 1).into(), WAD_ONE.into(), common::admin(), token_class)
    }

    #[test]
    fn test_set_oracle_extension() {
        let mut state = state();

        let mock_ekubo = common::mock_ekubo_oracle_extension_deploy(Option::None);
        state.ekubo_oracle_adapter.set_oracle_extension(mock_ekubo.contract_address);

        assert_eq!(
            state.ekubo_oracle_adapter.get_oracle_extension().contract_address,
            mock_ekubo.contract_address,
            "wrong extension addr"
        );
    }

    #[test]
    #[should_panic(expected: ('EOC: Zero address for extension',))]
    fn test_set_oracle_extension_zero_address() {
        let mut state = state();

        state.ekubo_oracle_adapter.set_oracle_extension(Zero::zero());
    }

    #[test]
    fn test_set_quote_tokens() {
        let mut state = state();

        let token_class = declare("erc20_mintable").unwrap();
        let quote_tokens = common::quote_tokens(Option::Some(token_class));

        let mut spy = spy_events(SpyOn::One(test_address()));

        state.ekubo_oracle_adapter.set_quote_tokens(quote_tokens);

        spy.fetch_events();

        assert_eq!(spy.events.len(), 1, "wrong number of events");

        let (_, event) = spy.events.at(0);
        assert_eq!(event.keys[1], @selector!("QuoteTokensUpdated"), "wrong event name");
        assert_eq!(*event.data[0], 3, "wrong span length in event");
        assert_eq!(*event.data[1], (*quote_tokens[0]).into(), "wrong token in event #1");
        assert_eq!(*event.data[2], constants::DAI_DECIMALS.into(), "wrong decimals in event #1");
        assert_eq!(*event.data[3], (*quote_tokens[1]).into(), "wrong token in event #2");
        assert_eq!(*event.data[4], constants::USDC_DECIMALS.into(), "wrong decimals in event #2");
        assert_eq!(*event.data[5], (*quote_tokens[2]).into(), "wrong token in event #3");
        assert_eq!(*event.data[6], constants::USDT_DECIMALS.into(), "wrong decimals in event #3");
    }

    #[test]
    #[should_panic(expected: ('EOC: Not 3 quote tokens',))]
    fn test_set_quote_tokens_too_few_tokens() {
        let mut state = state();

        let token_class = declare("erc20_mintable").unwrap();
        let quote_tokens = common::quote_tokens(Option::Some(token_class));
        let quote_tokens: Span<ContractAddress> = array![*quote_tokens[0], *quote_tokens[1]].span();
        state.ekubo_oracle_adapter.set_quote_tokens(quote_tokens);
    }

    #[test]
    #[should_panic(expected: ('EOC: Not 3 quote tokens',))]
    fn test_set_quote_tokens_too_many_tokens() {
        let mut state = state();

        let token_class = declare("erc20_mintable").unwrap();
        let quote_tokens = common::quote_tokens(Option::Some(token_class));
        let invalid_token: ContractAddress = invalid_token(Option::Some(token_class));
        let quote_tokens: Span<ContractAddress> = array![
            *quote_tokens[0], *quote_tokens[1], *quote_tokens[2], invalid_token
        ]
            .span();
        state.ekubo_oracle_adapter.set_quote_tokens(quote_tokens);
    }

    #[test]
    #[should_panic(expected: ('EOC: Too many decimals',))]
    fn test_set_quote_tokens_too_many_decimals() {
        let mut state = state();

        let token_class = declare("erc20_mintable").unwrap();
        let quote_tokens = common::quote_tokens(Option::Some(token_class));

        let invalid_token: ContractAddress = invalid_token(Option::Some(token_class));
        let quote_tokens: Span<ContractAddress> = array![*quote_tokens[0], *quote_tokens[1], invalid_token].span();
        state.ekubo_oracle_adapter.set_quote_tokens(quote_tokens);
    }

    #[test]
    fn test_set_twap_duration_pass() {
        let mut state = state();

        let mut spy = spy_events(SpyOn::One(test_address()));

        let twap_duration: u64 = 5 * 60;
        state.ekubo_oracle_adapter.set_twap_duration(twap_duration);

        spy.fetch_events();

        assert_eq!(spy.events.len(), 1, "wrong number of events");

        let (_, event) = spy.events.at(0);
        assert_eq!(event.keys[1], @selector!("TwapDurationUpdated"), "wrong event name");
        assert_eq!(*event.data[0], 0, "wrong old duration in event");
        assert_eq!(*event.data[1], twap_duration.into(), "wrong new duration in event");
    }

    #[test]
    #[should_panic(expected: ('EOC: TWAP duration too low',))]
    fn test_set_twap_duration_zero_fail() {
        let mut state = state();

        state.ekubo_oracle_adapter.set_twap_duration(MIN_TWAP_DURATION - 1);
    }

    #[test]
    fn test_get_quotes() {
        let mut state = state();

        let mock_ekubo = common::mock_ekubo_oracle_extension_deploy(Option::None);
        state.ekubo_oracle_adapter.set_oracle_extension(mock_ekubo.contract_address);

        let token_class = declare("erc20_mintable").unwrap();
        let quote_tokens = common::quote_tokens(Option::Some(token_class));
        state.ekubo_oracle_adapter.set_quote_tokens(quote_tokens);

        let eth = common::eth_token_deploy(Option::Some(token_class));

        // Use real values to ensure correctness
        let eth_dai_x128_price: u256 = 1136300885434234067297094194169939045041922;
        let eth_usdc_x128_price: u256 = 1135036808904793908619842566045;
        let eth_usdt_x128_price: u256 = 1134582885198987280493503591381;
        let prices = array![eth_dai_x128_price, eth_usdc_x128_price, eth_usdt_x128_price].span();

        set_next_ekubo_prices(mock_ekubo, eth, quote_tokens, prices);

        let exact_eth_dai_price: Wad = convert_ekubo_oracle_price_to_wad(
            eth_dai_x128_price, WAD_DECIMALS, constants::DAI_DECIMALS
        );
        let exact_eth_usdc_price: Wad = convert_ekubo_oracle_price_to_wad(
            eth_usdc_x128_price, WAD_DECIMALS, constants::USDC_DECIMALS
        );
        let exact_eth_usdt_price: Wad = convert_ekubo_oracle_price_to_wad(
            eth_usdt_x128_price, WAD_DECIMALS, constants::USDT_DECIMALS
        );
        let expected_eth_quotes: Span<Wad> = array![exact_eth_dai_price, exact_eth_usdc_price, exact_eth_usdt_price]
            .span();
        assert_eq!(state.ekubo_oracle_adapter.get_quotes(eth), expected_eth_quotes, "wrong quotes #1");

        let wbtc = common::wbtc_token_deploy(Option::Some(token_class));

        // Use real values to ensure correctness
        let wbtc_dai_x128_price: u256 = 318614252893849538883488508055166997992904971664081878;
        let wbtc_usdc_x128_price: u256 = 318205074905452844409073501798802864775508;
        let wbtc_usdt_x128_price: u256 = 317746236343423991390061019847542458957558;
        let prices = array![wbtc_dai_x128_price, wbtc_usdc_x128_price, wbtc_usdt_x128_price].span();

        set_next_ekubo_prices(mock_ekubo, wbtc, quote_tokens, prices);

        let exact_wbtc_dai_price: Wad = convert_ekubo_oracle_price_to_wad(
            wbtc_dai_x128_price, constants::WBTC_DECIMALS, constants::DAI_DECIMALS
        );
        let exact_wbtc_usdc_price: Wad = convert_ekubo_oracle_price_to_wad(
            wbtc_usdc_x128_price, constants::WBTC_DECIMALS, constants::USDC_DECIMALS
        );
        let exact_wbtc_usdt_price: Wad = convert_ekubo_oracle_price_to_wad(
            wbtc_usdt_x128_price, constants::WBTC_DECIMALS, constants::USDT_DECIMALS
        );
        let expected_wbtc_quotes: Span<Wad> = array![exact_wbtc_dai_price, exact_wbtc_usdc_price, exact_wbtc_usdt_price]
            .span();
        assert_eq!(state.ekubo_oracle_adapter.get_quotes(wbtc), expected_wbtc_quotes, "wrong quotes #2");
    }
}
