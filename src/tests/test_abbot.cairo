#[cfg(test)]
mod TestAbbot {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::{ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_const, contract_address_to_felt252, deploy_syscall, SyscallResultTrait};
    use starknet::testing::set_contract_address;
    use traits::{Default, Into};

    use aura::core::abbot::Abbot;
    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{Wad, WadZeroable};

    use aura::tests::shrine::utils::ShrineUtils;


    //
    // Test setup helpers
    //

    fn abbot_deploy() -> (IShrineDispatcher, IAbbotDispatcher) {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        // TODO: update sentinel fixture
        let sentinel_addr: ContractAddress = contract_address_const::<0x12345678>();

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(shrine.contract_address));
        calldata.append(contract_address_to_felt252(sentinel_addr));

        let abbot_class_hash: ClassHash = class_hash_try_from_felt252(Abbot::TEST_CLASS_HASH)
            .unwrap();
        let (abbot_addr, _) = deploy_syscall(abbot_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        let abbot = IAbbotDispatcher { contract_address: abbot_addr };
        
        // Grant Shrine roles to Abbot
        set_contract_address(ShrineUtils::admin());
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine.contract_address };
        shrine_ac.grant_role(ShrineRoles::abbot(), abbot_addr);

        // TODO: auth Abbot in Sentinel

        (shrine, abbot)
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
    #[should_panic(expected: ('ABB: No yangs', 'ENTRYPOINT_FAILED'))]
    fn test_open_trove_no_yangs_fail() {
        let (_, abbot) = abbot_deploy();

        let yangs: Array<ContractAddress> = Default::default();
        let yang_amts: Array<u128> = Default::default();
        let forge_amt: Wad = 1_u128.into();
        let max_forge_fee_pct: Wad = WadZeroable::zero();

        abbot.open_trove(forge_amt, yangs.span(), yang_amts.span(), max_forge_fee_pct);   
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Array lengths mismatch', 'ENTRYPOINT_FAILED'))]
    fn test_open_trove_input_args_mismatch_fail() {
        let (_, abbot) = abbot_deploy();

        let mut yangs: Array<ContractAddress> = Default::default();
        yangs.append(ShrineUtils::yang1_addr());
        let yang_amts: Array<u128> = Default::default();
        let forge_amt: Wad = 1_u128.into();
        let max_forge_fee_pct: Wad = WadZeroable::zero();

        abbot.open_trove(forge_amt, yangs.span(), yang_amts.span(), max_forge_fee_pct);   
    }

    #[test]
    #[available_gas(20000000000)]
    // TODO: Error msg from Sentinel
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_open_trove_invalid_yang_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    fn test_close_trove_pass() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Not trove owner', 'ENTRYPOINT_FAILED'))]
    fn test_close_non_owner_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    fn test_deposit_pass() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Yang address cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_zero_address_yang_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Trove ID cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_zero_trove_id_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    // TODO: error msg from Sentinel
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_invalid_yang_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Non-existent trove', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_non_existent_trove_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    // Error message from Sentinel
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_exceeds_asset_cap_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    fn test_withdraw_pass() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Yang address cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_withdraw_zero_address_yang_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    // TODO: error msg from Sentinel
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_withdraw_invalid_yang_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Not trove owner', 'ENTRYPOINT_FAILED'))]
    fn test_withdraw_non_owner_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    fn test_forge_pass() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Trove LTV is too high', 'ENTRYPOINT_FAILED'))]
    fn test_forge_ltv_unsafe_fail() {

    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Not trove owner', 'ENTRYPOINT_FAILED'))]
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
