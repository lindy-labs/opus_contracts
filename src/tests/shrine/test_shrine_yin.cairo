#[cfg(test)]
mod TestShrine {
    use array::{ArrayTrait, SpanTrait};
    use debug::PrintTrait;
    use integer::BoundedU256;
    use option::OptionTrait;
    use traits::{Into, TryInto};
    use starknet::{
        contract_address_const, deploy_syscall, ClassHash, class_hash_try_from_felt252,
        ContractAddress, contract_address_to_felt252, get_block_timestamp, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};

    use aura::core::shrine::Shrine;
    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::exp::exp;
    use aura::utils::serde;
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RayZeroable, RAY_ONE, RAY_SCALE, Wad, WadZeroable, WAD_DECIMALS, WAD_SCALE};

    use aura::tests::shrine::shrine_utils::ShrineUtils;

    //
    // Tests - Yin transfers
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_yin_transfer_pass() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        set_contract_address(trove1_owner);

        let success: bool = yin.transfer(yin_user, ShrineUtils::TROVE1_FORGE_AMT.into());

        // TODO: Moving this call up here prevents the assert from triggering failed calculating gas
        yin.transfer(yin_user, 0_u256);
        assert(success, 'yin transfer fail');

        assert(yin.balance_of(trove1_owner) == 0_u256, 'wrong transferor balance');

        // TODO: Adding this call prevents failed calculating gas error
        yin.transfer(yin_user, 0_u256);

        assert(yin.balance_of(yin_user) == ShrineUtils::TROVE1_FORGE_AMT.into(), 'wrong transferee balance');

        // TODO: Adding all these calls prevents failed calculating gas error
        yin.transfer(yin_user, 0_u256);
        yin.transfer(yin_user, 0_u256);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_yin_transfer_fail_insufficient() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        set_contract_address(trove1_owner);

        yin.transfer(yin_user, (ShrineUtils::TROVE1_FORGE_AMT + 1).into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_yin_transfer_fail_zero_bal() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        set_contract_address(trove1_owner);

        yin.transfer(yin_user, 1_u256);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_yin_transfer_from_pass() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        set_contract_address(trove1_owner);

        yin.approve(yin_user, ShrineUtils::TROVE1_FORGE_AMT.into());

        set_contract_address(yin_user);
        let success: bool = yin.transfer_from(trove1_owner, yin_user, ShrineUtils::TROVE1_FORGE_AMT.into());

        assert(success, 'yin transfer fail');

        assert(yin.balance_of(trove1_owner) == 0_u256, 'wrong transferor balance');
        assert(yin.balance_of(yin_user) == ShrineUtils::TROVE1_FORGE_AMT.into(), 'wrong transferee balance');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u256_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_yin_transfer_from_unapproved_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();
        set_contract_address(yin_user);
        yin.transfer_from(ShrineUtils::trove1_owner_addr(), yin_user, 1_u256);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u256_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_yin_transfer_from_insufficient_allowance_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        shrine.forge(trove1_owner, ShrineUtils::TROVE_1, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();

        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        set_contract_address(trove1_owner);
        let approve_amt: u256 = (ShrineUtils::TROVE1_FORGE_AMT / 2).into();
        yin.approve(yin_user, approve_amt);

        set_contract_address(yin_user);
        yin.transfer_from(trove1_owner, yin_user, approve_amt + 1_u256);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_yin_transfer_from_insufficient_balance_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        shrine.forge(trove1_owner, ShrineUtils::TROVE_1, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();

        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        set_contract_address(trove1_owner);
        yin.approve(yin_user, BoundedU256::max());

        set_contract_address(yin_user);
        yin.transfer_from(trove1_owner, yin_user, (ShrineUtils::TROVE1_FORGE_AMT + 1).into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: No transfer to 0 address', 'ENTRYPOINT_FAILED'))]
    fn test_yin_transfer_zero_address_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        shrine.forge(trove1_owner, ShrineUtils::TROVE_1, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();

        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        set_contract_address(trove1_owner);
        yin.approve(yin_user, BoundedU256::max());

        set_contract_address(yin_user);
        yin.transfer_from(trove1_owner, ContractAddressZeroable::zero(), 1_u256);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_yin_melt_after_transfer() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();

        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        set_contract_address(trove1_owner);

        let transfer_amt: Wad = (forge_amt.val / 2).into();
        yin.transfer(yin_user, transfer_amt.val.into());

        let melt_amt: Wad = forge_amt - transfer_amt;

        ShrineUtils::trove1_melt(shrine, melt_amt);

        let (_, _, _, debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        let expected_debt: Wad = forge_amt - melt_amt;
        assert(debt == expected_debt, 'wrong debt after melt');

        assert(shrine.get_yin(trove1_owner) == forge_amt - melt_amt - transfer_amt, 'wrong balance');
    }
}
