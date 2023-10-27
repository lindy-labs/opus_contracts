#[starknet::contract]
mod BondRegistry {
    use starknet::contract_address::{ContractAddress, ContractAddressZeroable};

    use opus::core::roles::BondRegistryRoles;

    use opus::interfaces::IBond::{IBondDispatcher, IBondDispatcherTrait, IBondRegistry};
    use opus::utils::access_control::{AccessControl, IAccessControl};

    #[storage]
    struct Storage {
        bonds_count: u32,
        bond_ids: LegacyMap::<ContractAddress, u32>,
        bonds: LegacyMap::<u32, ContractAddress>,
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
            AccessControl::assert_has_role(BondRegistryRoles::ADD_BOND);

            assert(self.bond_ids.read(bond) == 0, 'BR: Bond already exists');
            let bond_id: u32 = self.bonds_count.read() + 1;

            self.bonds_count.write(bond_id);
            self.bond_ids.write(bond, bond_id);
            self.bonds.write(bond_id, bond);
        // TODO: emit event
        }

        fn remove_bond(ref self: ContractState, bond: ContractAddress) {
            AccessControl::assert_has_role(BondRegistryRoles::REMOVE_BOND);

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


    //
    // Public AccessControl functions
    //

    #[external(v0)]
    impl IAccessControlImpl of IAccessControl<ContractState> {
        fn get_roles(self: @ContractState, account: ContractAddress) -> u128 {
            AccessControl::get_roles(account)
        }

        fn has_role(self: @ContractState, role: u128, account: ContractAddress) -> bool {
            AccessControl::has_role(role, account)
        }

        fn get_admin(self: @ContractState) -> ContractAddress {
            AccessControl::get_admin()
        }

        fn get_pending_admin(self: @ContractState) -> ContractAddress {
            AccessControl::get_pending_admin()
        }

        fn grant_role(ref self: ContractState, role: u128, account: ContractAddress) {
            AccessControl::grant_role(role, account);
        }

        fn revoke_role(ref self: ContractState, role: u128, account: ContractAddress) {
            AccessControl::revoke_role(role, account);
        }

        fn renounce_role(ref self: ContractState, role: u128) {
            AccessControl::renounce_role(role);
        }

        fn set_pending_admin(ref self: ContractState, new_admin: ContractAddress) {
            AccessControl::set_pending_admin(new_admin);
        }

        fn accept_admin(ref self: ContractState) {
            AccessControl::accept_admin();
        }
    }
}
