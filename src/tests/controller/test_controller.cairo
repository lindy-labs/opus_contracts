mod TestController {
    use debug::PrintTrait;
    use starknet::testing::set_contract_address;
    use traits::Into;

    use aura::interfaces::IController::{IControllerDispatcher, IControllerDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::wadray_signed;
    use aura::utils::wadray_signed::{SignedRay, SignedRayZeroable};
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, Wad};

    use aura::tests::common;
    use aura::tests::controller::utils::ControllerUtils;
    use aura::tests::shrine::utils::ShrineUtils;

    const YIN_PRICE1: u128 = 999942800000000000; // wad 
    const YIN_PRICE2: u128 = 999879000000000000; // wad

    const ERROR_MARGIN: u128 = 1000000000000_u128; // 10^-15 (ray)

    #[test]
    #[available_gas(20000000000)]
    fn test_deploy_controller() {
        let (controller, shrine) = ControllerUtils::deploy_controller();

        assert(controller.get_p_gain() == ControllerUtils::P_GAIN.into(), 'wrong p gain');
        assert(controller.get_i_gain() == ControllerUtils::I_GAIN.into(), 'wrong i gain');
        assert(controller.get_alpha_p() == ControllerUtils::ALPHA_P, 'wrong alpha_p');
        assert(controller.get_alpha_i() == ControllerUtils::ALPHA_I, 'wrong alpha_i');
        assert(controller.get_beta_p() == ControllerUtils::BETA_P, 'wrong beta_p');
        assert(controller.get_beta_i() == ControllerUtils::BETA_I, 'wrong beta_i');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_setters() {
        let (controller, shrine) = ControllerUtils::deploy_controller();
        
        set_contract_address(ControllerUtils::admin());

        controller.set_p_gain(1_u128.into());
        controller.set_i_gain(2_u128.into());
        controller.set_alpha_p(3);
        controller.set_alpha_i(4);
        controller.set_beta_p(5);
        controller.set_beta_i(6);

        assert(controller.get_p_gain() == 1_u128.into(), 'wrong p gain');
        assert(controller.get_i_gain() == 2_u128.into(), 'wrong i gain');
        assert(controller.get_alpha_p() == 3, 'wrong alpha_p');
        assert(controller.get_alpha_i() == 4, 'wrong alpha_i');
        assert(controller.get_beta_p() == 5, 'wrong beta_p');
        assert(controller.get_beta_i() == 6, 'wrong beta_i');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_against_ground_truth() {
        let (controller, shrine) = ControllerUtils::deploy_controller();

        set_contract_address(ControllerUtils::admin());

        // Updating `i_gain` to match the ground truth simulation
        controller.set_i_gain(100000000000000000000000_u128.into());

        controller.get_p_term().val.print();
        controller.get_i_term().val.print();
        assert(controller.get_p_term() == SignedRayZeroable::zero(), 'Wrong p term #1');
        assert(controller.get_i_term() == SignedRayZeroable::zero(), 'Wrong i term #2');

        ControllerUtils::fast_forward_1_hour();
        shrine.update_yin_spot_price(YIN_PRICE1.into());
        controller.update_multiplier();

        controller.get_p_term().val.print();
        controller.get_i_term().val.print();
        common::assert_equalish(controller.get_p_term(), 18715000000000000_u128.into(), ERROR_MARGIN.into(), 'Wrong p term #2');
        //common::assert_equalish(controller.get_i_term(), SignedRayZeroable::zero(), ERROR_MARGIN.into(), 'Wrong i term #2');
        
        ControllerUtils::fast_forward_1_hour();
        shrine.update_yin_spot_price(YIN_PRICE2.into());
        controller.update_multiplier();

        controller.get_p_term().val.print();
        controller.get_i_term().val.print();
        common::assert_equalish(controller.get_p_term(), 177156100000000000_u128.into(), ERROR_MARGIN.into(), 'Wrong p term #3');
        common::assert_equalish(controller.get_i_term(), 57200000000000000000000_u128.into(), ERROR_MARGIN.into(), 'Wrong i term #3');

    }
}
