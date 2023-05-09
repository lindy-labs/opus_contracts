mod AccessControl {
    use array::{ArrayTrait, SpanTrait};
    use integer::U128BitNot;
    use option::OptionTrait;
    use starknet::{
        ContractAddress, get_caller_address, Felt252TryIntoContractAddress, SyscallResultTrait
    };
    use traits::{Into, TryInto};
    use zeroable::Zeroable;

    fn initializer(admin: ContractAddress) {
        set_admin_internal(admin);
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

    //
    // setters
    //

    fn grant_role(role: u128, account: ContractAddress) {
        assert_admin();
        grant_role_internal(role, account);
    }

    fn revoke_role(role: u128, account: ContractAddress) {
        assert_admin();
        revoke_role_internal(role, account);
    }

    fn renounce_role(role: u128) {
        revoke_role_internal(role, get_caller_address());
    }

    fn change_admin(new_admin: ContractAddress) {
        assert_admin();
        set_admin_internal(new_admin);
    }

    //
    // internal
    //

    fn set_admin_internal(new_admin: ContractAddress) {
        let prev_admin = get_admin();
        write_admin(new_admin);
        emit_admin_changed(prev_admin, new_admin);
    }

    fn grant_role_internal(role: u128, account: ContractAddress) {
        let roles = read_roles(account);
        write_roles(account, roles | role);
        emit_role_granted(role, account);
    }

    fn revoke_role_internal(role: u128, account: ContractAddress) {
        let roles = read_roles(account);
        // once ~ works as bitnot, use it instead of the long version
        // let updated_roles = roles & (~role);
        let updated_roles = roles & (U128BitNot::bitnot(role));
        write_roles(account, updated_roles);
        emit_role_revoked(role, account);
    }

    //
    // storage
    //

    // the read/write via syscalls can go away once we have contract composability in C1

    // get_storage_var_address('__accesscontrol_admin')
    const ADMIN_STORAGE_BASE_ADDR: felt252 =
        0x35dbc6d52d4cf954e68fe9f892062e268d9521a19861f1259bafa16de069420;

    // get_storage_var_address('__accesscontrol_roles')
    const ROLES_STORAGE_BASE_ADDR: felt252 =
        0x2eab78cbab284277f4538b0eec4126e90517b4be096f191d28577583f4b6046;

    fn read_admin() -> ContractAddress {
        let addr = starknet::storage_address_try_from_felt252(ADMIN_STORAGE_BASE_ADDR).unwrap();
        starknet::storage_read_syscall(0, addr).unwrap_syscall().try_into().unwrap()
    }

    fn write_admin(admin: ContractAddress) {
        let addr = starknet::storage_address_try_from_felt252(ADMIN_STORAGE_BASE_ADDR).unwrap();
        starknet::storage_write_syscall(0, addr, admin.into()).unwrap_syscall();
    }

    fn read_roles(account: ContractAddress) -> u128 {
        let base = starknet::storage_base_address_from_felt252(
            hash::LegacyHash::hash(ROLES_STORAGE_BASE_ADDR, account)
        );
        starknet::storage_read_syscall(
            0, starknet::storage_address_from_base(base)
        ).unwrap_syscall().try_into().unwrap()
    }

    fn write_roles(account: ContractAddress, roles: u128) {
        let base = starknet::storage_base_address_from_felt252(
            hash::LegacyHash::hash(ROLES_STORAGE_BASE_ADDR, account)
        );
        starknet::storage_write_syscall(
            0, starknet::storage_address_from_base(base), roles.into()
        ).unwrap_syscall();
    }

    //
    // events
    //

    // get_selector_from_name('AdminChanged')
    const ADMIN_CHANGED_EVENT_KEY: felt252 =
        0x120650e571756796b93f65826a80b3511d4f3a06808e82cb37407903b09d995;

    // get_selector_from_name('RoleGranted')
    const ROLE_GRANTED_EVENT_KEY: felt252 =
        0x9d4a59b844ac9d98627ddba326ab3707a7d7e105fd03c777569d0f61a91f1e;

    // get_selector_from_name('RoleRevoked')
    const ROLE_REVOKED_EVENT_KEY: felt252 =
        0x2842fd3b01bb0858fef6a2da51cdd9f995c7d36d7625fb68dd5d69fcc0a6d76;

    fn emit(event_key: felt252, data: Span<felt252>) {
        let mut keys = ArrayTrait::new();
        keys.append(event_key);
        starknet::emit_event_syscall(keys.span(), data).unwrap_syscall();
    }

    fn emit_admin_changed(prev_admin: ContractAddress, new_admin: ContractAddress) {
        let mut event_data = ArrayTrait::new();
        event_data.append(prev_admin.into());
        event_data.append(new_admin.into());
        emit(ADMIN_CHANGED_EVENT_KEY, event_data.span());
    }

    fn emit_role_granted(role: u128, account: ContractAddress) {
        let mut event_data = ArrayTrait::new();
        event_data.append(role.into());
        event_data.append(account.into());
        emit(ROLE_GRANTED_EVENT_KEY, event_data.span());
    }

    fn emit_role_revoked(role: u128, account: ContractAddress) {
        let mut event_data = ArrayTrait::new();
        event_data.append(role.into());
        event_data.append(account.into());
        emit(ROLE_REVOKED_EVENT_KEY, event_data.span());
    }
}
