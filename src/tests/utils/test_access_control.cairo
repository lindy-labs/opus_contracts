#[cfg(test)]
mod tests {
    use starknet::{contract_address_const, ContractAddress};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_caller_address;

    use aura::utils::access_control::AccessControl;

    // mock roles
    const R1: u128 = 1_u128;
    const R2: u128 = 2_u128;
    const R3: u128 = 128_u128;
    const R4: u128 = 256_u128;

    fn admin() -> ContractAddress {
        contract_address_const::<0x1337>()
    }

    fn user() -> ContractAddress {
        contract_address_const::<0xc1>()
    }

    fn badguy() -> ContractAddress {
        contract_address_const::<0x123>()
    }

    fn setup(caller: ContractAddress) {
        AccessControl::initializer(admin());
        set_caller_address(caller);
    }

    fn set_pending_admin(caller: ContractAddress, pending_admin: ContractAddress) {
        set_caller_address(caller);
        AccessControl::set_pending_admin(pending_admin);
    }

    fn default_grant() {
        let u = user();
        AccessControl::grant_role(R1, u);
        AccessControl::grant_role(R2, u);
    }

    #[test]
    #[available_gas(10000000)]
    fn test_initializer() {
        AccessControl::initializer(admin());
        assert(AccessControl::get_admin() == admin(), 'initialize wrong admin');
    }

    #[test]
    #[available_gas(10000000)]
    fn test_grant_role() {
        setup(admin());
        default_grant();

        let u = user();
        assert(AccessControl::has_role(R1, u), 'role R1 not granted');
        assert(AccessControl::has_role(R2, u), 'role R2 not granted');
        assert(AccessControl::get_roles(u) == R1 + R2, 'not all roles granted');
    }

    #[test]
    #[available_gas(10000000)]
    #[should_panic(expected: ('Caller not admin',))]
    fn test_grant_role_not_admin() {
        setup(badguy());
        AccessControl::grant_role(R2, badguy());
    }

    #[test]
    #[available_gas(10000000)]
    fn test_grant_role_multiple_users() {
        setup(admin());
        default_grant();

        let u = user();
        let u2 = contract_address_const::<0xbaba>();
        AccessControl::grant_role(R2 + R3 + R4, u2);
        assert(AccessControl::get_roles(u) == R1 + R2, 'wrong roles for u');
        assert(AccessControl::get_roles(u2) == R2 + R3 + R4, 'wrong roles for u2');
    }

    #[test]
    #[available_gas(10000000)]
    fn test_revoke_role() {
        setup(admin());
        default_grant();

        let u = user();
        AccessControl::revoke_role(R1, u);
        assert(AccessControl::has_role(R1, u) == false, 'role R1 not revoked');
        assert(AccessControl::has_role(R2, u), 'role R2 not kept');
        assert(AccessControl::get_roles(u) == R2, 'incorrect roles');
    }

    #[test]
    #[available_gas(10000000)]
    #[should_panic(expected: ('Caller not admin',))]
    fn test_revoke_role_not_admin() {
        setup(admin());
        set_caller_address(badguy());
        AccessControl::revoke_role(R1, user());
    }

    #[test]
    #[available_gas(10000000)]
    fn test_renounce_role() {
        setup(admin());
        default_grant();

        let u = user();
        set_caller_address(u);
        AccessControl::renounce_role(R1);
        assert(AccessControl::has_role(R1, u) == false, 'R1 role kept');
        // renouncing non-granted role should pass
        AccessControl::renounce_role(64);
    }

    #[test]
    #[available_gas(10000000)]
    fn test_set_pending_admin() {
        setup(admin());

        let pending_admin = user();
        AccessControl::set_pending_admin(pending_admin);
        assert(AccessControl::get_pending_admin() == pending_admin, 'pending admin not changed');
    }

    #[test]
    #[available_gas(10000000)]
    #[should_panic(expected: ('Caller not admin',))]
    fn test_set_pending_admin_not_admin() {
        setup(admin());
        set_caller_address(badguy());
        AccessControl::set_pending_admin(badguy());
    }

    #[test]
    #[available_gas(10000000)]
    fn test_accept_admin() {
        let current_admin = admin();
        setup(current_admin);

        let pending_admin = user();
        set_pending_admin(current_admin, pending_admin);

        set_caller_address(pending_admin);
        AccessControl::accept_admin();

        assert(AccessControl::get_admin() == pending_admin, 'admin not changed');
        assert(
            AccessControl::get_pending_admin() == ContractAddressZeroable::zero(),
            'pending admin not reset'
        );
    }

    #[test]
    #[available_gas(10000000)]
    #[should_panic(expected: ('Caller not pending admin',))]
    fn test_accept_admin_not_pending_admin() {
        let current_admin = admin();
        setup(current_admin);

        let pending_admin = user();
        set_pending_admin(current_admin, pending_admin);

        set_caller_address(badguy());
        AccessControl::accept_admin();
    }

    #[test]
    #[available_gas(10000000)]
    fn test_assert_has_role() {
        setup(admin());
        default_grant();

        set_caller_address(user());
        // should not throw
        AccessControl::assert_has_role(R1);
        AccessControl::assert_has_role(R1 + R2);
    }

    #[test]
    #[available_gas(10000000)]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_assert_has_role_panics() {
        setup(admin());
        default_grant();

        set_caller_address(user());
        AccessControl::assert_has_role(R3);
    }
}
