#[starknet::contract]
pub mod ekubo {
    use access_control::access_control_component;
    use core::num::traits::Zero;
    use opus::external::roles::ekubo_roles;
    use opus::interfaces::IEkubo::IEkubo;
    use opus::interfaces::IOracle::IOracle;
    use opus::types::QuoteTokenInfo;
    use opus::utils::ekubo_oracle_adapter::{IEkuboOracleAdapter, ekubo_oracle_adapter_component};
    use opus::utils::math::median_of_three;
    use starknet::ContractAddress;
    use wadray::Wad;

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    component!(path: ekubo_oracle_adapter_component, storage: ekubo_oracle_adapter, event: EkuboOracleAdapterEvent);

    impl EkuboOracleAdapterHelpers = ekubo_oracle_adapter_component::EkuboOracleAdapterHelpers<ContractState>;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        #[substorage(v0)]
        ekubo_oracle_adapter: ekubo_oracle_adapter_component::Storage,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AccessControlEvent: access_control_component::Event,
        EkuboOracleAdapterEvent: ekubo_oracle_adapter_component::Event,
        InvalidPriceUpdate: InvalidPriceUpdate,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct InvalidPriceUpdate {
        pub yang: ContractAddress,
        pub quotes: Span<Wad>,
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
        quote_tokens: Span<ContractAddress>,
    ) {
        self.access_control.initializer(admin, Option::Some(ekubo_roles::ADMIN));

        self.ekubo_oracle_adapter.set_oracle_extension(oracle_extension);
        self.ekubo_oracle_adapter.set_twap_duration(twap_duration);
        self.ekubo_oracle_adapter.set_quote_tokens(quote_tokens);
    }

    //
    // External Ekubo oracle adapter functions
    //

    #[abi(embed_v0)]
    impl IEkuboOracleAdapterImpl of IEkuboOracleAdapter<ContractState> {
        fn get_oracle_extension(self: @ContractState) -> ContractAddress {
            self.ekubo_oracle_adapter.get_oracle_extension().contract_address
        }

        fn get_quote_tokens(self: @ContractState) -> Span<QuoteTokenInfo> {
            self.ekubo_oracle_adapter.get_quote_tokens()
        }

        fn get_twap_duration(self: @ContractState) -> u64 {
            self.ekubo_oracle_adapter.get_twap_duration()
        }

        fn set_oracle_extension(ref self: ContractState, oracle_extension: ContractAddress) {
            self.access_control.assert_has_role(ekubo_roles::SET_QUOTE_TOKENS);

            self.ekubo_oracle_adapter.set_oracle_extension(oracle_extension);
        }

        fn set_quote_tokens(ref self: ContractState, quote_tokens: Span<ContractAddress>) {
            self.access_control.assert_has_role(ekubo_roles::SET_QUOTE_TOKENS);

            self.ekubo_oracle_adapter.set_quote_tokens(quote_tokens);
        }

        fn set_twap_duration(ref self: ContractState, twap_duration: u64) {
            self.access_control.assert_has_role(ekubo_roles::SET_TWAP_DURATION);

            self.ekubo_oracle_adapter.set_twap_duration(twap_duration);
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
            array![self.ekubo_oracle_adapter.get_oracle_extension().contract_address].span()
        }

        fn fetch_price(ref self: ContractState, yang: ContractAddress) -> Result<Wad, felt252> {
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

    //
    // External functions
    //

    #[abi(embed_v0)]
    impl IEkuboImpl of IEkubo<ContractState> {
        fn get_quotes(self: @ContractState, yang: ContractAddress) -> Span<Wad> {
            self.ekubo_oracle_adapter.get_quotes(yang)
        }
    }
}
