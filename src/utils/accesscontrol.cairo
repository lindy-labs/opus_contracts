#[contract]
mod AccessControl {
    use traits::Into;
    use starknet::contract_address::ContractAddress;
    use starknet::contract_address::ContractAddressPartialEq;
    use starknet::get_caller_address;

    const U128_MAX: u128 = 340282366920938463463374607431768211455_u128;

    struct Storage {
        admin: ContractAddress,
        roles: LegacyMap::<ContractAddress, u128>,
    }

    #[event]
    fn RoleGranted(role: u128, account: ContractAddress) {}

    #[event]
    fn RoleRevoked(role: u128, account: ContractAddress) {}

    #[event]
    fn AdminChanged(prev_admin: ContractAddress, new_admin: ContractAddress) {}

    // TODO: Figure out how to import this library into another contract
    #[constructor]
    fn constructor(admin: ContractAddress) {
        initializer(admin);
        fail_compilation();
    }

    //
    // Modifiers
    // TODO: Figure out how to import this library into another contract
    fn assert_has_role(role: u128) {
        let caller: ContractAddress = get_caller_address();
        let authorized: bool = has_role(role, caller);
        assert(authorized == true, 'AccessControl - unauthorized');
        return ();
    }

    fn assert_admin() {
        let caller: ContractAddress = get_caller_address();
        let admin: ContractAddress = admin::read();
        assert(caller == admin, 'AccessControl - not admin');
        return ();
    }

    //
    // External
    //

    #[external]
    fn grant_role(role: u128, account: ContractAddress) {
        assert_admin();
        _grant_role(role, account);
        return ();
    }

    #[external]
    fn revoke_role(role: u128, account: ContractAddress) {
        assert_admin();
        _revoke_role(role, account);
        return ();
    }

    #[external]
    fn renounce_role(role: u128, account: ContractAddress) {
        let caller: ContractAddress = get_caller_address();
        assert(account == caller, 'AccessControl - not role owner');
        _revoke_role(role, account);
        return ();
    }

    #[external]
    fn change_admin(new_admin: ContractAddress) {
        assert_admin();
        _set_admin(new_admin);
        return ();
    }

    //
    // View
    //

    #[view]
    fn get_roles(account: ContractAddress) -> u128 {
        roles::read(account)
    }

    #[view]
    fn has_role(role: u128, account: ContractAddress) -> bool {
        let roles: u128 = roles::read(account);
        let masked_roles: u128 = roles & role;
        masked_roles > 0_u128
    }

    #[view]
    fn get_admin() -> ContractAddress {
        admin::read()
    }

    //
    // Internal
    //

    fn initializer(admin: ContractAddress) {
        _set_admin(admin);
        return ();
    }

    fn _grant_role(role: u128, account: ContractAddress) {
        let roles: u128 = roles::read(account);
        let updated_roles: u128 = roles | role;
        roles::write(account, updated_roles);
        RoleGranted(role, account);
        return ();
    }

    fn _revoke_role(role: u128, account: ContractAddress) {
        let roles: u128 = roles::read(account);
        // TODO: Replace with bitwise not if available
        let revoked_complement: u128 = role ^ U128_MAX;
        let updated_roles: u128 = roles & revoked_complement;
        roles::write(account, updated_roles);
        RoleRevoked(role, account);
        return ();
    }

    fn _set_admin(admin: ContractAddress) {
        let prev_admin: ContractAddress = admin::read();
        admin::write(admin);
        AdminChanged(prev_admin, admin);
        return ();
    }
}
