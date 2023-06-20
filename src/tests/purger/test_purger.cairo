#[cfg(test)]
mod TestPurger {
    use integer::BoundedU128;
    use starknet::ContractAddress;
    use starknet::testing::set_contract_address;
    use traits::Into;


    use aura::core::purger::Purger;
    use aura::core::roles::PurgerRoles;

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IPurger::{IPurgerDispatcher, IPurgerDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RayZeroable, RAY_ONE, RAY_PERCENT, Wad, WadZeroable, WAD_ONE};

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
        let purger_ac = IAccessControlDispatcher { contract_address: purger.contract_address };
        assert(
            purger_ac.get_roles(PurgerUtils::admin()) == PurgerRoles::default_admin_role(),
            'wrong role for admin'
        );
    }

    //
    // Tests - Liquidate
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_liquidate_pass() {
        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        let target_trove_owner: ContractAddress = PurgerUtils::target_trove_owner();
        set_contract_address(target_trove_owner);

        let (threshold, _, value, debt) = shrine.get_trove_info(target_trove);
        let target_ltv: Ray = (threshold.val + 1).into();
        PurgerUtils::adjust_prices_for_trove_ltv(shrine, yangs, value, debt, target_ltv); 

        // Sanity check
        assert(!shrine.is_healthy(target_trove), 'should not be healthy');

        let (_, before_ltv, before_value, before_debt) = shrine
            .get_trove_info(target_trove);
        // TODO: this currently underflows because it requires a signed operation
        let penalty: Ray = purger.get_liquidation_penalty(target_trove);
        let max_close_amt: Wad = purger.get_max_liquidation_amount(target_trove);
        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);
        purger.liquidate(target_trove, BoundedU128::max().into(), searcher);

        // Check that LTV is close to safety margin
        let (_, after_ltv, after_value, after_debt) = shrine.get_trove_info(target_trove);
        assert(after_debt == before_debt - max_close_amt, 'wrong debt after liquidation');
        // TODO:

        // Check that searcher has received collateral
        let expected_freed_pct = PurgerUtils::get_expected_freed_pct(
            before_value, max_close_amt, penalty
        );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not liquidatable', 'ENTRYPOINT_FAILED'))]
    fn test_liquidate_trove_healthy_fail() {
        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let healthy_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        PurgerUtils::assert_trove_is_healthy(shrine, purger, healthy_trove);

        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);
        purger.liquidate(healthy_trove, BoundedU128::max().into(), searcher);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not liquidatable', 'ENTRYPOINT_FAILED'))]
    fn test_liquidate_trove_healthy_high_threshold_fail() {
        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let healthy_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        PurgerUtils::set_thresholds(shrine, yangs, HIGH_THRESHOLD.into());
        let max_forge_amt: Wad = shrine.get_max_forge(healthy_trove);

        let healthy_trove_owner: ContractAddress = PurgerUtils::target_trove_owner();
        set_contract_address(healthy_trove_owner);
        abbot.forge(healthy_trove, max_forge_amt, 0_u128.into());

        let (threshold, ltv, _, _) = shrine.get_trove_info(healthy_trove);
        // Sanity check
        assert(ltv > Purger::ABSORPTION_THRESHOLD.into(), 'too low');

        PurgerUtils::assert_trove_is_healthy(shrine, purger, healthy_trove);

        let searcher: ContractAddress = PurgerUtils::searcher();
        set_contract_address(searcher);
        purger.liquidate(healthy_trove, BoundedU128::max().into(), searcher);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED'))]
    fn test_liquidate_insufficient_yin_fail() {
        let target_trove_yin: Wad = PurgerUtils::TARGET_TROVE_YIN.into();
        let searcher_yin: Wad = (target_trove_yin.val / 10).into();

        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            searcher_yin
        );
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, target_trove_yin
        );

        let (threshold, _, value, debt) = shrine.get_trove_info(target_trove);

        let target_ltv: Ray = (Purger::ABSORPTION_THRESHOLD + 1).into();
        PurgerUtils::adjust_prices_for_trove_ltv(shrine, yangs, value, debt, target_ltv); 

        PurgerUtils::assert_trove_is_liquidatable(shrine, purger, target_trove);

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
        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        let (threshold, ltv, value, debt) = shrine.get_trove_info(target_trove);

        let target_ltv: Ray = (Purger::ABSORPTION_THRESHOLD + 1).into();
        PurgerUtils::adjust_prices_for_trove_ltv(shrine, yangs, value, debt, target_ltv); 

        // Fund the absorber with twice the target trove's debt
        let absorber_yin: Wad = (debt.val * 2).into();
        PurgerUtils::funded_absorber(shrine, abbot, absorber, yangs, gates, absorber_yin);

        // sanity check
        assert(shrine.get_yin(absorber.contract_address) > debt, 'not full absorption');

        // TODO: 
        // (1) check that yangs are transferred to absorber
        // (2) trove's debt is reduced by close amount
        // (3) trove is healthy, and LTV is at safety margin (?)
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_partial_absorb_with_redistribution_pass() {
        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        let (threshold, ltv, value, debt) = shrine.get_trove_info(target_trove);

        let target_ltv: Ray = (Purger::ABSORPTION_THRESHOLD + 1).into();
        PurgerUtils::adjust_prices_for_trove_ltv(shrine, yangs, value, debt, target_ltv); 

        // Fund the absorber with half the target trove's debt
        let absorber_yin: Wad = (debt.val / 2).into();
        PurgerUtils::funded_absorber(shrine, abbot, absorber, yangs, gates, absorber_yin);

        // sanity check
        assert(shrine.get_yin(absorber.contract_address) < debt, 'not partial absorption');

        // TODO: 
        // (1) check that yangs are transferred to absorber
        // (2) trove's debt is reduced by close amount
        // (3) trove is healthy, and LTV is at safety margin (?)
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_absorb_full_redistribution_pass() {
        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        let (threshold, ltv, value, debt) = shrine.get_trove_info(target_trove);
        let target_ltv: Ray = (Purger::ABSORPTION_THRESHOLD + 1).into();
        PurgerUtils::adjust_prices_for_trove_ltv(shrine, yangs, value, debt, target_ltv); 

        set_contract_address(PurgerUtils::random_user());
        purger.absorb(target_trove);

        let (_, ltv, value, debt) = shrine.get_trove_info(target_trove);
        assert(shrine.is_healthy(target_trove), 'should be healthy');
        assert(ltv == RayZeroable::zero(), 'LTV should be 0');
        assert(value == WadZeroable::zero(), 'value should be 0');
        assert(debt == WadZeroable::zero(), 'debt should be 0');

        assert(shrine.get_redistributions_count() == 1, 'wrong redistributions count');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not absorbable', 'ENTRYPOINT_FAILED'))]
    fn test_absorb_trove_healthy_fail() {
        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let healthy_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        PurgerUtils::assert_trove_is_healthy(shrine, purger, healthy_trove);

        set_contract_address(PurgerUtils::random_user());
        purger.absorb(healthy_trove);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PU: Not absorbable', 'ENTRYPOINT_FAILED'))]
    fn test_absorb_below_absorbable_ltv_fail() {
        let (shrine, abbot, absorber, purger, yangs, gates) =
            PurgerUtils::purger_deploy_with_searcher(
            PurgerUtils::SEARCHER_YIN.into()
        );
        let target_trove: u64 = PurgerUtils::funded_healthy_trove(
            abbot, yangs, gates, PurgerUtils::TARGET_TROVE_YIN.into()
        );

        assert(shrine.is_healthy(target_trove), 'should be healthy');

        let (threshold, ltv, value, debt) = shrine.get_trove_info(target_trove);
        // Calculate the target trove value for the LTV to be above the threshold by 1%

        let target_ltv: Ray = threshold + RAY_PERCENT.into();
        PurgerUtils::adjust_prices_for_trove_ltv(shrine, yangs, value, debt, target_ltv); 

        let (_, new_ltv, value, _) = shrine.get_trove_info(target_trove);

        PurgerUtils::assert_trove_is_liquidatable(shrine, purger, target_trove);
        PurgerUtils::assert_trove_is_not_absorbable(shrine, purger, target_trove);
    
        set_contract_address(PurgerUtils::random_user());
        purger.absorb(target_trove);
    }
}
