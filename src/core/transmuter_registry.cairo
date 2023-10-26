#[starknet::contract]
mod TransmuterRegistry {
    use starknet::contract_address::{ContractAddress, ContractAddressZeroable};

    use opus::core::roles::transmuter_registry_roles;

    use opus::interfaces::ITransmuter::{
        ITransmuterDispatcher, ITransmuterDispatcherTrait, ITransmuterRegistry
    };
    use opus::utils::access_control::access_control_component;

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic =
        access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        transmuters_count: u32,
        transmuter_ids: LegacyMap::<ContractAddress, u32>,
        transmuters: LegacyMap::<u32, ContractAddress>,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AccessControlEvent: access_control_component::Event,
    }

    //
    // External Transmuter registry functions
    //

    #[external(v0)]
    impl ITransmuterRegistryImpl of ITransmuterRegistry<ContractState> {
        fn get_transmuters_count(self: @ContractState) -> u32 {
            self.transmuters_count.read()
        }

        fn get_transmuters(self: @ContractState) -> Span<ContractAddress> {
            let mut transmuters: Array<ContractAddress> = ArrayTrait::new();

            let loop_end: u32 = 0;

            let mut transmuter_id: u32 = self.transmuters_count.read();
            loop {
                if transmuter_id == loop_end {
                    break transmuters.span();
                }

                transmuters.append(self.transmuters.read(transmuter_id));

                transmuter_id -= 1;
            }
        }

        fn add_transmuter(ref self: ContractState, transmuter: ContractAddress) {
            self.access_control.assert_has_role(transmuter_registry_roles::ADD_TRANSMUTER);

            assert(self.transmuter_ids.read(transmuter) == 0, 'TRR: Transmuter already exists');
            let transmuter_id: u32 = self.transmuters_count.read() + 1;

            self.transmuters_count.write(transmuter_id);
            self.transmuter_ids.write(transmuter, transmuter_id);
            self.transmuters.write(transmuter_id, transmuter);
        // TODO: emit event
        }

        fn remove_transmuter(ref self: ContractState, transmuter: ContractAddress) {
            self.access_control.assert_has_role(transmuter_registry_roles::REMOVE_TRANSMUTER);

            let transmuter_id: u32 = self.transmuter_ids.read(transmuter);
            assert(transmuter_id != 0, 'TRR: Transmuter does not exist');
            let transmuters_count: u32 = self.transmuters_count.read();

            // Reset mapping of transmuter to transmuter ID
            self.transmuter_ids.write(transmuter, 0);

            // Move last transmuter ID to removed transmuter ID
            let last_transmuter_id: u32 = transmuters_count;
            self.transmuters.write(last_transmuter_id, ContractAddressZeroable::zero());
            if transmuter_id != last_transmuter_id {
                let last_transmuter: ContractAddress = self.transmuters.read(last_transmuter_id);
                self.transmuters.write(transmuter_id, last_transmuter);
                self.transmuter_ids.write(last_transmuter, transmuter_id);
            }

            // Decrement transmuters count
            self.transmuters_count.write(transmuters_count - 1);
        // TODO: emit event
        }

        fn set_receiver(ref self: ContractState, receiver: ContractAddress) {
            self.access_control.assert_has_role(transmuter_registry_roles::SET_RECEIVER);

            let loop_end: u32 = 0;

            let mut transmuter_id: u32 = self.transmuters_count.read();
            loop {
                if transmuter_id == loop_end {
                    break;
                }

                ITransmuterDispatcher { contract_address: self.transmuters.read(transmuter_id) }
                    .set_receiver(receiver);

                transmuter_id -= 1;
            };
        }

        fn kill(ref self: ContractState) {
            self.access_control.assert_has_role(transmuter_registry_roles::KILL);

            let loop_end: u32 = 0;

            let mut transmuter_id: u32 = self.transmuters_count.read();
            loop {
                if transmuter_id == loop_end {
                    break;
                }

                ITransmuterDispatcher { contract_address: self.transmuters.read(transmuter_id) }
                    .kill();

                transmuter_id -= 1;
            };
        }
    }
}
