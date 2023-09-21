#[cfg(test)]
mod tests {
    use starknet::contract_address::{
        ContractAddress, ContractAddressZeroable, contract_address_try_from_felt252
    };
    use starknet::testing::{pop_log_raw, set_caller_address};

    use aura::utils::access_control::AccessControl;

    use aura::tests::common;

    // mock roles
    const R1: u128 = 1_u128;
    const R2: u128 = 2_u128;
    const R3: u128 = 128_u128;
    const R4: u128 = 256_u128;

    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('access control admin').unwrap()
    }

    fn user() -> ContractAddress {
        contract_address_try_from_felt252('user').unwrap()
    }

    fn setup(caller: ContractAddress) {
        AccessControl::initializer(admin(), Option::None);
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

    fn drop_events(count: u8) {
        let mut idx = 0;
        loop {
            if idx == count {
                break;
            }
            pop_log_raw(ContractAddressZeroable::zero());

            idx += 1;
        };
    }

    #[test]
    #[available_gas(10000000)]
    fn test_initializer() {
        let admin = admin();
        AccessControl::initializer(admin, Option::None);
        assert(AccessControl::get_admin() == admin, 'initialize wrong admin');

        let (mut keys, mut data) = pop_log_raw(ContractAddressZeroable::zero()).unwrap();
        assert(
            *keys.pop_front().unwrap() == AccessControl::ADMIN_CHANGED_EVENT_KEY,
            'should be AdminChanged'
        );
        assert(keys.len().is_zero(), 'keys should be empty');

        assert(
            contract_address_try_from_felt252(*data.pop_front().unwrap()).unwrap().is_zero(),
            'should be zero addr'
        );
        assert(
            contract_address_try_from_felt252(*data.pop_front().unwrap()).unwrap() == admin,
            'should be admin'
        );
        assert(data.len().is_zero(), 'data should be empty');

        assert(pop_log_raw(ContractAddressZeroable::zero()).is_none(), 'unexpected event');
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

        drop_events(1);

        let (mut keys, mut data) = pop_log_raw(ContractAddressZeroable::zero()).unwrap();
        assert(
            *keys.pop_front().unwrap() == AccessControl::ROLE_GRANTED_EVENT_KEY,
            'should be RoleGranted'
        );
        assert(keys.len().is_zero(), 'keys should be empty');

        assert((*data.pop_front().unwrap()).try_into().unwrap() == R1, 'should be R1');
        assert(
            contract_address_try_from_felt252(*data.pop_front().unwrap()).unwrap() == u,
            'should be user'
        );
        assert(data.len().is_zero(), 'data should be empty');

        let (mut keys, mut data) = pop_log_raw(ContractAddressZeroable::zero()).unwrap();
        assert(
            *keys.pop_front().unwrap() == AccessControl::ROLE_GRANTED_EVENT_KEY,
            'should be RoleGranted'
        );
        assert(keys.len().is_zero(), 'keys should be empty');

        assert((*data.pop_front().unwrap()).try_into().unwrap() == R2, 'should be R2');
        assert(
            contract_address_try_from_felt252(*data.pop_front().unwrap()).unwrap() == u,
            'should be user'
        );
        assert(data.len().is_zero(), 'data should be empty');

        assert(pop_log_raw(ContractAddressZeroable::zero()).is_none(), 'unexpected event');
    }

    #[test]
    #[available_gas(10000000)]
    #[should_panic(expected: ('Caller not admin',))]
    fn test_grant_role_not_admin() {
        setup(common::badguy());
        AccessControl::grant_role(R2, common::badguy());
    }

    #[test]
    #[available_gas(10000000)]
    fn test_grant_role_multiple_users() {
        setup(admin());
        default_grant();

        let u = user();
        let u2 = contract_address_try_from_felt252('user 2').unwrap();
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

        drop_events(3);

        let (mut keys, mut data) = pop_log_raw(ContractAddressZeroable::zero()).unwrap();
        assert(
            *keys.pop_front().unwrap() == AccessControl::ROLE_REVOKED_EVENT_KEY,
            'should be RoleRevoked'
        );
        assert(keys.len().is_zero(), 'keys should be empty');

        assert((*data.pop_front().unwrap()).try_into().unwrap() == R1, 'should be R1');
        assert(
            contract_address_try_from_felt252(*data.pop_front().unwrap()).unwrap() == u,
            'should be user'
        );
        assert(data.len().is_zero(), 'data should be empty');

        assert(pop_log_raw(ContractAddressZeroable::zero()).is_none(), 'unexpected event');
    }

    #[test]
    #[available_gas(10000000)]
    #[should_panic(expected: ('Caller not admin',))]
    fn test_revoke_role_not_admin() {
        setup(admin());
        set_caller_address(common::badguy());
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
        let non_existent_role: u128 = 64;
        AccessControl::renounce_role(non_existent_role);

        drop_events(3);

        let (mut keys, mut data) = pop_log_raw(ContractAddressZeroable::zero()).unwrap();
        assert(
            *keys.pop_front().unwrap() == AccessControl::ROLE_REVOKED_EVENT_KEY,
            'should be RoleGranted'
        );
        assert(keys.len().is_zero(), 'keys should be empty');

        assert((*data.pop_front().unwrap()).try_into().unwrap() == R1, 'should be R1');
        assert(
            contract_address_try_from_felt252(*data.pop_front().unwrap()).unwrap() == u,
            'should be user'
        );
        assert(data.len().is_zero(), 'data should be empty');

        let (mut keys, mut data) = pop_log_raw(ContractAddressZeroable::zero()).unwrap();
        assert(
            *keys.pop_front().unwrap() == AccessControl::ROLE_REVOKED_EVENT_KEY,
            'should be RoleRevoked'
        );
        assert(keys.len().is_zero(), 'keys should be empty');

        assert(
            (*data.pop_front().unwrap()).try_into().unwrap() == non_existent_role,
            'should be non-existent role'
        );
        assert(
            contract_address_try_from_felt252(*data.pop_front().unwrap()).unwrap() == u,
            'should be user'
        );
        assert(data.len().is_zero(), 'data should be empty');

        assert(pop_log_raw(ContractAddressZeroable::zero()).is_none(), 'unexpected event');
    }

    #[test]
    #[available_gas(10000000)]
    fn test_set_pending_admin() {
        setup(admin());

        let pending_admin = user();
        AccessControl::set_pending_admin(pending_admin);
        assert(AccessControl::get_pending_admin() == pending_admin, 'pending admin not changed');

        drop_events(1);

        let (mut keys, mut data) = pop_log_raw(ContractAddressZeroable::zero()).unwrap();
        assert(
            *keys.pop_front().unwrap() == AccessControl::NEW_PENDING_ADMIN_EVENT_KEY,
            'should be RoleGranted'
        );
        assert(keys.len().is_zero(), 'keys should be empty');

        assert(
            contract_address_try_from_felt252(*data.pop_front().unwrap()).unwrap() == pending_admin,
            'should be user'
        );
        assert(data.len().is_zero(), 'data should be empty');

        assert(pop_log_raw(ContractAddressZeroable::zero()).is_none(), 'unexpected event');
    }

    #[test]
    #[available_gas(10000000)]
    #[should_panic(expected: ('Caller not admin',))]
    fn test_set_pending_admin_not_admin() {
        setup(admin());
        set_caller_address(common::badguy());
        AccessControl::set_pending_admin(common::badguy());
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

        drop_events(2);

        let (mut keys, mut data) = pop_log_raw(ContractAddressZeroable::zero()).unwrap();
        assert(
            *keys.pop_front().unwrap() == AccessControl::ADMIN_CHANGED_EVENT_KEY,
            'should be AdminChanged'
        );
        assert(keys.len().is_zero(), 'keys should be empty');

        assert(
            contract_address_try_from_felt252(*data.pop_front().unwrap()).unwrap() == current_admin,
            'should be current admin'
        );
        assert(
            contract_address_try_from_felt252(*data.pop_front().unwrap()).unwrap() == pending_admin,
            'should be new admin'
        );
        assert(data.len().is_zero(), 'data should be empty');

        assert(pop_log_raw(ContractAddressZeroable::zero()).is_none(), 'unexpected event');
    }

    #[test]
    #[available_gas(10000000)]
    #[should_panic(expected: ('Caller not pending admin',))]
    fn test_accept_admin_not_pending_admin() {
        let current_admin = admin();
        setup(current_admin);

        let pending_admin = user();
        set_pending_admin(current_admin, pending_admin);

        set_caller_address(common::badguy());
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
