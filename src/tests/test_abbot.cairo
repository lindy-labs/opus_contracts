#[cfg(test)]
mod TestAbbot {
    use array::{ArrayTrait, SpanTrait};
    use starknet::{ContractAddress, contract_address_const, deploy_syscall, ClassHash, class_hash_try_from_felt252, SyscallResultTrait};
    use traits::Default;

    use aura::core::abbot::Abbot;

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IAbbot::{IShrineDispatcher, IShrineDispatcherTrait};

    use aura::tests::shrine::utils::ShrineUtils;


    //
    // Test setup helpers
    //

    fn abbot_deploy() -> IAbbotDispatcher {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        // TODO: update sentinel fixture
        let sentinel_addr: ContractAddress = contract_address_const::<0x12345678>;

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(shrine.contract_address));
        calldata.append(contract_address_to_felt252(sentinel_addr);

        let abbot_class_hash: ClassHash = class_hash_try_from_felt252(Abbot::TEST_CLASS_HASH)
            .unwrap();
        let (abbot_addr, _) = deploy_syscall(abbot_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        IAbbotDispatcher { contract_address: abbot_addr }
    }

    //
    // Tests
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_open_trove_pass() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_open_trove_input_args_mismatch_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_open_trove_no_yangs_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_open_trove_invalid_yang_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    fn test_close_trove_pass() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_close_non_owner_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    fn test_deposit_pass() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_zero_address_yang_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_zero_trove_id_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_invalid_yang_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_non_existent_trove_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_exceeds_asset_cap_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    fn test_withdraw_pass() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_withdraw_zero_address_yang_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_withdraw_invalid_yang_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_withdraw_non_owner_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    fn test_forge_pass() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_forge_ltv_unsafe_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_forge_non_owner_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    fn test_melt_pass() {

    }

    #[test]
    #[available_gas(20000000000)]
    fn test_get_trove_owner() {

    }

    #[test]
    #[available_gas(20000000000)]
    fn test_get_user_trove_ids() {

    }

}
