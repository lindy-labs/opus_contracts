#[starknet::contract]
mod BondRegistry {
    use starknet::contract_address::{ContractAddress, ContractAddressZeroable};

    use opus::core::roles::bond_registry_roles;

    use opus::interfaces::IBond::{IBondDispatcher, IBondDispatcherTrait, IBondRegistry};
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
        bonds_count: u32,
        bond_ids: LegacyMap::<ContractAddress, u32>,
        bonds: LegacyMap::<u32, ContractAddress>,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AccessControlEvent: access_control_component::Event,
    }

    #[external(v0)]
    impl IBondRegistryImpl of IBondRegistry<ContractState> {
        fn get_bonds_count(self: @ContractState) -> u32 {
            self.bonds_count.read()
        }

        fn get_bonds(self: @ContractState) -> Span<ContractAddress> {
            let mut bonds: Array<ContractAddress> = ArrayTrait::new();

            let loop_end: u32 = 0;

            let mut bond_id: u32 = self.bonds_count.read();
            loop {
                if bond_id == loop_end {
                    break bonds.span();
                }

                bonds.append(self.bonds.read(bond_id));

                bond_id -= 1;
            }
        }

        fn add_bond(ref self: ContractState, bond: ContractAddress) {
            self.access_control.assert_has_role(bond_registry_roles::ADD_BOND);

            assert(self.bond_ids.read(bond) == 0, 'BR: Bond already exists');
            let bond_id: u32 = self.bonds_count.read() + 1;

            self.bonds_count.write(bond_id);
            self.bond_ids.write(bond, bond_id);
            self.bonds.write(bond_id, bond);
        // TODO: emit event
        }

        fn remove_bond(ref self: ContractState, bond: ContractAddress) {
            self.access_control.assert_has_role(bond_registry_roles::REMOVE_BOND);

            let bond_id: u32 = self.bond_ids.read(bond);
            assert(bond_id != 0, 'BR: Bond does not exist');
            let bonds_count: u32 = self.bonds_count.read();

            // Reset mapping of bond to bond ID
            self.bond_ids.write(bond, 0);

            // Move last bond ID to removed bond ID
            let last_bond_id: u32 = bonds_count;
            self.bonds.write(last_bond_id, ContractAddressZeroable::zero());
            if bond_id != last_bond_id {
                let last_bond: ContractAddress = self.bonds.read(last_bond_id);
                self.bonds.write(bond_id, last_bond);
                self.bond_ids.write(last_bond, bond_id);
            }

            // Decrement bonds count
            self.bonds_count.write(bonds_count - 1);
        // TODO: emit event
        }
    }
}
