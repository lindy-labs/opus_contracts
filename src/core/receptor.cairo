#[starknet::contract]
pub mod receptor {
    use access_control::access_control_component;
    use core::num::traits::Zero;
    use opus::core::roles::receptor_roles;
    use opus::external::interfaces::{IEkuboOracleExtensionDispatcher, IEkuboOracleExtensionDispatcherTrait};
    use opus::interfaces::IReceptor::IReceptor;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::types::QuoteTokenInfo;
    use opus::utils::math::pow;
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::Wad;

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    //
    // Constants
    //

    pub const NUM_QUOTE_TOKENS: u32 = 3;
    const TWO_POW_128: u256 = 0x100000000000000000000000000000000;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        shrine: IShrineDispatcher,
        oracle_extension: IEkuboOracleExtensionDispatcher,
        quote_tokens: LegacyMap<u32, QuoteTokenInfo>,
        twap_duration: u64,
    }

    //
    // Events 
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AccessControlEvent: access_control_component::Event,
        QuoteTokensUpdated: QuoteTokensUpdated,
        Record: Record,
        TwapDurationUpdated: TwapDurationUpdated,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct QuoteTokensUpdated {
        quote_tokens: Span<QuoteTokenInfo>
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct Record {
        quotes: Span<Wad>
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct TwapDurationUpdated {
        twap_duration: u64
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        shrine: ContractAddress,
        oracle_extension: ContractAddress,
        twap_duration: u64,
        quote_tokens: Span<QuoteTokenInfo>
    ) {
        self.access_control.initializer(admin, Option::Some(receptor_roles::default_admin_role()));

        self.shrine.write(IShrineDispatcher { contract_address: shrine });

        self.set_oracle_extension_helper(oracle_extension);
        self.set_twap_duration_helper(twap_duration);
        self.set_quote_tokens_helper(quote_tokens);
    }

    //
    // External Receptor functions
    //

    #[abi(embed_v0)]
    impl IReceptorImpl of IReceptor<ContractState> {
        fn get_oracle_extension(self: @ContractState) -> ContractAddress {
            self.oracle_extension.read().contract_address
        }

        fn get_quote_tokens(self: @ContractState) -> Span<QuoteTokenInfo> {
            let mut quote_tokens: Array<QuoteTokenInfo> = Default::default();
            let mut index: u32 = 0;
            loop {
                if index == NUM_QUOTE_TOKENS {
                    break quote_tokens.span();
                }
                quote_tokens.append(self.quote_tokens.read(index));
                index += 1;
            }
        }

        fn get_quotes(self: @ContractState) -> Span<Wad> {
            let oracle_extension = self.oracle_extension.read();
            let ts = get_block_timestamp();
            let start_time = ts - self.twap_duration.read();
            let cash = self.shrine.read().contract_address;

            let mut quotes: Array<Wad> = Default::default();
            let mut index: u32 = 0;
            loop {
                if index == NUM_QUOTE_TOKENS {
                    break quotes.span();
                }

                let quote_token_info: QuoteTokenInfo = self.quote_tokens.read(index);

                let quote: u256 = oracle_extension
                    .get_price_x128_over_period(cash, quote_token_info.address, start_time, ts);

                let scaled_quote: Wad = scale_x128_to_wad(quote, quote_token_info.decimals);

                assert(scaled_quote.is_non_zero(), 'REC: Quote is zero');

                quotes.append(scaled_quote);
                index += 1;
            }
        }

        fn get_twap_duration(self: @ContractState) -> u64 {
            self.twap_duration.read()
        }

        fn get_yin_price(self: @ContractState) -> Wad {
            let quotes = self.get_quotes();
            get_median_quote(quotes)
        }

        fn set_oracle_extension(ref self: ContractState, oracle_extension: ContractAddress) {
            self.access_control.assert_has_role(receptor_roles::SET_ORACLE_EXTENSION);

            self.set_oracle_extension_helper(oracle_extension);
        }

        fn set_quote_tokens(ref self: ContractState, quote_tokens: Span<QuoteTokenInfo>) {
            self.access_control.assert_has_role(receptor_roles::SET_QUOTE_TOKENS);

            self.set_quote_tokens_helper(quote_tokens);
        }

        fn set_twap_duration(ref self: ContractState, twap_duration: u64) {
            self.access_control.assert_has_role(receptor_roles::SET_TWAP_DURATION);

            self.set_twap_duration_helper(twap_duration);
        }

        fn update_yin_price(ref self: ContractState) {
            let quotes = self.get_quotes();
            let yin_price: Wad = get_median_quote(quotes);
            self.shrine.read().update_yin_spot_price(yin_price);

            self.emit(Record { quotes });
        }
    }

    //
    // Internal Receptor functions
    //

    #[generate_trait]
    impl ReceptorHelpers of ReceptorHelpersTrait {
        fn set_oracle_extension_helper(ref self: ContractState, oracle_extension: ContractAddress) {
            assert(oracle_extension.is_non_zero(), 'REC: Zero address for extension');

            self.oracle_extension.write(IEkuboOracleExtensionDispatcher { contract_address: oracle_extension });
        }

        // Note that this function does not check for duplicate tokens.
        fn set_quote_tokens_helper(ref self: ContractState, quote_tokens: Span<QuoteTokenInfo>) {
            let mut index = 0;
            let num_quote_tokens = quote_tokens.len();
            assert(num_quote_tokens == NUM_QUOTE_TOKENS, 'REC: Not 3 quote tokens');

            let mut quote_tokens_copy = quote_tokens;
            loop {
                if index == num_quote_tokens {
                    break;
                }
                let quote_token_info: QuoteTokenInfo = *quote_tokens_copy.pop_front().unwrap();
                self.quote_tokens.write(index, quote_token_info);
                index += 1;
            };

            self.emit(QuoteTokensUpdated { quote_tokens });
        }

        fn set_twap_duration_helper(ref self: ContractState, twap_duration: u64) {
            assert(twap_duration.is_non_zero(), 'REC: TWAP duration is 0');

            self.twap_duration.write(twap_duration);

            self.emit(TwapDurationUpdated { twap_duration });
        }
    }

    // Returns the median of three Wad values
    fn get_median_quote(quotes: Span<Wad>) -> Wad {
        let a = *quotes[0];
        let b = *quotes[1];
        let c = *quotes[2];

        if (a <= b && b <= c) || (c <= b && b <= a) {
            b
        } else if (b <= a && a <= c) || (c <= a && a <= b) {
            a
        } else {
            c
        }
    }

    // If the quote token has less than 18 decimal precision, then the
    // x128 value needs to be scaled up by the quote token's decimals
    pub fn scale_x128_to_wad(n: u256, decimals: u8) -> Wad {
        let sqrt: u256 = n / TWO_POW_128;
        let unscaled: u128 = (sqrt * sqrt).try_into().unwrap();
        pow(unscaled, decimals).into()
    }
}
