mod ReentrancyGuard {
    use starknet::{
        ContractAddress, get_caller_address, Felt252TryIntoContractAddress, SyscallResultTrait
    };
    use starknet::storage_access::StorageAccessBool;

    use traits::{Into, TryInto};

    // get_storage_var_address('__reentrancyguard_entered')
    const GUARD_STORAGE_BASE_ADDR: felt252 =
        0x380125a0565a0f8085b5cc6540da297573e83173fadf00aa7ca010e2f45e41a;

    #[inline(always)]
    fn write_guard(entered: bool) {
        let base = starknet::storage_base_address_from_felt252(GUARD_STORAGE_BASE_ADDR);
        StorageAccessBool::write(0, base, entered).unwrap_syscall();
    }

    fn start() {
        let base = starknet::storage_base_address_from_felt252(GUARD_STORAGE_BASE_ADDR);
        let has_entered: bool = StorageAccessBool::read(0, base).unwrap_syscall();

        assert(!has_entered, 'RG: reentrant call');
        write_guard(true);
    }

    fn end() {
        write_guard(false);
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
