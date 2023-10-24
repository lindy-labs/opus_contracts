mod tests {
    use opus::utils::reentrancy_guard::reentrancy_guard_component;
    use opus::utils::reentrancy_guard::reentrancy_guard_component::{ReentrancyGuardHelpers};

    use opus::tests::utils::mock_reentrancy_guard::{IMockReentrancyGuard, mock_reentrancy_guard};

    fn state() -> mock_reentrancy_guard::ContractState {
        mock_reentrancy_guard::contract_state_for_testing()
    }

    #[test]
    #[available_gas(9999999)]
    fn test_reentrancy_guard_pass() {
        let mut state = state();

        // It should be possible to call the guarded function multiple times in succession.
        state.guarded_func(false);
        state.guarded_func(false);
        state.guarded_func(false);
    }

    #[test]
    #[should_panic(expected: ('RG: reentrant call',))]
    #[available_gas(9999999)]
    fn test_reentrancy_guard_fail() {
        let mut state = state();
        // Calling the guarded function from inside itself should fail.
        state.guarded_func(true);
    }
}
