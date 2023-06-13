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
    use traits::{Default, Into, TryInto};

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
    use aura::utils::wadray::{Wad, WadZeroable, WAD_SCALE};

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
        IShrineDispatcher,
        ISentinelDispatcher,
        IAbbotDispatcher,
        Span<ContractAddress>,
        Span<IGateDispatcher>
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

        (shrine, sentinel, abbot, yangs, gates)
    }

    fn initial_asset_amts() -> Span<u128> {
        let mut asset_amts: Array<u128> = Default::default();
        asset_amts.append(ETH_DEPOSIT_AMT * 10);
        asset_amts.append(WBTC_DEPOSIT_AMT * 10);
        asset_amts.span()
    }

    fn open_trove_yang_asset_amts() -> Span<u128> {
        let mut asset_amts: Array<u128> = Default::default();
        asset_amts.append(ETH_DEPOSIT_AMT);
        asset_amts.append(WBTC_DEPOSIT_AMT);
        asset_amts.span()
    }

    fn fund_user(user: ContractAddress, mut yangs: Span<ContractAddress>, mut asset_amts: Span<u128>) {
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    IMintableDispatcher {
                        contract_address: *yang
                    }.mint(user, (*asset_amts.pop_front().unwrap()).into());
                },
                Option::None(_) => {
                    break;
                }
            };
        };
    }

    fn open_trove_helper(
        abbot: IAbbotDispatcher,
        user: ContractAddress,
        mut yangs: Span<ContractAddress>,
        yang_asset_amts: Span<u128>,
        mut gates: Span<IGateDispatcher>,
        forge_amt: Wad
    ) -> u64 {
        set_contract_address(user);
        let mut yangs_copy = yangs;
        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => {
                    // Approve Gate to transfer from user
                    IERC20Dispatcher {
                        contract_address: *yang
                    }.approve((*gates.pop_front().unwrap()).contract_address, BoundedU256::max());
                },
                Option::None(_) => {
                    break;
                }
            };
        };

        let trove_id: u64 = abbot
            .open_trove(forge_amt, yangs, yang_asset_amts, 0_u128.into());

        set_contract_address(ContractAddressZeroable::zero());

        trove_id
    }

    //
    // Tests
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_open_trove_pass() {
        let (shrine, _, abbot, yangs, gates) = abbot_deploy();
        let trove_owner: ContractAddress = ShrineUtils::trove1_owner_addr();

        let eth_addr: ContractAddress = *yangs.at(0);
        let wbtc_addr: ContractAddress = *yangs.at(1);

        let before_eth_yang_total: Wad = shrine.get_yang_total(eth_addr);
        let before_wbtc_yang_total: Wad = shrine.get_yang_total(wbtc_addr);

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        fund_user(trove_owner, yangs, initial_asset_amts());
        let trove_id: u64 = open_trove_helper(abbot, trove_owner, yangs, open_trove_yang_asset_amts(), gates, forge_amt);

        // Check trove ID
        let expected_trove_id: u64 = 1;
        assert(trove_id == expected_trove_id, 'wrong trove ID', );
        assert(abbot.get_trove_owner(expected_trove_id) == trove_owner, 'wrong trove owner');
        assert(abbot.get_troves_count() == expected_trove_id, 'wrong troves count');

        let mut expected_user_trove_ids: Array<u64> = Default::default();
        expected_user_trove_ids.append(expected_trove_id);
        assert(
            abbot.get_user_trove_ids(trove_owner) == expected_user_trove_ids.span(),
            'wrong user trove ids'
        );

        // Check yang amounts
        //assert(shrine.get_deposit(eth_addr, expected_trove_id) == ETH_DEPOSIT_AMT.into(), 'wrong ETH yang amount');
        //let expected_wbtc_yang: Wad = wadray::fixed_point_to_wad(WBTC_DEPOSIT_AMT, test_utils::WBTC_DECIMALS);
        //assert(
        //    shrine.get_deposit(wbtc_addr, expected_trove_id) == expected_wbtc_yang, 'wrong WBTC yang amount'
        //);

        // TODO: The snippet commented out above leads to `Unknown ap change` error
        //       As a workaround, we test the total yang amount.
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
        //assert(debt == forge_amt, 'wrong trove debt');

        assert(shrine.get_total_debt() == forge_amt, 'wrong total debt');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: No yangs', 'ENTRYPOINT_FAILED'))]
    fn test_open_trove_no_yangs_fail() {
        let (_, _, abbot, _, _) = abbot_deploy();

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
        let (_, _, abbot, _, _) = abbot_deploy();

        let mut yangs: Array<ContractAddress> = Default::default();
        yangs.append(ShrineUtils::yang1_addr());
        let yang_amts: Array<u128> = Default::default();
        let forge_amt: Wad = 1_u128.into();
        let max_forge_fee_pct: Wad = WadZeroable::zero();

        abbot.open_trove(forge_amt, yangs.span(), yang_amts.span(), max_forge_fee_pct);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(
        expected: ('SE: Yang is not approved', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED')
    )]
    fn test_open_trove_invalid_yang_fail() {
        let (shrine, _, abbot, yangs, gates) = abbot_deploy();

        let invalid_yang: ContractAddress = contract_address_const::<0xdead>();
        let mut yangs: Array<ContractAddress> = Default::default();
        yangs.append(invalid_yang);
        let mut yang_amts: Array<u128> = Default::default();
        yang_amts.append(WAD_SCALE);
        let forge_amt: Wad = 1_u128.into();
        let max_forge_fee_pct: Wad = WadZeroable::zero();

        abbot.open_trove(forge_amt, yangs.span(), yang_amts.span(), max_forge_fee_pct);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_close_trove_pass() {
        let (shrine, _, abbot, yangs, gates) = abbot_deploy();
        let trove_owner: ContractAddress = ShrineUtils::trove1_owner_addr();

        let eth_addr: ContractAddress = *yangs.at(0);
        let wbtc_addr: ContractAddress = *yangs.at(1);

        let before_eth_yang_total: Wad = shrine.get_yang_total(eth_addr);
        let before_wbtc_yang_total: Wad = shrine.get_yang_total(wbtc_addr);

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        fund_user(trove_owner, yangs, initial_asset_amts());
        let trove_id: u64 = open_trove_helper(abbot, trove_owner, yangs, open_trove_yang_asset_amts(), gates, forge_amt);

        set_contract_address(trove_owner);
        abbot.close_trove(trove_id);

        assert(
            shrine.get_deposit(eth_addr, trove_id) == WadZeroable::zero(), 'wrong ETH yang amount'
        );
        assert(
            shrine.get_deposit(wbtc_addr, trove_id) == WadZeroable::zero(), 'wrong WBTC yang amount'
        );

        let (_, _, _, debt) = shrine.get_trove_info(trove_id);
        assert(debt == WadZeroable::zero(), 'wrong trove debt');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Not trove owner', 'ENTRYPOINT_FAILED'))]
    fn test_close_non_owner_fail() {
        let (shrine, _, abbot, yangs, gates) = abbot_deploy();
        let trove_owner: ContractAddress = ShrineUtils::trove1_owner_addr();

        let eth_addr: ContractAddress = *yangs.at(0);
        let wbtc_addr: ContractAddress = *yangs.at(1);

        let before_eth_yang_total: Wad = shrine.get_yang_total(eth_addr);
        let before_wbtc_yang_total: Wad = shrine.get_yang_total(wbtc_addr);

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        fund_user(trove_owner, yangs, initial_asset_amts());
        let trove_id: u64 = open_trove_helper(abbot, trove_owner, yangs, open_trove_yang_asset_amts(), gates, forge_amt);

        set_contract_address(ShrineUtils::badguy());
        abbot.close_trove(trove_id);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_deposit_pass() {
        let (shrine, _, abbot, yangs, gates) = abbot_deploy();
        let trove_owner: ContractAddress = ShrineUtils::trove1_owner_addr();

        let eth_addr: ContractAddress = *yangs.at(0);
        let wbtc_addr: ContractAddress = *yangs.at(1);

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        fund_user(trove_owner, yangs, initial_asset_amts());
        let trove_id: u64 = open_trove_helper(abbot, trove_owner, yangs, open_trove_yang_asset_amts(), gates, forge_amt);

        let before_eth_yang: Wad = shrine.get_deposit(eth_addr, trove_id);
        let before_wbtc_yang: Wad = shrine.get_deposit(wbtc_addr, trove_id);

        set_contract_address(trove_owner);
        abbot.deposit(eth_addr, trove_id, ETH_DEPOSIT_AMT);
        abbot.deposit(wbtc_addr, trove_id, WBTC_DEPOSIT_AMT);

        let expected_eth_yang: Wad = before_eth_yang + ETH_DEPOSIT_AMT.into();
        assert(
            shrine.get_deposit(eth_addr, trove_id) == expected_eth_yang, 'wrong ETH yang amount'
        );

        let expected_wbtc_yang: Wad = before_wbtc_yang
            + wadray::fixed_point_to_wad(WBTC_DEPOSIT_AMT, test_utils::WBTC_DECIMALS);
        assert(
            shrine.get_deposit(wbtc_addr, trove_id) == expected_wbtc_yang, 'wrong WBTC yang amount'
        );

        // Depositing 0 should pass
        abbot.deposit(eth_addr, trove_id, 0_u128);
        abbot.deposit(wbtc_addr, trove_id, 0_u128);
        assert(
            shrine.get_deposit(eth_addr, trove_id) == expected_eth_yang, 'wrong ETH yang amount'
        );
        assert(
            shrine.get_deposit(wbtc_addr, trove_id) == expected_wbtc_yang, 'wrong WBTC yang amount'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Yang address cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_zero_address_yang_fail() {
        let (_, _, abbot, _, _) = abbot_deploy();

        let invalid_yang_addr = ContractAddressZeroable::zero();
        let trove_id: u64 = ShrineUtils::TROVE_1;
        let amount: u128 = 1;

        abbot.deposit(invalid_yang_addr, trove_id, amount);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Trove ID cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_zero_trove_id_fail() {
        let (_, _, abbot, _, _) = abbot_deploy();

        let yang_addr = ShrineUtils::yang1_addr();
        let invalid_trove_id: u64 = 0;
        let amount: u128 = 1;

        abbot.deposit(yang_addr, invalid_trove_id, amount);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(
        expected: ('SE: Yang is not approved', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED')
    )]
    fn test_deposit_invalid_yang_fail() {
        let (_, _, abbot, yangs, gates) = abbot_deploy();
        let trove_owner: ContractAddress = ShrineUtils::trove1_owner_addr();

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        fund_user(trove_owner, yangs, initial_asset_amts());
        let trove_id: u64 = open_trove_helper(abbot, trove_owner, yangs, open_trove_yang_asset_amts(), gates, forge_amt);

        let invalid_yang_addr = contract_address_const::<0x0101>();
        abbot.deposit(invalid_yang_addr, trove_id, 0_u128);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Non-existent trove', 'ENTRYPOINT_FAILED'))]
    fn test_deposit_non_existent_trove_fail() {
        let (_, _, abbot, yangs, gates) = abbot_deploy();
        let trove_owner: ContractAddress = ShrineUtils::trove1_owner_addr();

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        fund_user(trove_owner, yangs, initial_asset_amts());
        let trove_id: u64 = open_trove_helper(abbot, trove_owner, yangs, open_trove_yang_asset_amts(), gates, forge_amt);

        let eth_addr: ContractAddress = *yangs.at(0);
        abbot.deposit(eth_addr, trove_id + 1, 1_u128);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(
        expected: ('SE: Exceeds max amount allowed', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED')
    )]
    fn test_deposit_exceeds_asset_cap_fail() {
        let (shrine, sentinel, abbot, yangs, gates) = abbot_deploy();
        let trove_owner: ContractAddress = ShrineUtils::trove1_owner_addr();

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        fund_user(trove_owner, yangs, initial_asset_amts());
        let trove_id: u64 = open_trove_helper(abbot, trove_owner, yangs, open_trove_yang_asset_amts(), gates, forge_amt);

        let eth_addr: ContractAddress = *yangs.at(0);
        let eth_gate: IGateDispatcher = *gates.at(0);
        let eth_gate_bal = IERC20Dispatcher {
            contract_address: eth_addr
        }.balance_of(eth_gate.contract_address);

        set_contract_address(SentinelUtils::admin());
        let new_eth_asset_max: u128 = eth_gate_bal.try_into().unwrap() - 1;
        sentinel.set_yang_asset_max(eth_addr, new_eth_asset_max);

        abbot.deposit(eth_addr, trove_id, 1_u128);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_withdraw_pass() {
        let (shrine, _, abbot, yangs, gates) = abbot_deploy();
        let trove_owner: ContractAddress = ShrineUtils::trove1_owner_addr();

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        fund_user(trove_owner, yangs, initial_asset_amts());
        let trove_id: u64 = open_trove_helper(abbot, trove_owner, yangs, open_trove_yang_asset_amts(), gates, forge_amt);

        let eth_addr: ContractAddress = *yangs.at(0);
        let eth_withdraw_amt: Wad = WAD_SCALE.into();
        set_contract_address(trove_owner);
        abbot.withdraw(eth_addr, trove_id, eth_withdraw_amt);

        assert(
            shrine.get_deposit(eth_addr, trove_id) == ETH_DEPOSIT_AMT.into() - eth_withdraw_amt,
            'wrong yang amount'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Yang address cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_withdraw_zero_address_yang_fail() {
        let (_, _, abbot, _, _) = abbot_deploy();

        let invalid_yang_addr = ContractAddressZeroable::zero();
        let trove_id: u64 = ShrineUtils::TROVE_1;
        let amount: u128 = 1;

        abbot.deposit(invalid_yang_addr, trove_id, amount);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(
        expected: ('SE: Yang is not approved', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED')
    )]
    fn test_withdraw_invalid_yang_fail() {
        let (shrine, _, abbot, yangs, gates) = abbot_deploy();
        let trove_owner: ContractAddress = ShrineUtils::trove1_owner_addr();

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        fund_user(trove_owner, yangs, initial_asset_amts());
        let trove_id: u64 = open_trove_helper(abbot, trove_owner, yangs, open_trove_yang_asset_amts(), gates, forge_amt);

        let invalid_yang_addr = contract_address_const::<0x0101>();
        set_contract_address(trove_owner);
        abbot.withdraw(invalid_yang_addr, trove_id, 0_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Not trove owner', 'ENTRYPOINT_FAILED'))]
    fn test_withdraw_non_owner_fail() {
        let (shrine, _, abbot, yangs, gates) = abbot_deploy();
        let trove_owner: ContractAddress = ShrineUtils::trove1_owner_addr();

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        fund_user(trove_owner, yangs, initial_asset_amts());
        let trove_id: u64 = open_trove_helper(abbot, trove_owner, yangs, open_trove_yang_asset_amts(), gates, forge_amt);

        let eth_addr: ContractAddress = *yangs.at(0);
        set_contract_address(ShrineUtils::badguy());
        abbot.withdraw(eth_addr, trove_id, 0_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_forge_pass() {
        let (shrine, _, abbot, yangs, gates) = abbot_deploy();
        let trove_owner: ContractAddress = ShrineUtils::trove1_owner_addr();

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        fund_user(trove_owner, yangs, initial_asset_amts());
        let trove_id: u64 = open_trove_helper(abbot, trove_owner, yangs, open_trove_yang_asset_amts(), gates, forge_amt);

        let (_, _, _, before_trove_debt) = shrine.get_trove_info(trove_id);
        let before_yin: Wad = shrine.get_yin(trove_owner);

        let additional_forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        set_contract_address(trove_owner);
        abbot.forge(trove_id, additional_forge_amt, WadZeroable::zero());

        let (_, _, _, after_trove_debt) = shrine.get_trove_info(trove_id);
        assert(after_trove_debt == before_trove_debt + additional_forge_amt, 'wrong trove debt');
        assert(
            shrine.get_yin(trove_owner) == before_yin + additional_forge_amt, 'wrong yin balance'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(
        expected: ('SH: Trove LTV is too high', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED')
    )]
    fn test_forge_ltv_unsafe_fail() {
        let (shrine, _, abbot, yangs, gates) = abbot_deploy();
        let trove_owner: ContractAddress = ShrineUtils::trove1_owner_addr();

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        fund_user(trove_owner, yangs, initial_asset_amts());
        let trove_id: u64 = open_trove_helper(abbot, trove_owner, yangs, open_trove_yang_asset_amts(), gates, forge_amt);

        let unsafe_forge_amt: Wad = shrine.get_max_forge(trove_id) + 2_u128.into();
        set_contract_address(trove_owner);
        abbot.forge(trove_id, unsafe_forge_amt, WadZeroable::zero());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABB: Not trove owner', 'ENTRYPOINT_FAILED'))]
    fn test_forge_non_owner_fail() {
        let (shrine, _, abbot, yangs, gates) = abbot_deploy();
        let trove_owner: ContractAddress = ShrineUtils::trove1_owner_addr();

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        fund_user(trove_owner, yangs, initial_asset_amts());
        let trove_id: u64 = open_trove_helper(abbot, trove_owner, yangs, open_trove_yang_asset_amts(), gates, forge_amt);

        set_contract_address(ShrineUtils::badguy());
        abbot.forge(trove_id, 0_u128.into(), WadZeroable::zero());
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_melt_pass() {
        let (shrine, _, abbot, yangs, gates) = abbot_deploy();
        let trove_owner: ContractAddress = ShrineUtils::trove1_owner_addr();

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        fund_user(trove_owner, yangs, initial_asset_amts());
        let trove_id: u64 = open_trove_helper(abbot, trove_owner, yangs, open_trove_yang_asset_amts(), gates, forge_amt);

        let (_, _, _, before_trove_debt) = shrine.get_trove_info(trove_id);
        let before_yin: Wad = shrine.get_yin(trove_owner);

        let melt_amt: Wad = (before_yin.val / 2).into();
        set_contract_address(trove_owner);
        abbot.melt(trove_id, melt_amt);

        let (_, _, _, after_trove_debt) = shrine.get_trove_info(trove_id);
        assert(after_trove_debt == before_trove_debt - melt_amt, 'wrong trove debt');
        assert(shrine.get_yin(trove_owner) == before_yin - melt_amt, 'wrong yin balance');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_get_user_trove_ids() {
        let (shrine, _, abbot, yangs, gates) = abbot_deploy();
        let trove_owner: ContractAddress = ShrineUtils::trove1_owner_addr();

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        fund_user(trove_owner, yangs, initial_asset_amts());
        let first_trove_id: u64 = open_trove_helper(abbot, trove_owner, yangs, open_trove_yang_asset_amts(), gates, forge_amt);
        let second_trove_id: u64 = open_trove_helper(abbot, trove_owner, yangs, open_trove_yang_asset_amts(), gates, forge_amt);

        let mut expected_user_trove_ids: Array<u64> = Default::default();
        let empty_user_trove_ids: Span<u64> = expected_user_trove_ids.span();
        expected_user_trove_ids.append(first_trove_id);
        expected_user_trove_ids.append(second_trove_id);

        assert(
            abbot.get_user_trove_ids(trove_owner) == expected_user_trove_ids.span(),
            'wrong user trove IDs'
        );
        assert(abbot.get_troves_count() == 2, 'wrong troves count');

        let non_user: ContractAddress = contract_address_const::<0x0b0b>();
        assert(
            abbot.get_user_trove_ids(non_user) == empty_user_trove_ids, 'wrong non user trove IDs'
        );
    }
}
