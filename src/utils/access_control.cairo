use starknet::ContractAddress;

#[starknet::interface]
trait IAccessControl<TContractState> {
    fn get_roles(self: @TContractState, account: ContractAddress) -> u128;
    fn has_role(self: @TContractState, role: u128, account: ContractAddress) -> bool;
    fn get_admin(self: @TContractState) -> ContractAddress;
    fn get_pending_admin(self: @TContractState) -> ContractAddress;
    fn grant_role(ref self: TContractState, role: u128, account: ContractAddress);
    fn revoke_role(ref self: TContractState, role: u128, account: ContractAddress);
    fn renounce_role(ref self: TContractState, role: u128);
    fn set_pending_admin(ref self: TContractState, new_admin: ContractAddress);
    fn accept_admin(ref self: TContractState);
}

mod AccessControl {
    use starknet::{ContractAddress, get_caller_address, SyscallResultTrait};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::storage_access::{
        StoreContractAddress, StoreU128, StorageBaseAddress, storage_base_address_from_felt252,
    };

    fn initializer(admin: ContractAddress, roles: Option<u128>) {
        set_admin_helper(admin);
        if roles.is_some() {
            grant_role_helper(roles.unwrap(), admin);
        }
    }

    //
    // asserts
    //

    fn assert_has_role(role: u128) {
        assert(has_role(role, get_caller_address()), 'Caller missing role');
    }

    fn assert_admin() {
        assert(get_admin() == get_caller_address(), 'Caller not admin');
    }

    //
    // getters
    //

    fn get_roles(account: ContractAddress) -> u128 {
        read_roles(account)
    }

    fn has_role(role: u128, account: ContractAddress) -> bool {
        let roles = read_roles(account);
        // masks roles such that all bits are zero, except the bit(s) representing `role`, which may be zero or one
        let masked_roles = roles & role;
        // if masked_roles is non-zero, the account has the queried role
        masked_roles != 0
    }

    fn get_admin() -> ContractAddress {
        read_admin()
    }

    fn get_pending_admin() -> ContractAddress {
        read_pending_admin()
    }

    //
    // setters
    //

    fn grant_role(role: u128, account: ContractAddress) {
        assert_admin();
        grant_role_helper(role, account);
    }

    fn revoke_role(role: u128, account: ContractAddress) {
        assert_admin();
        revoke_role_helper(role, account);
    }

    fn renounce_role(role: u128) {
        revoke_role_helper(role, get_caller_address());
    }

    fn set_pending_admin(new_admin: ContractAddress) {
        assert_admin();
        set_pending_admin_helper(new_admin);
    }

    //
    // external
    //

    fn accept_admin() {
        let caller: ContractAddress = get_caller_address();
        assert(get_pending_admin() == caller, 'Caller not pending admin');
        set_admin_helper(caller);
        write_pending_admin(ContractAddressZeroable::zero());
    }

    //
    // internal
    //

    fn set_admin_helper(new_admin: ContractAddress) {
        let prev_admin = get_admin();
        write_admin(new_admin);
        emit_admin_changed(prev_admin, new_admin);
    }

    fn set_pending_admin_helper(new_admin: ContractAddress) {
        write_pending_admin(new_admin);
        emit_new_pending_admin(new_admin);
    }

    fn grant_role_helper(role: u128, account: ContractAddress) {
        let roles = read_roles(account);
        write_roles(account, roles | role);
        emit_role_granted(role, account);
    }

    fn revoke_role_helper(role: u128, account: ContractAddress) {
        let roles = read_roles(account);
        let updated_roles = roles & (~role);
        write_roles(account, updated_roles);
        emit_role_revoked(role, account);
    }

    //
    // storage
    //

    // the read/write via syscalls can go away once we have contract composability in C1

    const ROLES_STORAGE_BASE_ADDR: felt252 = selector!("__accesscontrol_roles");

    fn admin_storage_base_addr() -> StorageBaseAddress {
        storage_base_address_from_felt252(selector!("__accesscontrol_admin"))
    }

    fn pending_admin_storage_base_addr() -> StorageBaseAddress {
        storage_base_address_from_felt252(selector!("__accesscontrol_pending_admin"))
    }

    fn read_admin() -> ContractAddress {
        StoreContractAddress::read(0, admin_storage_base_addr()).unwrap_syscall()
    }

    fn write_admin(admin: ContractAddress) {
        StoreContractAddress::write(0, admin_storage_base_addr(), admin).expect('AC: write_admin');
    }

    fn read_pending_admin() -> ContractAddress {
        StoreContractAddress::read(0, pending_admin_storage_base_addr()).unwrap_syscall()
    }

    fn write_pending_admin(admin: ContractAddress) {
        StoreContractAddress::write(0, pending_admin_storage_base_addr(), admin)
            .expect('AC: write_pending_admin');
    }

    fn read_roles(account: ContractAddress) -> u128 {
        let base = starknet::storage_base_address_from_felt252(
            hash::LegacyHash::hash(ROLES_STORAGE_BASE_ADDR, account)
        );
        StoreU128::read(0, base).unwrap_syscall()
    }

    fn write_roles(account: ContractAddress, roles: u128) {
        let base = starknet::storage_base_address_from_felt252(
            hash::LegacyHash::hash(ROLES_STORAGE_BASE_ADDR, account)
        );
        StoreU128::write(0, base, roles).expect('AC: write_roles');
    }

    //
    // events
    //

    const ADMIN_CHANGED_EVENT_KEY: felt252 = selector!("AdminChanged");
    const NEW_PENDING_ADMIN_EVENT_KEY: felt252 = selector!("NewPendingAdmin");
    const ROLE_GRANTED_EVENT_KEY: felt252 = selector!("RoleGranted");
    const ROLE_REVOKED_EVENT_KEY: felt252 = selector!("RoleRevoked");

    // all of the events emitted from this module take up to 2 data values
    // so we pass them separately into `emit`
    fn emit(event_key: felt252, event_data_1: felt252, event_data_2: Option<felt252>) {
        let mut data: Array<felt252> = ArrayTrait::new();
        data.append(event_data_1);

        match event_data_2 {
            Option::Some(i) => { data.append(i); },
            Option::None => {},
        };

        let mut keys: Array<felt252> = ArrayTrait::new();
        keys.append(event_key);
        starknet::emit_event_syscall(keys.span(), data.span()).unwrap_syscall();
    }

    // AdminChanged(prev_admin, new_admin)
    fn emit_admin_changed(prev_admin: ContractAddress, new_admin: ContractAddress) {
        emit(ADMIN_CHANGED_EVENT_KEY, prev_admin.into(), Option::Some(new_admin.into()));
    }

    // NewPendingAdmin(new_admin)
    fn emit_new_pending_admin(new_admin: ContractAddress) {
        emit(NEW_PENDING_ADMIN_EVENT_KEY, new_admin.into(), Option::None);
    }

    // RoleGranted(role, account)
    fn emit_role_granted(role: u128, account: ContractAddress) {
        emit(ROLE_GRANTED_EVENT_KEY, role.into(), Option::Some(account.into()));
    }

    // RoleRevoked(role, account)
    fn emit_role_revoked(role: u128, account: ContractAddress) {
        emit(ROLE_REVOKED_EVENT_KEY, role.into(), Option::Some(account.into()));
    }
}
