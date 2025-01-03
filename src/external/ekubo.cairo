#[starknet::contract]
pub mod ekubo {
    use access_control::access_control_component;
    use core::num::traits::Zero;
    use opus::external::interfaces::{IEkuboOracleExtensionDispatcher, IEkuboOracleExtensionDispatcherTrait};
    use opus::external::roles::ekubo_roles;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IEkubo::IEkubo;
    use opus::interfaces::IOracle::IOracle;
    use opus::types::QuoteTokenInfo;
    use opus::utils::math::{median_of_three, convert_ekubo_oracle_price_to_wad};
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::{Wad, WAD_DECIMALS};

    //
    // Constants
    //

    const LOOP_START: u32 = 1;
    pub const NUM_QUOTE_TOKENS: u32 = 3;

    pub const MIN_TWAP_DURATION: u64 = 60; // seconds; acts as a sanity check

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        // interface to the Ekubo oracle extension
        oracle_extension: IEkuboOracleExtensionDispatcher,
        // Collection of quote tokens, in no particular order
        // Starts from 1
        // (idx) -> (token to be quoted per yang)
        quote_tokens: LegacyMap<u32, QuoteTokenInfo>,
        // The duration in seconds for reading TWAP from Ekubo
        twap_duration: u64
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AccessControlEvent: access_control_component::Event,
        InvalidPriceUpdate: InvalidPriceUpdate,
        QuoteTokensUpdated: QuoteTokensUpdated,
        TwapDurationUpdated: TwapDurationUpdated
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct InvalidPriceUpdate {
        pub yang: ContractAddress,
        pub quotes: Span<Wad>
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct QuoteTokensUpdated {
        pub quote_tokens: Span<QuoteTokenInfo>
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct TwapDurationUpdated {
        pub old_duration: u64,
        pub new_duration: u64
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        oracle_extension: ContractAddress,
        twap_duration: u64,
        quote_tokens: Span<ContractAddress>
    ) {
        self.access_control.initializer(admin, Option::Some(ekubo_roles::default_admin_role()));

        self.oracle_extension.write(IEkuboOracleExtensionDispatcher { contract_address: oracle_extension });

        self.set_twap_duration_helper(twap_duration);
        self.set_quote_tokens_helper(quote_tokens);
    }

    //
    // External functions
    //

    #[abi(embed_v0)]
    impl IEkuboImpl of IEkubo<ContractState> {
        fn get_quote_tokens(self: @ContractState) -> Span<QuoteTokenInfo> {
            let mut quote_tokens: Array<QuoteTokenInfo> = Default::default();
            let mut index: u32 = LOOP_START;
            let end_index = LOOP_START + NUM_QUOTE_TOKENS;
            loop {
                if index == end_index {
                    break quote_tokens.span();
                }
                quote_tokens.append(self.quote_tokens.read(index));
                index += 1;
            }
        }

        fn get_twap_duration(self: @ContractState) -> u64 {
            self.twap_duration.read()
        }

        fn set_quote_tokens(ref self: ContractState, quote_tokens: Span<ContractAddress>) {
            self.access_control.assert_has_role(ekubo_roles::SET_QUOTE_TOKENS);

            self.set_quote_tokens_helper(quote_tokens);
        }

        fn set_twap_duration(ref self: ContractState, twap_duration: u64) {
            self.access_control.assert_has_role(ekubo_roles::SET_TWAP_DURATION);

            self.set_twap_duration_helper(twap_duration);
        }
    }

    //
    // External oracle functions
    //

    #[abi(embed_v0)]
    impl IOracleImpl of IOracle<ContractState> {
        fn get_name(self: @ContractState) -> felt252 {
            'Ekubo'
        }

        fn get_oracles(self: @ContractState) -> Span<ContractAddress> {
            array![self.oracle_extension.read().contract_address].span()
        }

        fn fetch_price(ref self: ContractState, yang: ContractAddress) -> Result<Wad, felt252> {
            let price: Wad = self.fetch_median_price(yang)?; // propagate Err if any
            Result::Ok(price)
        }
    }

    //
    // Internal functions
    //

    #[generate_trait]
    impl EkuboHelpers of EkuboHelpersTrait {
        // Note that this function does not check for duplicate tokens.
        fn set_quote_tokens_helper(ref self: ContractState, quote_tokens: Span<ContractAddress>) {
            assert(quote_tokens.len() == NUM_QUOTE_TOKENS, 'EKB: Not 3 quote tokens');

            let mut index = LOOP_START;
            let mut quote_tokens_copy = quote_tokens;
            let mut quote_tokens_info: Array<QuoteTokenInfo> = Default::default();
            loop {
                match quote_tokens_copy.pop_front() {
                    Option::Some(quote_token) => {
                        let token = IERC20Dispatcher { contract_address: *quote_token };
                        let decimals: u8 = token.decimals();
                        assert(decimals <= WAD_DECIMALS, 'EKB: Too many decimals');

                        let quote_token_info = QuoteTokenInfo { address: *quote_token, decimals };
                        self.quote_tokens.write(index, quote_token_info);
                        quote_tokens_info.append(quote_token_info);
                        index += 1;
                    },
                    Option::None => { break; }
                }
            };

            self.emit(QuoteTokensUpdated { quote_tokens: quote_tokens_info.span() });
        }

        fn set_twap_duration_helper(ref self: ContractState, twap_duration: u64) {
            assert(twap_duration >= MIN_TWAP_DURATION, 'EKB: TWAP duration too low');

            let old_duration: u64 = self.twap_duration.read();
            self.twap_duration.write(twap_duration);

            self.emit(TwapDurationUpdated { old_duration, new_duration: twap_duration });
        }

        fn get_quotes(self: @ContractState, yang: ContractAddress) -> Span<Wad> {
            let oracle_extension = self.oracle_extension.read();
            let twap_duration = self.twap_duration.read();

            let mut quotes: Array<Wad> = Default::default();
            let mut index: u32 = LOOP_START;
            let end_index = LOOP_START + NUM_QUOTE_TOKENS;
            loop {
                if index == end_index {
                    break quotes.span();
                }

                let quote_token_info: QuoteTokenInfo = self.quote_tokens.read(index);
                let quote: u256 = oracle_extension
                    .get_price_x128_over_last(yang, quote_token_info.address, twap_duration);

                let base_decimals: u8 = IERC20Dispatcher { contract_address: yang }.decimals();
                let scaled_quote: Wad = convert_ekubo_oracle_price_to_wad(
                    quote, base_decimals, quote_token_info.decimals
                );

                quotes.append(scaled_quote);
                index += 1;
            }
        }

        fn fetch_median_price(ref self: ContractState, yang: ContractAddress) -> Result<Wad, felt252> {
            let quotes = self.get_quotes(yang);

            // if we receive what we consider a valid price from the oracle,
            // return it back, otherwise emit an event about the update being invalid
            let mut quotes_copy = quotes;
            loop {
                match quotes_copy.pop_front() {
                    Option::Some(quote) => {
                        if quote.is_zero() {
                            self.emit(InvalidPriceUpdate { yang, quotes });
                            break Result::Err('EKB: Invalid price update');
                        }
                    },
                    Option::None => {
                        let price: Wad = median_of_three(quotes);
                        break Result::Ok(price);
                    }
                };
            }
        }
    }
}
