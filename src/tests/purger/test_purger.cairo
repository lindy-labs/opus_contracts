#[cfg(test)]
mod TestPurger {
    use integer::BoundedU128;
    use starknet::ContractAddress;
    use starknet::testing::set_contract_address;
    use traits::Into;

    //use aura::core::roles::PurgerRoles;

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IPurger::{IPurgerDispatcher, IPurgerDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::Wad;

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

        let healthy_trove_owner: ContractAddress = common::trove1_owner_addr();
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
    fn test_liquidate_insufficient_yin_fail() {

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
