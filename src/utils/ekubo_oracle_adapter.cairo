use opus::types::QuoteTokenInfo;
use starknet::ContractAddress;

#[starknet::interface]
pub trait IEkuboOracleAdapter<TContractState> {
    // getters
    fn get_oracle_extension(self: @TContractState) -> ContractAddress;
    fn get_quote_tokens(self: @TContractState) -> Span<QuoteTokenInfo>;
    fn get_twap_duration(self: @TContractState) -> u64;
    // setters
    fn set_oracle_extension(ref self: TContractState, oracle_extension: ContractAddress);
    fn set_quote_tokens(ref self: TContractState, quote_tokens: Span<ContractAddress>);
    fn set_twap_duration(ref self: TContractState, twap_duration: u64);
}

#[starknet::component]
pub mod ekubo_oracle_adapter_component {
    use core::num::traits::Zero;
    use opus::external::interfaces::{IEkuboOracleExtensionDispatcher, IEkuboOracleExtensionDispatcherTrait};
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::types::QuoteTokenInfo;
    use opus::utils::math::convert_ekubo_oracle_price_to_wad;
    use starknet::ContractAddress;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess
    };
    use wadray::{Wad, WAD_DECIMALS};

    //
    // Constants
    //

    const LOOP_START: u32 = 1;
    pub const NUM_QUOTE_TOKENS: u32 = 3;

    pub const MIN_TWAP_DURATION: u64 = 60; // seconds; acts as a sanity check

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // Ekubo oracle extension for reading TWAP
        oracle_extension: IEkuboOracleExtensionDispatcher,
        // Collection of quote tokens, in no particular order
        // Starts from 1
        // (idx) -> (token to be quoted per yang)
        quote_tokens: Map<u32, QuoteTokenInfo>,
        // The duration in seconds for reading TWAP from Ekubo
        twap_duration: u64
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        QuoteTokensUpdated: QuoteTokensUpdated,
        TwapDurationUpdated: TwapDurationUpdated,
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
    // Internal functions
    //

    #[generate_trait]
    pub impl EkuboOracleAdapterHelpers<
        TContractState, +HasComponent<TContractState>
    > of EkuboOracleAdapterHelpersTrait<TContractState> {
        fn get_oracle_extension(self: @ComponentState<TContractState>) -> IEkuboOracleExtensionDispatcher {
            self.oracle_extension.read()
        }

        fn get_quote_tokens(self: @ComponentState<TContractState>) -> Span<QuoteTokenInfo> {
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

        fn get_twap_duration(self: @ComponentState<TContractState>) -> u64 {
            self.twap_duration.read()
        }

        fn get_quotes(self: @ComponentState<TContractState>, asset: ContractAddress) -> Span<Wad> {
            let oracle_extension = self.oracle_extension.read();
            let twap_duration = self.twap_duration.read();
            let base_decimals: u8 = IERC20Dispatcher { contract_address: asset }.decimals();

            let mut quotes: Array<Wad> = Default::default();
            let mut quote_tokens = self.get_quote_tokens();

            loop {
                match quote_tokens.pop_front() {
                    Option::Some(info) => {
                        let quote: u256 = oracle_extension
                            .get_price_x128_over_last(asset, *info.address, twap_duration);
                        let scaled_quote: Wad = convert_ekubo_oracle_price_to_wad(quote, base_decimals, *info.decimals);
                        quotes.append(scaled_quote);
                    },
                    Option::None => { break quotes.span(); }
                };
            }
        }

        fn set_oracle_extension(ref self: ComponentState<TContractState>, oracle_extension: ContractAddress) {
            assert(oracle_extension.is_non_zero(), 'EOC: Zero address for extension');

            self.oracle_extension.write(IEkuboOracleExtensionDispatcher { contract_address: oracle_extension });
        }

        fn set_quote_tokens(ref self: ComponentState<TContractState>, quote_tokens: Span<ContractAddress>) {
            assert(quote_tokens.len() == NUM_QUOTE_TOKENS, 'EOC: Not 3 quote tokens');

            let mut index = LOOP_START;
            let mut quote_tokens_copy = quote_tokens;
            let mut quote_tokens_info: Array<QuoteTokenInfo> = Default::default();
            loop {
                match quote_tokens_copy.pop_front() {
                    Option::Some(quote_token) => {
                        let token = IERC20Dispatcher { contract_address: *quote_token };
                        let decimals: u8 = token.decimals();
                        assert(decimals <= WAD_DECIMALS, 'EOC: Too many decimals');

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

        fn set_twap_duration(ref self: ComponentState<TContractState>, twap_duration: u64) {
            assert(twap_duration >= MIN_TWAP_DURATION, 'EOC: TWAP duration too low');

            let old_duration: u64 = self.twap_duration.read();
            self.twap_duration.write(twap_duration);

            self.emit(TwapDurationUpdated { old_duration, new_duration: twap_duration });
        }
    }
}
