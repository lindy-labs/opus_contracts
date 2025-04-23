#[starknet::contract]
pub mod mock_address_registry {
    use opus::utils::address_registry::address_registry_component;

    component!(path: address_registry_component, storage: address_registry, event: AddressRegistryEvent);

    impl AddressRegistryHelpers = address_registry_component::AddressRegistryHelpers<ContractState>;

    #[storage]
    pub struct Storage {
        #[substorage(v0)]
        pub address_registry: address_registry_component::Storage,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AddressRegistryEvent: address_registry_component::Event,
    }
}
