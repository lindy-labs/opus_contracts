mod test_ekubo_oracle_config {
    use core::num::traits::Zero;
    use opus::constants;
    use opus::tests::common;
    use opus::tests::utils::mock_ekubo_oracle_config::mock_ekubo_oracle_config;
    use opus::utils::ekubo_oracle_config::ekubo_oracle_config_component::{EkuboOracleConfigHelpers, MIN_TWAP_DURATION};
    use snforge_std::{declare, ContractClass, spy_events, SpyOn, EventSpy, EventAssertions, EventFetcher, test_address};
    use starknet::ContractAddress;
    use wadray::{WAD_DECIMALS, WAD_ONE};

    fn state() -> mock_ekubo_oracle_config::ContractState {
        mock_ekubo_oracle_config::contract_state_for_testing()
    }

    fn invalid_token(token_class: Option<ContractClass>) -> ContractAddress {
        common::deploy_token('Invalid', 'INV', (WAD_DECIMALS + 1).into(), WAD_ONE.into(), common::admin(), token_class)
    }

    fn mock_ekubo_oracle() -> ContractAddress {
        'mock ekubo oracle'.try_into().unwrap()
    }

    #[test]
    fn test_set_oracle_extension() {
        let mut state = state();

        let oracle_extension = mock_ekubo_oracle();
        state.ekubo_oracle_config.set_oracle_extension(oracle_extension);

        assert_eq!(
            state.ekubo_oracle_config.get_oracle_extension().contract_address, oracle_extension, "wrong extension addr"
        );
    }

    #[test]
    #[should_panic(expected: ('EOC: Zero address for extension',))]
    fn test_set_oracle_extension_zero_address() {
        let mut state = state();

        state.ekubo_oracle_config.set_oracle_extension(Zero::zero());
    }

    #[test]
    fn test_set_quote_tokens() {
        let mut state = state();

        let token_class = declare("erc20_mintable").unwrap();
        let quote_tokens = common::quote_tokens(Option::Some(token_class));

        let mut spy = spy_events(SpyOn::One(test_address()));

        state.ekubo_oracle_config.set_quote_tokens(quote_tokens);

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
        state.ekubo_oracle_config.set_quote_tokens(quote_tokens);
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
        state.ekubo_oracle_config.set_quote_tokens(quote_tokens);
    }

    #[test]
    #[should_panic(expected: ('EOC: Too many decimals',))]
    fn test_set_quote_tokens_too_many_decimals() {
        let mut state = state();

        let token_class = declare("erc20_mintable").unwrap();
        let quote_tokens = common::quote_tokens(Option::Some(token_class));

        let invalid_token: ContractAddress = invalid_token(Option::Some(token_class));
        let quote_tokens: Span<ContractAddress> = array![*quote_tokens[0], *quote_tokens[1], invalid_token].span();
        state.ekubo_oracle_config.set_quote_tokens(quote_tokens);
    }

    #[test]
    fn test_set_twap_duration_pass() {
        let mut state = state();

        let mut spy = spy_events(SpyOn::One(test_address()));

        let twap_duration: u64 = 5 * 60;
        state.ekubo_oracle_config.set_twap_duration(twap_duration);

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

        state.ekubo_oracle_config.set_twap_duration(MIN_TWAP_DURATION - 1);
    }
}
