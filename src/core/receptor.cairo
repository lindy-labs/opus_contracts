#[starknet::contract]
pub mod receptor {
    use access_control::access_control_component;
    use core::num::traits::Zero;
    use opus::core::roles::receptor_roles;
    use opus::external::interfaces::ITask;
    use opus::external::interfaces::{IEkuboOracleExtensionDispatcher, IEkuboOracleExtensionDispatcherTrait};
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IReceptor::IReceptor;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::types::QuoteTokenInfo;
    use opus::utils::math::{median_of_three, pow, scale_x128_to_wad};
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::{Wad, WAD_DECIMALS};

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

    const LOOP_START: u32 = 1;
    pub const NUM_QUOTE_TOKENS: u32 = 3;

    pub const MIN_TWAP_DURATION: u64 = 60; // seconds; acts as a sanity check

    pub const LOWER_UPDATE_FREQUENCY_BOUND: u64 = 15; // seconds (approx. Starknet block prod goal)
    pub const UPPER_UPDATE_FREQUENCY_BOUND: u64 = 4 * 60 * 60; // 4 hours * 60 minutes * 60 seconds

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        // Shrine associated with this module
        shrine: IShrineDispatcher,
        // Ekubo oracle extension for reading TWAP
        oracle_extension: IEkuboOracleExtensionDispatcher,
        // Collection of quote tokens, in no particular order
        // Starts from 1
        // (idx) -> (token to be quoted per CASH)
        quote_tokens: LegacyMap<u32, QuoteTokenInfo>,
        // The duration in seconds for reading TWAP from Ekubo
        twap_duration: u64,
        // Block timestamp of the last `update_yin_price_internal` execution
        last_update_yin_price_call_timestamp: u64,
        // The minimal time difference in seconds of how often we
        // want to update yin spot price,
        update_frequency: u64,
    }

    //
    // Events 
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AccessControlEvent: access_control_component::Event,
        InvalidQuotes: InvalidQuotes,
        QuoteTokensUpdated: QuoteTokensUpdated,
        ValidQuotes: ValidQuotes,
        TwapDurationUpdated: TwapDurationUpdated,
        UpdateFrequencyUpdated: UpdateFrequencyUpdated,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct InvalidQuotes {
        pub quotes: Span<Wad>
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct ValidQuotes {
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

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct UpdateFrequencyUpdated {
        pub old_frequency: u64,
        pub new_frequency: u64
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
        update_frequency: u64,
        twap_duration: u64,
        quote_tokens: Span<ContractAddress>
    ) {
        self.access_control.initializer(admin, Option::Some(receptor_roles::default_admin_role()));

        self.shrine.write(IShrineDispatcher { contract_address: shrine });

        self.set_oracle_extension_helper(oracle_extension);
        self.set_twap_duration_helper(twap_duration);
        self.set_quote_tokens_helper(quote_tokens);
        self.set_update_frequency_helper(update_frequency);
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

        fn get_quotes(self: @ContractState) -> Span<Wad> {
            let oracle_extension = self.oracle_extension.read();
            let twap_duration = self.twap_duration.read();
            let cash = self.shrine.read().contract_address;

            let mut quotes: Array<Wad> = Default::default();
            let mut index: u32 = LOOP_START;
            let end_index = LOOP_START + NUM_QUOTE_TOKENS;
            loop {
                if index == end_index {
                    break quotes.span();
                }

                let quote_token_info: QuoteTokenInfo = self.quote_tokens.read(index);
                let quote: u256 = oracle_extension
                    .get_price_x128_over_last(cash, quote_token_info.address, twap_duration);
                let scaled_quote: Wad = scale_x128_to_wad(quote, quote_token_info.decimals);

                quotes.append(scaled_quote);
                index += 1;
            }
        }

        fn get_twap_duration(self: @ContractState) -> u64 {
            self.twap_duration.read()
        }

        fn get_update_frequency(self: @ContractState) -> u64 {
            self.update_frequency.read()
        }

        fn set_oracle_extension(ref self: ContractState, oracle_extension: ContractAddress) {
            self.access_control.assert_has_role(receptor_roles::SET_ORACLE_EXTENSION);

            self.set_oracle_extension_helper(oracle_extension);
        }

        fn set_quote_tokens(ref self: ContractState, quote_tokens: Span<ContractAddress>) {
            self.access_control.assert_has_role(receptor_roles::SET_QUOTE_TOKENS);

            self.set_quote_tokens_helper(quote_tokens);
        }

        fn set_update_frequency(ref self: ContractState, new_frequency: u64) {
            self.access_control.assert_has_role(receptor_roles::SET_UPDATE_FREQUENCY);
            assert(
                LOWER_UPDATE_FREQUENCY_BOUND <= new_frequency && new_frequency <= UPPER_UPDATE_FREQUENCY_BOUND,
                'REC: Frequency out of bounds'
            );

            self.set_update_frequency_helper(new_frequency);
        }

        fn set_twap_duration(ref self: ContractState, twap_duration: u64) {
            self.access_control.assert_has_role(receptor_roles::SET_TWAP_DURATION);

            self.set_twap_duration_helper(twap_duration);
        }

        fn update_yin_price(ref self: ContractState) {
            self.access_control.assert_has_role(receptor_roles::UPDATE_YIN_PRICE);
            self.update_yin_price_internal();
        }
    }

    #[abi(embed_v0)]
    impl ITaskImpl of ITask<ContractState> {
        fn probe_task(self: @ContractState) -> bool {
            let seconds_since_last_update: u64 = get_block_timestamp()
                - self.last_update_yin_price_call_timestamp.read();
            self.update_frequency.read() <= seconds_since_last_update
        }

        fn execute_task(ref self: ContractState) {
            assert(self.probe_task(), 'REC: Too soon to update price');
            self.update_yin_price_internal();
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
        fn set_quote_tokens_helper(ref self: ContractState, quote_tokens: Span<ContractAddress>) {
            assert(quote_tokens.len() == NUM_QUOTE_TOKENS, 'REC: Not 3 quote tokens');

            let mut index = LOOP_START;
            let mut quote_tokens_copy = quote_tokens;
            let mut quote_tokens_info: Array<QuoteTokenInfo> = Default::default();
            loop {
                match quote_tokens_copy.pop_front() {
                    Option::Some(quote_token) => {
                        let token = IERC20Dispatcher { contract_address: *quote_token };
                        let decimals: u8 = token.decimals();
                        assert(decimals <= WAD_DECIMALS, 'REC: Too many decimals');

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
            assert(twap_duration >= MIN_TWAP_DURATION, 'REC: TWAP duration too low');

            let old_duration: u64 = self.twap_duration.read();
            self.twap_duration.write(twap_duration);

            self.emit(TwapDurationUpdated { old_duration, new_duration: twap_duration });
        }

        fn set_update_frequency_helper(ref self: ContractState, new_frequency: u64) {
            let old_frequency: u64 = self.update_frequency.read();
            self.update_frequency.write(new_frequency);
            self.emit(UpdateFrequencyUpdated { old_frequency, new_frequency });
        }

        fn update_yin_price_internal(ref self: ContractState) {
            let quotes = self.get_quotes();

            let mut quotes_copy = quotes;
            loop {
                match quotes_copy.pop_front() {
                    Option::Some(quote) => { if quote.is_zero() {
                        self.emit(InvalidQuotes { quotes });
                        break;
                    } },
                    Option::None => {
                        let yin_price: Wad = median_of_three(quotes);
                        self.shrine.read().update_yin_spot_price(yin_price);

                        self.last_update_yin_price_call_timestamp.write(get_block_timestamp());

                        self.emit(ValidQuotes { quotes });
                        break;
                    }
                };
            };
        }
    }
}
