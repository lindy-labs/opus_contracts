mod ReentrancyGuard {
    use starknet::{
        ContractAddress, get_caller_address, Felt252TryIntoContractAddress, SyscallResultTrait
    };
    use starknet::storage_access::StoreBool;

    use traits::{Into, TryInto};


    const GUARD_STORAGE_BASE_ADDR: felt252 = selector!("__reentrancyguard_entered");

    #[inline(always)]
    fn write_guard(entered: bool) {
        let base = starknet::storage_base_address_from_felt252(GUARD_STORAGE_BASE_ADDR);
        StoreBool::write(0, base, entered).unwrap_syscall();
    }

    fn start() {
        let base = starknet::storage_base_address_from_felt252(GUARD_STORAGE_BASE_ADDR);
        let has_entered: bool = StoreBool::read(0, base).unwrap_syscall();

        assert(!has_entered, 'RG: reentrant call');
        write_guard(true);
    }

    fn end() {
        write_guard(false);
    }
}
