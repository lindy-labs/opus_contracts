#[cfg(test)]
mod TestPurger {
    use integer::BoundedU128;
    use starknet::ContractAddress;
    use starknet::testing::set_contract_address;
    use traits::Into;

    //use aura::core::roles::PurgerRoles;

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IPurger::{IPurgerDispatcher, IPurgerDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, Wad, WAD_ONE};

    use aura::tests::common;
    use aura::tests::purger::utils::PurgerUtils;
    use aura::tests::shrine::utils::ShrineUtils;

    use debug::PrintTrait;

    // 
    // Constants
    // 

    const HIGH_THRESHOLD: u128 = 950000000000000000000000000; // 95% (Ray)

    //
    // Tests - Setup
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_purger_setup() {
        let (shrine, abbot, absorber, purger, yangs, gates) = PurgerUtils::purger_deploy();

        // TODO: pending #335
        //let purger_ac = IAccessControlDispatcher { contract_address: purger.contract_address };
        //assert(
        //    purger_ac.get_roles(PurgerUtils::admin()) == PurgerRoles::default_admin_role(),
        //    'wrong role for admin'
        //);
    }

    //
    // Tests - Liquidate
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_liquidate_pass() {
        let (shrine, abbot, absorber, purger, yangs, gates) = PurgerUtils::purger_deploy_with_searcher();
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(abbot, yangs, gates);

        let target_trove_owner: ContractAddress = PurgerUtils::target_trove_owner();
        set_contract_address(target_trove_owner);

        let max_forge_amt: Wad = shrine.get_max_forge(target_trove);
        abbot.forge(target_trove, max_forge_amt, 0_u128.into());
        PurgerUtils::decrease_yang_prices_by_pct(
            shrine,
            yangs,
            200000000000000000000000000_u128.into() // 20% (Ray)
        );

        // Sanity check
        assert(!shrine.is_healthy(target_trove), 'should not be healthy');

        let (_, before_ltv, before_debt, before_value) = shrine.get_trove_info(target_trove);

        let penalty: Ray = purger.get_penalty(target_trove);
        let max_close_amt: Wad = purger.get_max_close_amount(target_trove);

        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);
        purger.liquidate(target_trove, BoundedU128::max().into(), searcher);

        // Check that LTV is close to safety margin

        // Check that searcher has received collateral
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not liquidatable', 'ENTRYPOINT_FAILED'))]
    fn test_liquidate_trove_healthy_fail() {
        let (shrine, abbot, absorber, purger, yangs, gates) = PurgerUtils::purger_deploy_with_searcher();
        let healthy_trove: u64 = PurgerUtils::funded_healthy_trove(abbot, yangs, gates);

        assert(shrine.is_healthy(healthy_trove), 'should be healthy');

        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);
        purger.liquidate(healthy_trove, BoundedU128::max().into(), searcher);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not liquidatable', 'ENTRYPOINT_FAILED'))]
    fn test_liquidate_trove_healthy_high_threshold_fail() {
        let (shrine, abbot, absorber, purger, yangs, gates) = PurgerUtils::purger_deploy_with_searcher();
        let healthy_trove: u64 = PurgerUtils::funded_healthy_trove(abbot, yangs, gates);

        PurgerUtils::set_thresholds(shrine, yangs, HIGH_THRESHOLD.into());
        let max_forge_amt: Wad = shrine.get_max_forge(healthy_trove);

        let healthy_trove_owner: ContractAddress = PurgerUtils::target_trove_owner();
        set_contract_address(healthy_trove_owner);
        abbot.forge(healthy_trove, max_forge_amt, 0_u128.into());

        assert(shrine.is_healthy(healthy_trove), 'should be healthy');

        let (threshold, ltv, _, _) = shrine.get_trove_info(healthy_trove);
        // Sanity check
        assert(ltv > 910000000000000000000000000_u128.into(), 'too low');

        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);
        purger.liquidate(healthy_trove, BoundedU128::max().into(), searcher);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_liquidate_insufficient_yin_fail() {
        let (shrine, abbot, absorber, purger, yangs, gates) = PurgerUtils::purger_deploy_with_searcher();
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(abbot, yangs, gates);

        let (_, ltv, _, _) = shrine.get_trove_info(target_trove);
        // Modify the thresholds to below the trove's LTV
        PurgerUtils::set_thresholds(shrine, yangs, (ltv.val - 1).into());

        assert(!shrine.is_healthy(target_trove), 'should not be healthy');
        let max_close_amt: Wad = purger.get_max_close_amount(target_trove);

        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);
        let yin = IERC20Dispatcher { contract_address: shrine.contract_address };
        let searcher_yin_bal: Wad = shrine.get_yin(searcher);
        // Transfer yin from the searcher so that its balance falls just below
        // the maximum close amount
        yin.transfer(PurgerUtils::target_trove_owner(), (searcher_yin_bal - (max_close_amt + WAD_ONE.into())).into());

        purger.liquidate(target_trove, BoundedU128::max().into(), searcher);
    }

    //
    // Tests - Absorb
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_full_absorb_pass() {

    }

    #[test]
    #[available_gas(20000000000)]
    fn test_partial_absorb_with_redistribution_pass() {

    }

    #[test]
    #[available_gas(20000000000)]
    fn test_absorb_full_redistribution_pass() {

    }

    #[test]
    #[available_gas(20000000000)]
    fn test_absorb_ltv_too_low_fail() {

    }
}
