#[cfg(test)]
mod TestPurger {
    //use aura::core::roles::PurgerRoles;

    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};

    use aura::tests::purger::utils::PurgerUtils;

    //
    // Tests - Setup
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_purger_setup() {
        let (shrine, absorber, purger, yangs, gates) = PurgerUtils::purger_deploy();

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
    fn test_liquidate_trove_healthy_fail() {

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
