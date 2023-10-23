mod tests {
    use starknet::contract_address::{
        ContractAddress, ContractAddressZeroable, contract_address_try_from_felt252
    };
    use starknet::testing::{pop_log, pop_log_raw, set_caller_address};

    use opus::utils::access_control::access_control_component;
    use opus::utils::access_control::access_control_component::{
        AccessControlPublic, AccessControlHelpers
    };

    use opus::tests::common;
    use opus::tests::utils::mock_access_control::MockAccessControl;

    //
    // Constants
    //

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

    fn zero_addr() -> ContractAddress {
        ContractAddressZeroable::zero()
    }

    //
    // Test setup
    //

    fn state() -> MockAccessControl::ContractState {
        MockAccessControl::contract_state_for_testing()
    }

    fn setup(caller: ContractAddress) -> MockAccessControl::ContractState {
        let mut state = state();
        state.access_control.initializer(admin(), Option::None);

        set_caller_address(caller);

        state
    }

    fn set_pending_admin(
        ref state: MockAccessControl::ContractState,
        caller: ContractAddress,
        pending_admin: ContractAddress
    ) {
        set_caller_address(caller);
        state.set_pending_admin(pending_admin);
    }

    fn default_grant(ref state: MockAccessControl::ContractState) {
        let u = user();
        state.grant_role(R1, u);
        state.grant_role(R2, u);
    }

    //
    // Tests
    //

    #[test]
    #[available_gas(10000000)]
    fn test_initializer() {
        let admin = admin();

        let state = setup(admin);

        assert(state.get_admin() == admin, 'initialize wrong admin');

        let event = pop_log::<access_control_component::AdminChanged>(zero_addr()).unwrap();
        assert(event.old_admin.is_zero(), 'should be zero address');
        assert(event.new_admin == admin(), 'wrong admin in event');

        assert(pop_log_raw(zero_addr()).is_none(), 'unexpected event');
    }

    #[test]
    #[available_gas(10000000)]
    fn test_grant_role() {
        let mut state = setup(admin());
        common::drop_all_events(zero_addr());

        default_grant(ref state);

        let u = user();
        assert(state.has_role(R1, u), 'role R1 not granted');
        assert(state.has_role(R2, u), 'role R2 not granted');
        assert(state.get_roles(u) == R1 + R2, 'not all roles granted');

        let event = pop_log::<access_control_component::RoleGranted>(zero_addr()).unwrap();
        assert(event.user == u, 'wrong user in event #1');
        assert(event.role_granted == R1, 'wrong role in event #1');

        let event = pop_log::<access_control_component::RoleGranted>(zero_addr()).unwrap();
        assert(event.user == u, 'wrong user in event #2');
        assert(event.role_granted == R2, 'wrong role in event #2');

        assert(pop_log_raw(zero_addr()).is_none(), 'unexpected event');
    }

    #[test]
    #[available_gas(10000000)]
    #[should_panic(expected: ('Caller not admin',))]
    fn test_grant_role_not_admin() {
        let mut state = setup(common::badguy());
        state.grant_role(R2, common::badguy());
    }

    #[test]
    #[available_gas(10000000)]
    fn test_grant_role_multiple_users() {
        let mut state = setup(admin());
        default_grant(ref state);

        let u = user();
        let u2 = contract_address_try_from_felt252('user 2').unwrap();
        state.grant_role(R2 + R3 + R4, u2);
        assert(state.get_roles(u) == R1 + R2, 'wrong roles for u');
        assert(state.get_roles(u2) == R2 + R3 + R4, 'wrong roles for u2');
    }

    #[test]
    #[available_gas(10000000)]
    fn test_revoke_role() {
        let mut state = setup(admin());
        default_grant(ref state);

        common::drop_all_events(zero_addr());

        let u = user();
        state.revoke_role(R1, u);
        assert(state.has_role(R1, u) == false, 'role R1 not revoked');
        assert(state.has_role(R2, u), 'role R2 not kept');
        assert(state.get_roles(u) == R2, 'incorrect roles');

        let event = pop_log::<access_control_component::RoleRevoked>(zero_addr()).unwrap();
        assert(event.user == u, 'wrong user in event');
        assert(event.role_revoked == R1, 'wrong role in event');

        assert(pop_log_raw(zero_addr()).is_none(), 'unexpected event');
    }

    #[test]
    #[available_gas(10000000)]
    #[should_panic(expected: ('Caller not admin',))]
    fn test_revoke_role_not_admin() {
        let mut state = setup(admin());
        set_caller_address(common::badguy());
        state.revoke_role(R1, user());
    }

    #[test]
    #[available_gas(10000000)]
    fn test_renounce_role() {
        let mut state = setup(admin());
        default_grant(ref state);

        common::drop_all_events(zero_addr());

        let u = user();
        set_caller_address(u);
        state.renounce_role(R1);
        assert(state.has_role(R1, u) == false, 'R1 role kept');

        // renouncing non-granted role should pass
        let non_existent_role: u128 = 64;
        state.renounce_role(non_existent_role);

        let event = pop_log::<access_control_component::RoleRevoked>(zero_addr()).unwrap();
        assert(event.user == u, 'wrong user in event #1');
        assert(event.role_revoked == R1, 'wrong role in event #1');

        let event = pop_log::<access_control_component::RoleRevoked>(zero_addr()).unwrap();
        assert(event.user == u, 'wrong user in event #2');
        assert(event.role_revoked == non_existent_role, 'wrong role in event #2');

        assert(pop_log_raw(zero_addr()).is_none(), 'unexpected event');
    }

    #[test]
    #[available_gas(10000000)]
    fn test_set_pending_admin() {
        let mut state = setup(admin());

        common::drop_all_events(zero_addr());

        let pending_admin = user();
        state.set_pending_admin(pending_admin);
        assert(state.get_pending_admin() == pending_admin, 'pending admin not changed');

        let event = pop_log::<access_control_component::NewPendingAdmin>(zero_addr()).unwrap();
        assert(event.new_admin == pending_admin, 'wrong user in event');

        assert(pop_log_raw(zero_addr()).is_none(), 'unexpected event');
    }

    #[test]
    #[available_gas(10000000)]
    #[should_panic(expected: ('Caller not admin',))]
    fn test_set_pending_admin_not_admin() {
        let mut state = setup(admin());
        set_caller_address(common::badguy());
        state.set_pending_admin(common::badguy());
    }

    #[test]
    #[available_gas(10000000)]
    fn test_accept_admin() {
        let current_admin = admin();
        let mut state = setup(current_admin);

        let pending_admin = user();
        set_pending_admin(ref state, current_admin, pending_admin);

        common::drop_all_events(zero_addr());

        set_caller_address(pending_admin);
        state.accept_admin();

        assert(state.get_admin() == pending_admin, 'admin not changed');
        assert(state.get_pending_admin().is_zero(), 'pending admin not reset');

        let event = pop_log::<access_control_component::AdminChanged>(zero_addr()).unwrap();
        assert(event.old_admin == current_admin, 'wrong old admin in event');
        assert(event.new_admin == pending_admin, 'wrong new admin in event');

        assert(pop_log_raw(zero_addr()).is_none(), 'unexpected event');
    }

    #[test]
    #[available_gas(10000000)]
    #[should_panic(expected: ('Caller not pending admin',))]
    fn test_accept_admin_not_pending_admin() {
        let current_admin = admin();
        let mut state = setup(current_admin);

        let pending_admin = user();
        set_pending_admin(ref state, current_admin, pending_admin);

        set_caller_address(common::badguy());
        state.accept_admin();
    }

    #[test]
    #[available_gas(10000000)]
    fn test_assert_has_role() {
        let mut state = setup(admin());
        default_grant(ref state);

        set_caller_address(user());
        // should not throw
        state.access_control.assert_has_role(R1);
        state.access_control.assert_has_role(R1 + R2);
    }

    #[test]
    #[available_gas(10000000)]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_assert_has_role_panics() {
        let mut state = setup(admin());
        default_grant(ref state);

        set_caller_address(user());
        state.access_control.assert_has_role(R3);
    }
}
