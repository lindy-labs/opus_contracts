use starknet::ContractAddress;

#[abi]
trait IAccessControl {
    fn get_roles(account: ContractAddress) -> u128;
    fn has_role(role: u128, account: ContractAddress) -> bool;
    fn get_admin() -> ContractAddress;
    fn get_pending_admin() -> ContractAddress;
    fn grant_role(role: u128, account: ContractAddress);
    fn revoke_role(role: u128, account: ContractAddress);
    fn renounce_role(role: u128);
    fn set_pending_admin(new_admin: ContractAddress);
    fn accept_admin();
}

mod AccessControl {
    use array::{ArrayTrait, SpanTrait};
    use integer::U128BitNot;
    use option::OptionTrait;
    use starknet::{
        ContractAddress, get_caller_address, Felt252TryIntoContractAddress, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::storage_access::{
        StorageAccessContractAddress, StorageAccessU128, StorageBaseAddress,
        storage_base_address_from_felt252, storage_base_address_const
    };
    use traits::{Default, Into, TryInto};

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

    fn get_pending_admin() -> ContractAddress {
        read_pending_admin()
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

    fn set_pending_admin(new_admin: ContractAddress) {
        assert_admin();
        set_pending_admin_internal(new_admin);
    }

    //
    // external
    //

    fn accept_admin() {
        let caller: ContractAddress = get_caller_address();
        assert(get_pending_admin() == caller, 'Caller not pending admin');
        set_admin_internal(caller);
        write_pending_admin(ContractAddressZeroable::zero());
    }

    //
    // internal
    //

    fn set_admin_internal(new_admin: ContractAddress) {
        let prev_admin = get_admin();
        write_admin(new_admin);
        emit_admin_changed(prev_admin, new_admin);
    }

    fn set_pending_admin_internal(new_admin: ContractAddress) {
        write_pending_admin(new_admin);
        emit_new_pending_admin(new_admin);
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

    // get_storage_var_address('__accesscontrol_roles')
    const ROLES_STORAGE_BASE_ADDR: felt252 =
        0x2eab78cbab284277f4538b0eec4126e90517b4be096f191d28577583f4b6046;

    // get_storage_var_address('__accesscontrol_admin')
    fn admin_storage_base_addr() -> StorageBaseAddress {
        storage_base_address_const::<0x35dbc6d52d4cf954e68fe9f892062e268d9521a19861f1259bafa16de069420>()
    }

    // get_storage_var_address('__accesscontrol_pending_admin')
    fn pending_admin_storage_base_addr() -> StorageBaseAddress {
        storage_base_address_const::<0x24ad2cfdcaf266992a1f4ef0c3913021bd49409632edab775649f6ee7f650a9>()
    }

    fn read_admin() -> ContractAddress {
        StorageAccessContractAddress::read(0, admin_storage_base_addr()).unwrap_syscall()
    }

    fn write_admin(admin: ContractAddress) {
        StorageAccessContractAddress::write(0, admin_storage_base_addr(), admin);
    }

    fn read_pending_admin() -> ContractAddress {
        StorageAccessContractAddress::read(0, pending_admin_storage_base_addr()).unwrap_syscall()
    }

    fn write_pending_admin(admin: ContractAddress) {
        StorageAccessContractAddress::write(0, pending_admin_storage_base_addr(), admin);
    }

    fn read_roles(account: ContractAddress) -> u128 {
        let base = starknet::storage_base_address_from_felt252(
            hash::LegacyHash::hash(ROLES_STORAGE_BASE_ADDR, account)
        );
        StorageAccessU128::read(0, base).unwrap_syscall()
    }

    fn write_roles(account: ContractAddress, roles: u128) {
        let base = starknet::storage_base_address_from_felt252(
            hash::LegacyHash::hash(ROLES_STORAGE_BASE_ADDR, account)
        );
        StorageAccessU128::write(0, base, roles);
    }

    //
    // events
    //

    // get_selector_from_name('AdminChanged')
    const ADMIN_CHANGED_EVENT_KEY: felt252 =
        0x120650e571756796b93f65826a80b3511d4f3a06808e82cb37407903b09d995;

    // get_selector_from_name('NewPendingAdmin')
    const NEW_PENDING_ADMIN_EVENT_KEY: felt252 =
        0x11de12079842d5a0cd483671a1213f7854d77513656c5619ed523787f9bb992;

    // get_selector_from_name('RoleGranted')
    const ROLE_GRANTED_EVENT_KEY: felt252 =
        0x9d4a59b844ac9d98627ddba326ab3707a7d7e105fd03c777569d0f61a91f1e;

    // get_selector_from_name('RoleRevoked')
    const ROLE_REVOKED_EVENT_KEY: felt252 =
        0x2842fd3b01bb0858fef6a2da51cdd9f995c7d36d7625fb68dd5d69fcc0a6d76;

    // all of the events emitted from this module take up to 2 data values
    // so we pass them separately into `emit`
    fn emit(event_key: felt252, event_data_1: felt252, event_data_2: Option<felt252>) {
        let mut data = Default::default();
        data.append(event_data_1);

        match event_data_2 {
            Option::Some(i) => {
                data.append(i);
            },
            Option::None(_) => {},
        };

        let mut keys = Default::default();
        keys.append(event_key);
        starknet::emit_event_syscall(keys.span(), data.span()).unwrap_syscall();
    }

    // AdminChanged(prev_admin, new_admin)
    fn emit_admin_changed(prev_admin: ContractAddress, new_admin: ContractAddress) {
        emit(ADMIN_CHANGED_EVENT_KEY, prev_admin.into(), Option::Some(new_admin.into()));
    }

    // NewPendingAdmin(new_admin)
    fn emit_new_pending_admin(new_admin: ContractAddress) {
        emit(NEW_PENDING_ADMIN_EVENT_KEY, new_admin.into(), Option::None(()));
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
