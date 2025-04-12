#[starknet::contract]
pub mod mock_ekubo_oracle_adapter {
    use opus::utils::ekubo_oracle_adapter::ekubo_oracle_adapter_component;

    component!(path: ekubo_oracle_adapter_component, storage: ekubo_oracle_adapter, event: EkuboOracleAdapterEvent);

    impl EkuboOracleAdapterHelpers = ekubo_oracle_adapter_component::EkuboOracleAdapterHelpers<ContractState>;

    #[storage]
    pub struct Storage {
        #[substorage(v0)]
        pub ekubo_oracle_adapter: ekubo_oracle_adapter_component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        EkuboOracleAdapterEvent: ekubo_oracle_adapter_component::Event,
    }
}
