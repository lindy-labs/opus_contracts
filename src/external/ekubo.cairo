#[starknet::contract]
pub mod ekubo {
    use access_control::access_control_component;
    use core::num::traits::Zero;
    use opus::external::interfaces::{IEkuboOracleExtensionDispatcher, IEkuboOracleExtensionDispatcherTrait};
    use opus::external::roles::ekubo_roles;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IOracle::IOracle;
    use opus::types::QuoteTokenInfo;
    use opus::utils::ekubo_oracle_config::{ekubo_oracle_config_component, IEkuboOracleConfig};
    use opus::utils::math::{median_of_three, convert_ekubo_oracle_price_to_wad};
    use starknet::ContractAddress;
    use wadray::Wad;

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    component!(path: ekubo_oracle_config_component, storage: ekubo_oracle_config, event: EkuboOracleConfigEvent);

    impl EkuboOracleConfigHelpers = ekubo_oracle_config_component::EkuboOracleConfigHelpers<ContractState>;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        #[substorage(v0)]
        ekubo_oracle_config: ekubo_oracle_config_component::Storage,
        // interface to the Ekubo oracle extension
        oracle_extension: IEkuboOracleExtensionDispatcher,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AccessControlEvent: access_control_component::Event,
        EkuboOracleConfigEvent: ekubo_oracle_config_component::Event,
        InvalidPriceUpdate: InvalidPriceUpdate
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct InvalidPriceUpdate {
        pub yang: ContractAddress,
        pub quotes: Span<Wad>
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

        self.ekubo_oracle_config.set_twap_duration(twap_duration);
        self.ekubo_oracle_config.set_quote_tokens(quote_tokens);
    }

    //
    // External Ekubo oracle config functions
    //

    #[abi(embed_v0)]
    impl IEkuboOracleConfigImpl of IEkuboOracleConfig<ContractState> {
        fn get_quote_tokens(self: @ContractState) -> Span<QuoteTokenInfo> {
            self.ekubo_oracle_config.get_quote_tokens()
        }

        fn get_twap_duration(self: @ContractState) -> u64 {
            self.ekubo_oracle_config.get_twap_duration()
        }

        fn set_quote_tokens(ref self: ContractState, quote_tokens: Span<ContractAddress>) {
            self.access_control.assert_has_role(ekubo_roles::SET_QUOTE_TOKENS);

            self.ekubo_oracle_config.set_quote_tokens(quote_tokens);
        }

        fn set_twap_duration(ref self: ContractState, twap_duration: u64) {
            self.access_control.assert_has_role(ekubo_roles::SET_TWAP_DURATION);

            self.ekubo_oracle_config.set_twap_duration(twap_duration);
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
        fn get_quotes(self: @ContractState, yang: ContractAddress) -> Span<Wad> {
            let oracle_extension = self.oracle_extension.read();
            let twap_duration = self.ekubo_oracle_config.get_twap_duration();
            let base_decimals: u8 = IERC20Dispatcher { contract_address: yang }.decimals();

            let mut quotes: Array<Wad> = Default::default();
            let mut quote_tokens = self.ekubo_oracle_config.get_quote_tokens();

            loop {
                match quote_tokens.pop_front() {
                    Option::Some(info) => {
                        let quote: u256 = oracle_extension.get_price_x128_over_last(yang, *info.address, twap_duration);

                        let scaled_quote: Wad = convert_ekubo_oracle_price_to_wad(quote, base_decimals, *info.decimals);

                        quotes.append(scaled_quote);
                    },
                    Option::None => { break quotes.span(); }
                };
            }
        }

        fn fetch_median_price(ref self: ContractState, yang: ContractAddress) -> Result<Wad, felt252> {
            let quotes = self.get_quotes(yang);

            // As long as the median price is non-zero (i.e. at least two prices are non-zero), 
            // it is treated as valid because liveness is prioritized for Ekubo's on-chain oracle.
            // Otherwise, emit an event about the update being invalid.
            let median_price: Wad = median_of_three(quotes);
            if median_price.is_zero() {
                self.emit(InvalidPriceUpdate { yang, quotes });
                Result::Err('EKB: Invalid price update')
            } else {
                Result::Ok(median_price)
            }
        }
    }
}
