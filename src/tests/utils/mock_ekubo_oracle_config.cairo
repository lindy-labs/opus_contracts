#[starknet::contract]
pub mod mock_ekubo_oracle_config {
    use opus::utils::ekubo_oracle_config::ekubo_oracle_config_component;

    component!(path: ekubo_oracle_config_component, storage: ekubo_oracle_config, event: EkuboOracleConfigEvent);

    impl EkuboOracleConfigHelpers = ekubo_oracle_config_component::EkuboOracleConfigHelpers<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ekubo_oracle_config: ekubo_oracle_config_component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        EkuboOracleConfigEvent: ekubo_oracle_config_component::Event
    }
}
