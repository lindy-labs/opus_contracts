#[cfg(test)]
mod TestAbbot {
    use array::{ArrayTrait, SpanTrait};
    use integer::BoundedU256;
    use option::OptionTrait;
    use starknet::{
        ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_const,
        contract_address_to_felt252, deploy_syscall, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;
    use traits::{Default, Into};

    use aura::core::abbot::Abbot;
    use aura::core::roles::SentinelRoles;
    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IERC20::{
        IERC20Dispatcher, IERC20DispatcherTrait, IMintableDispatcher, IMintableDispatcherTrait
    };
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{Wad, WadZeroable};

    use aura::tests::sentinel::utils::SentinelUtils;
    use aura::tests::shrine::utils::ShrineUtils;
    use aura::tests::test_utils;

    //
    // Constants
    //

    const ETH_DEPOSIT_AMT: u128 = 10000000000000000000; // 10 (Wad);
    const WBTC_DEPOSIT_AMT: u128 = 50000000; // 0.5 (WBTC decimals);
    const OPEN_TROVE_FORGE_AMT: u128 = 2000000000000000000000; // 2_000 (Wad)

    //
    // Test setup helpers
    //

    fn abbot_deploy() -> (
        IShrineDispatcher, IAbbotDispatcher, Span<ContractAddress>, Span<IGateDispatcher>
    ) {
        let (sentinel, shrine, yangs, gates) = SentinelUtils::deploy_sentinel_with_gates();
        ShrineUtils::shrine_setup(shrine.contract_address);

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(shrine.contract_address));
        calldata.append(contract_address_to_felt252(sentinel.contract_address));

        let abbot_class_hash: ClassHash = class_hash_try_from_felt252(Abbot::TEST_CLASS_HASH)
            .unwrap();
        let (abbot_addr, _) = deploy_syscall(abbot_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        let abbot = IAbbotDispatcher { contract_address: abbot_addr };

        // Grant Shrine roles to Abbot
        set_contract_address(ShrineUtils::admin());
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine.contract_address };
        shrine_ac.grant_role(ShrineRoles::abbot(), abbot_addr);

        // Grant Sentinel roles to Abbot
        let sentinel_ac = IAccessControlDispatcher { contract_address: sentinel.contract_address };
        sentinel_ac.grant_role(SentinelRoles::ENTER + SentinelRoles::EXIT, abbot_addr);

        (shrine, abbot, yangs, gates)
    }

    //
    // Tests
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_open_trove_pass() {
        let (shrine, abbot, yangs, gates) = abbot_deploy();
        let trove_owner: ContractAddress = ShrineUtils::trove1_owner_addr();

        let eth_addr: ContractAddress = *yangs.at(0);
        let eth_gate: IGateDispatcher = *gates.at(0);
        let wbtc_addr: ContractAddress = *yangs.at(1);
        let wbtc_gate: IGateDispatcher = *gates.at(1);

        let before_eth_yang_total: Wad = shrine.get_yang_total(eth_addr);
        let before_wbtc_yang_total: Wad = shrine.get_yang_total(wbtc_addr);

        // Mint yang assets to trove owner
        IMintableDispatcher {
            contract_address: eth_addr
        }.mint(trove_owner, ETH_DEPOSIT_AMT.into());
        IMintableDispatcher {
            contract_address: wbtc_addr
        }.mint(trove_owner, WBTC_DEPOSIT_AMT.into());

        set_contract_address(trove_owner);
        IERC20Dispatcher {
            contract_address: eth_addr
        }.approve(eth_gate.contract_address, BoundedU256::max());
        IERC20Dispatcher {
            contract_address: wbtc_addr
        }.approve(wbtc_gate.contract_address, BoundedU256::max());

        // Open trove
        let mut yang_asset_amts: Array<u128> = Default::default();
        yang_asset_amts.append(ETH_DEPOSIT_AMT);
        yang_asset_amts.append(WBTC_DEPOSIT_AMT);

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();

        abbot.open_trove(forge_amt, yangs, yang_asset_amts.span(), 0_u128.into());

        // Check trove ID
        let expected_trove_id: u64 = 1;
        assert(abbot.get_trove_owner(expected_trove_id) == trove_owner, 'wrong trove owner');
        assert(abbot.get_troves_count() == expected_trove_id, 'wrong troves count');

        let mut expected_user_trove_ids: Array<u64> = Default::default();
        expected_user_trove_ids.append(expected_trove_id);
        assert(
            abbot.get_user_trove_ids(trove_owner) == expected_user_trove_ids.span(),
            'wrong user trove ids'
        );

        // Check yang amounts
        let expected_eth_yang_total = before_eth_yang_total + ETH_DEPOSIT_AMT.into();
        assert(shrine.get_yang_total(eth_addr) == expected_eth_yang_total, 'wrong ETH yang total');
        let expected_wbtc_yang_total: Wad = before_wbtc_yang_total
            + wadray::fixed_point_to_wad(WBTC_DEPOSIT_AMT, test_utils::WBTC_DECIMALS);
        assert(
            shrine.get_yang_total(wbtc_addr) == expected_wbtc_yang_total, 'wrong WBTC yang total'
        );

        // Check trove's debt
        // TODO: calling `shrine.get_trove_info()` results in `Unknown ap change` error
        //let (_, _, _, debt) = shrine.get_trove_info(expected_trove_id);
        //assert(actual_debt == forge_amt, 'wrong trove debt');

        assert(shrine.get_total_debt() == forge_amt, 'wrong total debt');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: No yangs', 'ENTRYPOINT_FAILED'))]
    fn test_open_trove_no_yangs_fail() {
        let (_, abbot, _, _) = abbot_deploy();

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
        let (_, abbot, _, _) = abbot_deploy();

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
    #[should_panic(expected: ('', 'ENTRYPOINT_FAILED'))]
    fn test_open_trove_invalid_yang_fail() {}

    #[test]
    #[available_gas(20000000000)]
    fn test_close_trove_pass() {}

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Not trove owner', 'ENTRYPOINT_FAILED'))]
    fn test_close_non_owner_fail() {}

    #[test]
    #[available_gas(20000000000)]
    fn test_deposit_pass() {}

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Yang address cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_zero_address_yang_fail() {
        let (_, abbot, _, _) = abbot_deploy();

        let invalid_yang_addr = ContractAddressZeroable::zero();
        let trove_id: u64 = ShrineUtils::TROVE_1;
        let amount: u128 = 1;

        abbot.deposit(invalid_yang_addr, trove_id, amount);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Trove ID cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_zero_trove_id_fail() {
        let (_, abbot, _, _) = abbot_deploy();

        let yang_addr = ShrineUtils::yang1_addr();
        let invalid_trove_id: u64 = 0;
        let amount: u128 = 1;

        abbot.deposit(yang_addr, invalid_trove_id, amount);
    }

    #[test]
    #[available_gas(20000000000)]
    // TODO: error msg from Sentinel
    #[should_panic(expected: ('', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_invalid_yang_fail() {}

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Non-existent trove', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_non_existent_trove_fail() {}

    #[test]
    #[available_gas(20000000000)]
    // Error message from Sentinel
    #[should_panic(expected: ('', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_exceeds_asset_cap_fail() {}

    #[test]
    #[available_gas(20000000000)]
    fn test_withdraw_pass() {}

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Yang address cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_withdraw_zero_address_yang_fail() {
        let (_, abbot, _, _) = abbot_deploy();

        let invalid_yang_addr = ContractAddressZeroable::zero();
        let trove_id: u64 = ShrineUtils::TROVE_1;
        let amount: u128 = 1;

        abbot.deposit(invalid_yang_addr, trove_id, amount);
    }

    #[test]
    #[available_gas(20000000000)]
    // TODO: error msg from Sentinel
    #[should_panic(expected: ('', 'ENTRYPOINT_FAILED'))]
    fn test_withdraw_invalid_yang_fail() {}

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Not trove owner', 'ENTRYPOINT_FAILED'))]
    fn test_withdraw_non_owner_fail() {}

    #[test]
    #[available_gas(20000000000)]
    fn test_forge_pass() {}

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Trove LTV is too high', 'ENTRYPOINT_FAILED'))]
    fn test_forge_ltv_unsafe_fail() {}

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Not trove owner', 'ENTRYPOINT_FAILED'))]
    fn test_forge_non_owner_fail() {}

    #[test]
    #[available_gas(20000000000)]
    fn test_melt_pass() {}

    #[test]
    #[available_gas(20000000000)]
    fn test_get_trove_owner() {}

    #[test]
    #[available_gas(20000000000)]
    fn test_get_user_trove_ids() {}
}
