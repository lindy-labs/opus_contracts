#[cfg(test)]
mod tests {
    use aura::utils::reentrancy_guard::ReentrancyGuard;

    fn guarded_func(recurse_once: bool) {
        ReentrancyGuard::start();

        if recurse_once {
            guarded_func(false);
        }

        ReentrancyGuard::end();
    }

    #[test]
    #[available_gas(9999999)]
    fn test_reentrancy_guard_pass() {
        // It should be possible to call the guarded function multiple times in succession. 
        guarded_func(false);
        guarded_func(false);
        guarded_func(false);
    }

    #[test]
    #[should_panic(expected: ('RG: reentrant call', ))]
    #[available_gas(9999999)]
    fn test_reentrancy_guard_fail() {
        // Calling the guarded function from inside itself should fail.
        guarded_func(true);
    }
}
