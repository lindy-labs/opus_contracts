#[starknet::contract]
mod TransmuterRegistry {
    use starknet::contract_address::{ContractAddress, ContractAddressZeroable};

    use opus::core::roles::transmuter_registry_roles;

    use opus::interfaces::ITransmuter::{
        ITransmuterDispatcher, ITransmuterDispatcherTrait, ITransmuterRegistry
    };
    use opus::utils::access_control::access_control_component;
    use opus::utils::address_registry::address_registry_component;

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);
    component!(path: address_registry_component, storage: registry, event: AddressRegistryEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic =
        access_control_component::AccessControl<ContractState>;

    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;
    impl AddressRegistryHelpers = address_registry_component::AddressRegistryHelpers<ContractState>;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        #[substorage(v0)]
        registry: address_registry_component::Storage,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AccessControlEvent: access_control_component::Event,
        AddressRegistryEvent: address_registry_component::Event,
    }

    //
    // External Transmuter registry functions
    //

    #[external(v0)]
    impl ITransmuterRegistryImpl of ITransmuterRegistry<ContractState> {
        fn get_transmuters_count(self: @ContractState) -> u32 {
            self.registry.get_entries_count()
        }

        fn get_transmuters(self: @ContractState) -> Span<ContractAddress> {
            self.registry.get_entries()
        }

        fn add_transmuter(ref self: ContractState, transmuter: ContractAddress) {
            self.access_control.assert_has_role(transmuter_registry_roles::ADD_TRANSMUTER);

            self.registry.add_entry(transmuter, 'TRR: Transmuter already exists');
        }

        fn remove_transmuter(ref self: ContractState, transmuter: ContractAddress) {
            self.access_control.assert_has_role(transmuter_registry_roles::REMOVE_TRANSMUTER);

            self.registry.remove_entry(transmuter, 'TRR: Transmuter does not exist');
        }

        fn set_receiver(ref self: ContractState, receiver: ContractAddress) {
            self.access_control.assert_has_role(transmuter_registry_roles::SET_RECEIVER);

            let loop_end: u32 = 0;

            let mut transmuter_id: u32 = self.registry.get_entries_count();
            let self_snap = @self;
            loop {
                if transmuter_id == loop_end {
                    break;
                }

                ITransmuterDispatcher {
                    contract_address: self_snap.registry.get_entry(transmuter_id)
                }
                    .set_receiver(receiver);

                transmuter_id -= 1;
            };
        }

        fn kill(ref self: ContractState) {
            self.access_control.assert_has_role(transmuter_registry_roles::KILL);

            let loop_end: u32 = 0;

            let mut transmuter_id: u32 = self.registry.get_entries_count();
            let self_snap = @self;
            loop {
                if transmuter_id == loop_end {
                    break;
                }

                ITransmuterDispatcher {
                    contract_address: self_snap.registry.get_entry(transmuter_id)
                }
                    .kill();

                transmuter_id -= 1;
            };
        }
    }
}
