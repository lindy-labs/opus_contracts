mod ReentrancyGuard {
    use starknet::{
        ContractAddress, get_caller_address, Felt252TryIntoContractAddress, SyscallResultTrait
    };
    use starknet::storage_access::StorageAccessBool;

    use traits::{Into, TryInto};

    // SHA-256 (truncated to 251 bits) of '__reentrancyguard_guard'
    const GUARD_STORAGE_BASE_ADDR: felt252 =
        0x419b027bb2ae53e5a60723836fe05087557a431224b11a2c116be5e9e23b23e;

    #[inline(always)]
    fn set_guard(on: bool) {
        let base = starknet::storage_base_address_from_felt252(GUARD_STORAGE_BASE_ADDR);
        StorageAccessBool::write(0, base, on).unwrap_syscall();
    }

    fn start() {
        let base = starknet::storage_base_address_from_felt252(GUARD_STORAGE_BASE_ADDR);
        let is_on: bool = StorageAccessBool::read(0, base).unwrap_syscall();

        assert(!is_on, 'RG: reentrant call');
        set_guard(true);
    }

    fn end() {
        set_guard(false);
    }
}

#[cfg(test)]
mod tests {
    use super::ReentrancyGuard;

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
