#[starknet::contract]
pub mod receptor {
    use access_control::access_control_component;
    use core::num::traits::Zero;
    use opus::core::roles::receptor_roles;
    use opus::external::interfaces::ITask;
    use opus::interfaces::IReceptor::IReceptor;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::types::QuoteTokenInfo;
    use opus::utils::ekubo_oracle_adapter::{IEkuboOracleAdapter, ekubo_oracle_adapter_component};
    use opus::utils::math::median_of_three;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_block_timestamp};
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
    // Constants
    //

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
        #[substorage(v0)]
        ekubo_oracle_adapter: ekubo_oracle_adapter_component::Storage,
        // Shrine associated with this module
        shrine: IShrineDispatcher,
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
        EkuboOracleAdapterEvent: ekubo_oracle_adapter_component::Event,
        InvalidQuotes: InvalidQuotes,
        ValidQuotes: ValidQuotes,
        UpdateFrequencyUpdated: UpdateFrequencyUpdated,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct InvalidQuotes {
        pub quotes: Span<Wad>,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct ValidQuotes {
        pub quotes: Span<Wad>,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct UpdateFrequencyUpdated {
        pub old_frequency: u64,
        pub new_frequency: u64,
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
        quote_tokens: Span<ContractAddress>,
    ) {
        self.access_control.initializer(admin, Option::Some(receptor_roles::default_admin_role()));

        self.shrine.write(IShrineDispatcher { contract_address: shrine });

        self.ekubo_oracle_adapter.set_oracle_extension(oracle_extension);
        self.ekubo_oracle_adapter.set_twap_duration(twap_duration);
        self.ekubo_oracle_adapter.set_quote_tokens(quote_tokens);

        self.set_update_frequency_helper(update_frequency);
    }

    //
    // External Ekubo oracle config functions
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
            self.access_control.assert_has_role(receptor_roles::SET_ORACLE_EXTENSION);

            self.ekubo_oracle_adapter.set_oracle_extension(oracle_extension);
        }

        fn set_quote_tokens(ref self: ContractState, quote_tokens: Span<ContractAddress>) {
            self.access_control.assert_has_role(receptor_roles::SET_QUOTE_TOKENS);

            self.ekubo_oracle_adapter.set_quote_tokens(quote_tokens);
        }

        fn set_twap_duration(ref self: ContractState, twap_duration: u64) {
            self.access_control.assert_has_role(receptor_roles::SET_TWAP_DURATION);

            self.ekubo_oracle_adapter.set_twap_duration(twap_duration);
        }
    }

    //
    // External Receptor functions
    //

    #[abi(embed_v0)]
    impl IReceptorImpl of IReceptor<ContractState> {
        fn get_quotes(self: @ContractState) -> Span<Wad> {
            self.ekubo_oracle_adapter.get_quotes(self.shrine.read().contract_address)
        }

        fn get_update_frequency(self: @ContractState) -> u64 {
            self.update_frequency.read()
        }

        fn set_update_frequency(ref self: ContractState, new_frequency: u64) {
            self.access_control.assert_has_role(receptor_roles::SET_UPDATE_FREQUENCY);
            assert(
                LOWER_UPDATE_FREQUENCY_BOUND <= new_frequency && new_frequency <= UPPER_UPDATE_FREQUENCY_BOUND,
                'REC: Frequency out of bounds',
            );

            self.set_update_frequency_helper(new_frequency);
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
                    },
                };
            };
        }
    }
}
