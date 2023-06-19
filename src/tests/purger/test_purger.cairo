#[cfg(test)]
mod TestPurger {
    use integer::BoundedU128;
    use starknet::ContractAddress;
    use starknet::testing::set_contract_address;
    use traits::Into;

    use aura::core::purger::Purger;
    //use aura::core::roles::PurgerRoles;

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IPurger::{IPurgerDispatcher, IPurgerDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RAY_ONE, RAY_PERCENT, Wad, WAD_ONE};

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
        let (shrine, abbot, absorber, purger, yangs, gates) = PurgerUtils::purger_deploy_with_searcher(PurgerUtils::SEARCHER_YIN.into());
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into());

        let target_trove_owner: ContractAddress = PurgerUtils::target_trove_owner();
        set_contract_address(target_trove_owner);

        let max_forge_amt: Wad = shrine.get_max_forge(target_trove);
        abbot.forge(target_trove, max_forge_amt, 0_u128.into());
        PurgerUtils::decrease_yang_prices_by_pct(
            shrine,
            yangs,
            100000000000000000000000000_u128.into() // 10% (Ray)
        );

        // Sanity check
        assert(!shrine.is_healthy(target_trove), 'should not be healthy');

        let (threshold, before_ltv, before_value, before_debt) = shrine.get_trove_info(target_trove);
        // TODO: this currently underflows because it requires a signed operation
        let penalty: Ray = purger.get_penalty(target_trove);
        let max_close_amt: Wad = purger.get_max_close_amount(target_trove);
        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);
        purger.liquidate(target_trove, BoundedU128::max().into(), searcher);

        // Check that LTV is close to safety margin
        let (_, after_ltv, after_value, after_debt) = shrine.get_trove_info(target_trove);
        assert(after_debt == before_debt - max_close_amt, 'wrong debt after liquidation');
        // TODO:

        // Check that searcher has received collateral
        let expected_freed_pct = PurgerUtils::get_expected_freed_pct(before_value, max_close_amt, penalty);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not liquidatable', 'ENTRYPOINT_FAILED'))]
    fn test_liquidate_trove_healthy_fail() {
        let (shrine, abbot, absorber, purger, yangs, gates) = PurgerUtils::purger_deploy_with_searcher(PurgerUtils::SEARCHER_YIN.into());
        let healthy_trove: u64 = PurgerUtils::funded_healthy_trove(abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into());

        assert(shrine.is_healthy(healthy_trove), 'should be healthy');

        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);
        purger.liquidate(healthy_trove, BoundedU128::max().into(), searcher);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not liquidatable', 'ENTRYPOINT_FAILED'))]
    fn test_liquidate_trove_healthy_high_threshold_fail() {
        let (shrine, abbot, absorber, purger, yangs, gates) = PurgerUtils::purger_deploy_with_searcher(PurgerUtils::SEARCHER_YIN.into());
        let healthy_trove: u64 = PurgerUtils::funded_healthy_trove(abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into());

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
        let target_trove_yin: Wad = PurgerUtils::TARGET_TROVE_YIN.into();
        let searcher_yin: Wad = (target_trove_yin.val / 4).into();

        let (shrine, abbot, absorber, purger, yangs, gates) = PurgerUtils::purger_deploy_with_searcher(searcher_yin);
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(abbot, yangs, gates, target_trove_yin);

        let (_, ltv, _, _) = shrine.get_trove_info(target_trove);
        // Modify the thresholds to below the trove's LTV
        PurgerUtils::set_thresholds(shrine, yangs, (ltv.val - 1).into());

        assert(!shrine.is_healthy(target_trove), 'should not be healthy');

        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);

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
    #[should_panic(expected: ('PU: Not absorbable', 'ENTRYPOINT_FAILED'))]
    fn test_absorb_trove_healthy_fail() {
        let (shrine, abbot, absorber, purger, yangs, gates) = PurgerUtils::purger_deploy_with_searcher(PurgerUtils::SEARCHER_YIN.into());
        let healthy_trove: u64 = PurgerUtils::funded_healthy_trove(abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into());

        assert(shrine.is_healthy(healthy_trove), 'should be healthy');

        set_contract_address(PurgerUtils::random_user());
        purger.absorb(healthy_trove);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not absorbable', 'ENTRYPOINT_FAILED'))]
    fn test_absorb_below_absorbable_ltv_fail() {
        let (shrine, abbot, absorber, purger, yangs, gates) = PurgerUtils::purger_deploy_with_searcher(PurgerUtils::SEARCHER_YIN.into());
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into());

        assert(shrine.is_healthy(target_trove), 'should be healthy');

        let (threshold, ltv, value, debt) = shrine.get_trove_info(target_trove);
        let unhealthy_value: Wad = wadray::rmul_wr(debt, (RAY_ONE.into() / Purger::MAX_PENALTY_LTV.into()));
        let decrease_pct: Ray = wadray::rdiv_ww((value - unhealthy_value), value);
        PurgerUtils::decrease_yang_prices_by_pct(
            shrine,
            yangs,
            decrease_pct - RAY_PERCENT.into(), // Add 1% offset to guarantee LTV is below max penalty
        );

        let (_, new_ltv, _, _) = shrine.get_trove_info(target_trove);

        // sanity check
        assert(!shrine.is_healthy(target_trove), 'should not be healthy');
        assert(new_ltv > threshold & Purger::MAX_PENALTY_LTV.into() > new_ltv, 'LTV not in expected range');

        set_contract_address(PurgerUtils::random_user());
        purger.absorb(target_trove);
    }
}
