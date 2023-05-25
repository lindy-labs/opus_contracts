#[cfg(test)]
mod TestShrine {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use traits::{Default, Into};
    use starknet::{ContractAddress, contract_address_const};
    use starknet::testing::set_contract_address;

    use aura::core::shrine::Shrine;
    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::serde;
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{
        Ray, RayZeroable, RAY_ONE, RAY_SCALE, Wad, WadZeroable, WAD_DECIMALS, WAD_SCALE
    };

    use aura::tests::shrine::shrine_utils::ShrineUtils;

    //
    // Tests - Access control
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_auth() {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();
        let shrine = ShrineUtils::shrine(shrine_addr);
        let shrine_accesscontrol: IAccessControlDispatcher = IAccessControlDispatcher {
            contract_address: shrine_addr
        };

        let admin: ContractAddress = ShrineUtils::admin();
        let new_admin: ContractAddress = contract_address_const::<0xdada>();

        assert(shrine_accesscontrol.get_admin() == admin, 'wrong admin');

        // Authorizing an address and testing that it can use authorized functions
        set_contract_address(admin);
        shrine_accesscontrol.grant_role(ShrineRoles::SET_DEBT_CEILING, new_admin);
        assert(shrine_accesscontrol.has_role(ShrineRoles::SET_DEBT_CEILING, new_admin), 'role not granted');
        assert(shrine_accesscontrol.get_roles(new_admin) == ShrineRoles::SET_DEBT_CEILING, 'role not granted');

        set_contract_address(new_admin);
        let new_ceiling: Wad = (WAD_SCALE + 1).into();
        shrine.set_debt_ceiling(new_ceiling);
        assert(shrine.get_debt_ceiling() == new_ceiling, 'wrong debt ceiling');

        // Revoking an address
        set_contract_address(admin);
        shrine_accesscontrol.revoke_role(ShrineRoles::SET_DEBT_CEILING, new_admin);
        assert(!shrine_accesscontrol.has_role(ShrineRoles::SET_DEBT_CEILING, new_admin), 'role not revoked');
        assert(shrine_accesscontrol.get_roles(new_admin) == 0, 'role not revoked');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_revoke_role() {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();
        let shrine = ShrineUtils::shrine(shrine_addr);
        let shrine_accesscontrol: IAccessControlDispatcher = IAccessControlDispatcher {
            contract_address: shrine_addr
        };

        let admin: ContractAddress = ShrineUtils::admin();
        let new_admin: ContractAddress = contract_address_const::<0xdada>();

        set_contract_address(admin);
        shrine_accesscontrol.grant_role(ShrineRoles::SET_DEBT_CEILING, new_admin);
        shrine_accesscontrol.revoke_role(ShrineRoles::SET_DEBT_CEILING, new_admin);
        
        set_contract_address(new_admin);
        let new_ceiling: Wad = (WAD_SCALE + 1).into();
        shrine.set_debt_ceiling(new_ceiling);
    }

    //
    // Tests - Price and multiplier updates
    // Note that core functionality is already tested in `test_shrine_setup_with_feed`
    //

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_advance_unauthorized() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::badguy());
        shrine.advance(ShrineUtils::yang1_addr(), ShrineUtils::YANG1_START_PRICE.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang does not exist', 'ENTRYPOINT_FAILED'))]
    fn test_advance_invalid_yang() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        shrine.advance(ShrineUtils::invalid_yang_addr(), ShrineUtils::YANG1_START_PRICE.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_multiplier_unauthorized() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::badguy());
        shrine.set_multiplier(RAY_SCALE.into());
    }

    //
    // Tests - Inject/eject
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_inject_and_eject() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        let yin = ShrineUtils::yin(shrine.contract_address);
        let trove1_owner = ShrineUtils::trove1_owner_addr();

        let before_total_supply: u256 = yin.total_supply();
        let before_user_bal: u256 = yin.balance_of(trove1_owner);
        let before_total_yin: Wad = shrine.get_total_yin();
        let before_user_yin: Wad = shrine.get_yin(trove1_owner);

        set_contract_address(ShrineUtils::admin());

        let inject_amt = ShrineUtils::TROVE1_FORGE_AMT.into();
        shrine.inject(trove1_owner, inject_amt);

        // TODO: replace with WadIntoU256 from Absorber PR
        assert(
            yin.total_supply() == before_total_supply + inject_amt.val.into(),
            'incorrect total supply'
        );
        assert(
            yin.balance_of(trove1_owner) == before_user_bal + inject_amt.val.into(),
            'incorrect user balance'
        );
        assert(shrine.get_total_yin() == before_total_yin + inject_amt, 'incorrect total yin');
        assert(shrine.get_yin(trove1_owner) == before_user_yin + inject_amt, 'incorrect user yin');

        shrine.eject(trove1_owner, inject_amt);
        assert(yin.total_supply() == before_total_supply, 'incorrect total supply');
        assert(yin.balance_of(trove1_owner) == before_user_bal, 'incorrect user balance');
        assert(shrine.get_total_yin() == before_total_yin, 'incorrect total yin');
        assert(shrine.get_yin(trove1_owner) == before_user_yin, 'incorrect user yin');
    }


    //
    // Tests - Price and multiplier
    //

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Price cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_advance_zero_value_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        shrine.advance(ShrineUtils::yang1_addr(), WadZeroable::zero());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Multiplier cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_set_multiplier_zero_value_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        shrine.set_multiplier(RayZeroable::zero());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Multiplier exceeds maximum', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_set_multiplier_exceeds_max_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        shrine.set_multiplier((RAY_SCALE * 3 + 1).into());
    }

    //
    // Tests - Getters for trove information
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_trove_unhealthy() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        let deposit_amt: Wad = ShrineUtils::TROVE1_YANG1_DEPOSIT.into();
        ShrineUtils::trove1_deposit(shrine, deposit_amt);
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);

        let (_, _, _, debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);

        let unsafe_price: Wad = wadray::rdiv_wr(debt, ShrineUtils::YANG1_THRESHOLD.into())
            / deposit_amt;

        set_contract_address(ShrineUtils::admin());
        shrine.advance(ShrineUtils::yang1_addr(), unsafe_price);

        assert(shrine.is_healthy(ShrineUtils::TROVE_1), 'should be unhealthy');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_get_trove_info() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        let mut yangs: Array<ContractAddress> = Default::default();
        let yang1_addr: ContractAddress = ShrineUtils::yang1_addr();
        let yang2_addr: ContractAddress = ShrineUtils::yang2_addr();

        yangs.append(yang1_addr);
        yangs.append(yang2_addr);

        let mut yang_amts: Array<Wad> = Default::default();
        yang_amts.append(ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        yang_amts.append(ShrineUtils::TROVE1_YANG2_DEPOSIT.into());

        // Manually set the prices
        let mut yang_prices: Array<Wad> = Default::default();
        let yang1_price: Wad = 2500000000000000000000_u128.into(); // 2_500 (Wad)
        let yang2_price: Wad = 625000000000000000000_u128.into(); // 625 (Wad)
        yang_prices.append(yang1_price);
        yang_prices.append(yang2_price);

        let mut yang_amts_copy: Span<Wad> = yang_amts.span();
        let mut yangs_copy: Span<ContractAddress> = yangs.span();
        let mut yang_prices_copy: Span<Wad> = yang_prices.span();

        set_contract_address(ShrineUtils::admin());
        loop {
            match yang_amts_copy.pop_front() {
                Option::Some(yang_amt) => {
                    let yang: ContractAddress = *yangs_copy.pop_front().unwrap();
                    shrine.deposit(yang, ShrineUtils::TROVE_1, *yang_amt);

                    shrine.advance(yang, *yang_prices_copy.pop_front().unwrap());
                },
                Option::None(_) => {
                    break ();
                }
            };
        };
        let mut yang_thresholds: Array<Ray> = Default::default();
        yang_thresholds.append(ShrineUtils::YANG1_THRESHOLD.into());
        yang_thresholds.append(ShrineUtils::YANG2_THRESHOLD.into());

        let (expected_threshold, expected_value) = ShrineUtils::calculate_trove_threshold_and_value(
            yang_prices.span(), yang_amts.span(), yang_thresholds.span()
        );
        let (threshold, _, value, _) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        assert(threshold == expected_threshold, 'wrong threshold');

        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);
        let (_, ltv, _, _) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        let expected_ltv: Ray = wadray::rdiv_ww(forge_amt, expected_value);
        assert(ltv == expected_ltv, 'wrong LTV');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_zero_value_trove() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        let (threshold, ltv, value, debt) = shrine.get_trove_info(ShrineUtils::TROVE_3);
        assert(threshold == RayZeroable::zero(), 'threshold should be 0');
        assert(ltv == RayZeroable::zero(), 'LTV should be 0');
        assert(value == WadZeroable::zero(), 'value should be 0');
        assert(debt == WadZeroable::zero(), 'debt should be 0');
    }

    //
    // Tests - Getters for shrine threshold and value
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_get_shrine_info() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        let mut yangs: Array<ContractAddress> = Default::default();
        let yang1_addr: ContractAddress = ShrineUtils::yang1_addr();
        let yang2_addr: ContractAddress = ShrineUtils::yang2_addr();

        yangs.append(yang1_addr);
        yangs.append(yang2_addr);

        let mut yang_amts: Array<Wad> = Default::default();
        yang_amts.append(ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        yang_amts.append(ShrineUtils::TROVE1_YANG2_DEPOSIT.into());

        // Manually set the prices
        let mut yang_prices: Array<Wad> = Default::default();
        let yang1_price: Wad = 2500000000000000000000_u128.into(); // 2_500 (Wad)
        let yang2_price: Wad = 625000000000000000000_u128.into(); // 625 (Wad)
        yang_prices.append(yang1_price);
        yang_prices.append(yang2_price);

        let mut yang_amts_copy: Span<Wad> = yang_amts.span();
        let mut yangs_copy: Span<ContractAddress> = yangs.span();
        let mut yang_prices_copy: Span<Wad> = yang_prices.span();

        // Deposit into troves 1 and 2, with trove 2 getting twice 
        // the amount of trove 1
        set_contract_address(ShrineUtils::admin());
        loop {
            match yang_amts_copy.pop_front() {
                Option::Some(yang_amt) => {
                    let yang: ContractAddress = *yangs_copy.pop_front().unwrap();
                    shrine.deposit(yang, ShrineUtils::TROVE_1, *yang_amt);
                    // Deposit twice the amount into trove 2
                    shrine.deposit(yang, ShrineUtils::TROVE_2, (*yang_amt.val * 2).into());

                    shrine.advance(yang, *yang_prices_copy.pop_front().unwrap());
                },
                Option::None(_) => {
                    break ();
                }
            };
        };

        // Update the amounts with the total amount deposited into troves 1 and 2
        let mut yang_amts: Array<Wad> = Default::default();
        yang_amts.append((ShrineUtils::TROVE1_YANG1_DEPOSIT * 3).into());
        yang_amts.append((ShrineUtils::TROVE1_YANG2_DEPOSIT * 3).into());

        let mut yang_thresholds: Array<Ray> = Default::default();
        yang_thresholds.append(ShrineUtils::YANG1_THRESHOLD.into());
        yang_thresholds.append(ShrineUtils::YANG2_THRESHOLD.into());

        let (expected_threshold, expected_value) = ShrineUtils::calculate_trove_threshold_and_value(
            yang_prices.span(), yang_amts.span(), yang_thresholds.span()
        );
        let (threshold, value) = shrine.get_shrine_threshold_and_value();
        assert(threshold == expected_threshold, 'wrong threshold');
        assert(value == expected_value, 'wrong value');
    }
}
