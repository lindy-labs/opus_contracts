mod test_receptor {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::constants;
    use opus::core::receptor::receptor as receptor_contract;
    use opus::core::roles::receptor_roles;
    use opus::core::shrine::shrine as shrine_contract;
    use opus::external::interfaces::{ITaskDispatcher, ITaskDispatcherTrait};
    use opus::interfaces::IReceptor::{IReceptorDispatcher, IReceptorDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::mock::mock_ekubo_oracle_extension::set_next_ekubo_prices;
    use opus::tests::common;
    use opus::tests::receptor::utils::receptor_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::QuoteTokenInfo;
    use snforge_std::{
        declare, start_warp, start_prank, stop_prank, CheatTarget, spy_events, SpyOn, EventSpy, EventAssertions
    };
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::Wad;


    #[test]
    fn test_receptor_deploy() {
        let token_class = declare("erc20_mintable").unwrap();
        let (_, receptor, mock_ekubo_oracle_extension_addr, quote_tokens) = receptor_utils::receptor_deploy(
            Option::None, Option::Some(token_class)
        );

        let receptor_ac = IAccessControlDispatcher { contract_address: receptor.contract_address };
        let admin = shrine_utils::admin();
        assert(receptor_ac.get_admin() == admin, 'wrong admin');
        assert(receptor_ac.get_roles(admin) == receptor_roles::default_admin_role(), 'wrong role');

        assert_eq!(receptor.get_oracle_extension(), mock_ekubo_oracle_extension_addr, "wrong extension addr");
        assert_eq!(receptor.get_twap_duration(), receptor_utils::INITIAL_TWAP_DURATION, "wrong twap duration");

        let expected_quote_tokens_info: Span<QuoteTokenInfo> = array![
            QuoteTokenInfo { address: *quote_tokens[0], decimals: constants::DAI_DECIMALS },
            QuoteTokenInfo { address: *quote_tokens[1], decimals: constants::USDC_DECIMALS },
            QuoteTokenInfo { address: *quote_tokens[2], decimals: constants::USDT_DECIMALS },
        ]
            .span();
        assert_eq!(receptor.get_quote_tokens(), expected_quote_tokens_info, "wrong quote tokens");
    }

    // Parameters

    #[test]
    fn test_set_oracle_extension() {
        let token_class = declare("erc20_mintable").unwrap();
        let (_, receptor, _, _) = receptor_utils::receptor_deploy(Option::None, Option::Some(token_class));

        start_prank(CheatTarget::One(receptor.contract_address), shrine_utils::admin());
        let new_addr: ContractAddress = receptor_utils::mock_oracle_extension();
        receptor.set_oracle_extension(new_addr);

        assert_eq!(receptor.get_oracle_extension(), new_addr, "wrong extension addr");
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_oracle_extension_unauthorized() {
        let token_class = declare("erc20_mintable").unwrap();
        let (_, receptor, _, _) = receptor_utils::receptor_deploy(Option::None, Option::Some(token_class));

        start_prank(CheatTarget::One(receptor.contract_address), common::badguy());
        receptor.set_oracle_extension(receptor_utils::mock_oracle_extension());
    }

    #[test]
    fn test_set_quote_tokens() {
        let token_class = declare("erc20_mintable").unwrap();
        let (_, receptor, _, quote_tokens) = receptor_utils::receptor_deploy(Option::None, Option::Some(token_class));
        let mut spy = spy_events(SpyOn::One(receptor.contract_address));

        start_prank(CheatTarget::One(receptor.contract_address), shrine_utils::admin());

        let lusd: ContractAddress = common::lusd_token_deploy(Option::Some(token_class));
        let new_quote_tokens: Span<ContractAddress> = array![*quote_tokens[0], *quote_tokens[1], lusd].span();
        receptor.set_quote_tokens(new_quote_tokens);

        let expected_quote_tokens_info: Span<QuoteTokenInfo> = array![
            QuoteTokenInfo { address: *quote_tokens[0], decimals: constants::DAI_DECIMALS },
            QuoteTokenInfo { address: *quote_tokens[1], decimals: constants::USDC_DECIMALS },
            QuoteTokenInfo { address: lusd, decimals: constants::LUSD_DECIMALS },
        ]
            .span();
        assert_eq!(receptor.get_quote_tokens(), expected_quote_tokens_info, "wrong quote tokens");

        let expected_events = array![
            (
                receptor.contract_address,
                receptor_contract::Event::QuoteTokensUpdated(
                    receptor_contract::QuoteTokensUpdated { quote_tokens: expected_quote_tokens_info }
                )
            )
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('REC: Too many decimals',))]
    fn test_set_quote_tokens_too_many_decimals() {
        let token_class = declare("erc20_mintable").unwrap();
        let (_, receptor, _, quote_tokens) = receptor_utils::receptor_deploy(Option::None, Option::Some(token_class));

        start_prank(CheatTarget::One(receptor.contract_address), shrine_utils::admin());

        let invalid_token: ContractAddress = receptor_utils::invalid_token(Option::Some(token_class));
        let new_quote_tokens: Span<ContractAddress> = array![*quote_tokens[0], *quote_tokens[1], invalid_token].span();
        receptor.set_quote_tokens(new_quote_tokens);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_quote_tokens_unauthorized() {
        let token_class = declare("erc20_mintable").unwrap();
        let (_, receptor, _, quote_tokens) = receptor_utils::receptor_deploy(Option::None, Option::Some(token_class));

        start_prank(CheatTarget::One(receptor.contract_address), common::badguy());
        receptor.set_quote_tokens(quote_tokens);
    }

    #[test]
    fn test_set_twap_duration_pass() {
        let token_class = declare("erc20_mintable").unwrap();
        let (_, receptor, _, _) = receptor_utils::receptor_deploy(Option::None, Option::Some(token_class));
        let mut spy = spy_events(SpyOn::One(receptor.contract_address));

        start_prank(CheatTarget::One(receptor.contract_address), shrine_utils::admin().into());
        let old_duration: u64 = receptor_utils::INITIAL_TWAP_DURATION;
        let new_duration: u64 = old_duration + 1;
        receptor.set_twap_duration(new_duration);

        let expected_events = array![
            (
                receptor.contract_address,
                receptor_contract::Event::TwapDurationUpdated(
                    receptor_contract::TwapDurationUpdated { old_duration, new_duration }
                )
            )
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('REC: TWAP duration too low',))]
    fn test_set_twap_duration_zero_fail() {
        let token_class = declare("erc20_mintable").unwrap();
        let (_, receptor, _, _) = receptor_utils::receptor_deploy(Option::None, Option::Some(token_class));

        start_prank(CheatTarget::One(receptor.contract_address), shrine_utils::admin().into());
        receptor.set_twap_duration(receptor_contract::MIN_TWAP_DURATION - 1);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_twap_duration_unauthorized_fail() {
        let token_class = declare("erc20_mintable").unwrap();
        let (_, receptor, _, _) = receptor_utils::receptor_deploy(Option::None, Option::Some(token_class));

        start_prank(CheatTarget::One(receptor.contract_address), common::badguy());
        receptor.set_twap_duration(receptor_utils::INITIAL_TWAP_DURATION + 1);
    }

    #[test]
    fn test_set_update_frequency_pass() {
        let token_class = declare("erc20_mintable").unwrap();
        let (_, receptor, _, _) = receptor_utils::receptor_deploy(Option::None, Option::Some(token_class));
        let mut spy = spy_events(SpyOn::One(receptor.contract_address));

        let old_frequency: u64 = receptor_utils::INITIAL_UPDATE_FREQUENCY;
        let new_frequency: u64 = old_frequency + 1;
        start_prank(CheatTarget::One(receptor.contract_address), shrine_utils::admin());
        receptor.set_update_frequency(new_frequency);

        assert_eq!(receptor.get_update_frequency(), new_frequency, "wrong update frequency");

        let expected_events = array![
            (
                receptor.contract_address,
                receptor_contract::Event::UpdateFrequencyUpdated(
                    receptor_contract::UpdateFrequencyUpdated { old_frequency, new_frequency }
                )
            )
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_update_frequency_unauthorized() {
        let token_class = declare("erc20_mintable").unwrap();
        let (_, receptor, _, _) = receptor_utils::receptor_deploy(Option::None, Option::Some(token_class));
        start_prank(CheatTarget::One(receptor.contract_address), common::badguy());
        receptor.set_update_frequency(receptor_utils::INITIAL_UPDATE_FREQUENCY - 1);
    }

    #[test]
    #[should_panic(expected: ('REC: Frequency out of bounds',))]
    fn test_set_update_frequency_oob_lower() {
        let token_class = declare("erc20_mintable").unwrap();
        let (_, receptor, _, _) = receptor_utils::receptor_deploy(Option::None, Option::Some(token_class));

        let new_frequency: u64 = receptor_contract::LOWER_UPDATE_FREQUENCY_BOUND - 1;
        start_prank(CheatTarget::One(receptor.contract_address), shrine_utils::admin());
        receptor.set_update_frequency(new_frequency);
    }

    #[test]
    #[should_panic(expected: ('REC: Frequency out of bounds',))]
    fn test_set_update_frequency_oob_higher() {
        let token_class = declare("erc20_mintable").unwrap();
        let (_, receptor, _, _) = receptor_utils::receptor_deploy(Option::None, Option::Some(token_class));

        let new_frequency: u64 = receptor_contract::UPPER_UPDATE_FREQUENCY_BOUND + 1;
        start_prank(CheatTarget::One(receptor.contract_address), shrine_utils::admin());
        receptor.set_update_frequency(new_frequency);
    }

    // Core functionality

    #[test]
    fn test_update_yin_price() {
        let token_class = declare("erc20_mintable").unwrap();
        let (shrine, receptor, mock_ekubo_oracle_extension_addr, quote_tokens) = receptor_utils::receptor_deploy(
            Option::None, Option::Some(token_class)
        );
        let mut shrine_spy = spy_events(SpyOn::One(shrine.contract_address));
        let mut receptor_spy = spy_events(SpyOn::One(receptor.contract_address));

        let before_yin_spot_price: Wad = shrine.get_yin_spot_price();

        // actual mainnet values from 1727418625 start time to 1727429425 end time
        // converted in python
        let prices: Span<u256> = array![
            340309250276362099785975626643777172060, // 1.000079003081079 DAI / CASH
            340527434977254803682969657, // 1.0007201902894171 USDC / CASH
            340328625112763872478829777, // 1.000135940607925 USDT / CASH
        ]
            .span();
        set_next_ekubo_prices(mock_ekubo_oracle_extension_addr, shrine.contract_address, quote_tokens, prices,);

        let next_ts = get_block_timestamp() + receptor_utils::INITIAL_UPDATE_FREQUENCY;
        start_warp(CheatTarget::All, next_ts);

        let quotes: Span<Wad> = receptor.get_quotes();
        let expected_yin_spot_price: Wad = *quotes[2];
        let mut expected_prices: Span<Wad> = array![
            1000079003081079000_u128.into(), // DAI
            1000720190289417000_u128.into(), // USDC
            1000135940607925000_u128.into(), // USDT
        ]
            .span();
        let error_margin: Wad = 200_u128.into();

        let mut quotes_copy = quotes;
        loop {
            match quotes_copy.pop_front() {
                Option::Some(quote) => {
                    let expected: Wad = *expected_prices.pop_front().unwrap();
                    common::assert_equalish(*quote, expected, error_margin, 'wrong quote');
                },
                Option::None => { break; },
            };
        };

        start_prank(CheatTarget::One(receptor.contract_address), shrine_utils::admin());
        receptor.update_yin_price();

        let after_yin_spot_price: Wad = shrine.get_yin_spot_price();
        assert_eq!(after_yin_spot_price, expected_yin_spot_price, "wrong yin price in shrine #1");

        let expected_receptor_events = array![
            (
                receptor.contract_address,
                receptor_contract::Event::ValidQuotes(receptor_contract::ValidQuotes { quotes })
            )
        ];
        receptor_spy.assert_emitted(@expected_receptor_events);

        let expected_shrine_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::YinPriceUpdated(
                    shrine_contract::YinPriceUpdated {
                        old_price: before_yin_spot_price, new_price: after_yin_spot_price
                    }
                )
            )
        ];
        shrine_spy.assert_emitted(@expected_shrine_events);

        // test unsuccessful update due to a zero price quote
        let prices: Span<u256> = array![
            340309250276362099785975626643777172060, // 1.000158012403645039602034587 DAI / CASH
            0, // 1.001440899252887204535902704 USDC / CASH
            340328625112763872478829777, // 1.000271899695698999556601210 USDT / CASH
        ]
            .span();
        set_next_ekubo_prices(mock_ekubo_oracle_extension_addr, shrine.contract_address, quote_tokens, prices,);

        let next_ts = get_block_timestamp() + receptor_utils::INITIAL_UPDATE_FREQUENCY;
        start_warp(CheatTarget::All, next_ts);

        let quotes: Span<Wad> = receptor.get_quotes();

        receptor.update_yin_price();

        assert_eq!(shrine.get_yin_spot_price(), expected_yin_spot_price, "wrong yin price in shrine #2");

        let expected_receptor_events = array![
            (
                receptor.contract_address,
                receptor_contract::Event::InvalidQuotes(receptor_contract::InvalidQuotes { quotes })
            )
        ];
        receptor_spy.assert_emitted(@expected_receptor_events);
    }

    #[test]
    fn test_update_yin_price_via_execute_task() {
        let token_class = declare("erc20_mintable").unwrap();
        let (shrine, receptor, mock_ekubo_oracle_extension_addr, quote_tokens) = receptor_utils::receptor_deploy(
            Option::None, Option::Some(token_class)
        );

        // actual mainnet values from 1727418625 start time to 1727429425 end time
        // converted in python
        let prices: Span<u256> = array![
            340309250276362099785975626643777172060, // 1.000158012403645039602034587 DAI / CASH
            340527434977254803682969657, // 1.001440899252887204535902704 USDC / CASH
            340328625112763872478829777, // 1.000271899695698999556601210 USDT / CASH
        ]
            .span();
        set_next_ekubo_prices(mock_ekubo_oracle_extension_addr, shrine.contract_address, quote_tokens, prices,);

        let next_ts = get_block_timestamp() + receptor_utils::INITIAL_UPDATE_FREQUENCY;
        start_warp(CheatTarget::All, next_ts);

        ITaskDispatcher { contract_address: receptor.contract_address }.execute_task();

        let quotes: Span<Wad> = receptor.get_quotes();
        let expected_yin_spot_price: Wad = *quotes[2];

        let after_yin_spot_price: Wad = shrine.get_yin_spot_price();
        assert_eq!(after_yin_spot_price, expected_yin_spot_price, "wrong yin price in shrine #1");
    }

    #[test]
    fn test_probe_task() {
        let token_class = declare("erc20_mintable").unwrap();
        let (shrine, receptor, mock_ekubo_oracle_extension_addr, quote_tokens) = receptor_utils::receptor_deploy(
            Option::None, Option::Some(token_class)
        );

        // actual mainnet values from 1727418625 start time to 1727429425 end time
        // converted in python
        let prices: Span<u256> = array![
            340309250276362099785975626643777172060, // 1.000158012403645039602034587 DAI / CASH
            340527434977254803682969657, // 1.001440899252887204535902704 USDC / CASH
            340328625112763872478829777, // 1.000271899695698999556601210 USDT / CASH
        ]
            .span();
        set_next_ekubo_prices(mock_ekubo_oracle_extension_addr, shrine.contract_address, quote_tokens, prices,);

        let task = ITaskDispatcher { contract_address: receptor.contract_address };
        assert(task.probe_task(), 'should be ready 1');

        task.execute_task();
        assert(!task.probe_task(), 'should not be ready 1');

        start_warp(CheatTarget::All, get_block_timestamp() + receptor.get_update_frequency() - 1);
        assert(!task.probe_task(), 'should not be ready 2');

        start_warp(CheatTarget::All, get_block_timestamp() + 1);
        assert(task.probe_task(), 'should be ready 2');
    }
}
