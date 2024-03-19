pub mod controller_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::debug::PrintTrait;
    use core::num::traits::Zero;
    use opus::core::roles::shrine_roles;
    use opus::interfaces::IController::{IControllerDispatcher, IControllerDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{declare, ContractClassTrait, start_prank, stop_prank, start_warp, CheatTarget};
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::{Ray, SignedRay, Wad};

    // Controller update interval
    const ONE_HOUR: u64 = consteval_int!(60 * 60); // 1 hour

    // Default controller parameters
    const P_GAIN: u128 = 100000000000000000000000000000; // 100 * RAY_ONE
    const I_GAIN: u128 = 0;
    const ALPHA_P: u8 = 3;
    const BETA_P: u8 = 8;
    const ALPHA_I: u8 = 1;
    const BETA_I: u8 = 2;

    // Addresses

    #[inline(always)]
    pub fn admin() -> ContractAddress {
        'controller admin'.try_into().unwrap()
    }

    pub fn deploy_controller() -> (IControllerDispatcher, IShrineDispatcher) {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        shrine_utils::make_root(shrine_addr, shrine_utils::admin());

        let calldata: Array<felt252> = array![
            admin().into(),
            shrine_addr.into(),
            P_GAIN.into(),
            I_GAIN.into(),
            ALPHA_P.into(),
            BETA_P.into(),
            ALPHA_I.into(),
            BETA_I.into()
        ];

        let controller_class = declare("controller");
        let controller_addr = controller_class.deploy(@calldata).expect('controller deploy failed');

        let shrine_ac = IAccessControlDispatcher { contract_address: shrine_addr };
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine_ac.grant_role(shrine_roles::controller(), controller_addr);

        start_prank(CheatTarget::All, Zero::zero());

        (
            IControllerDispatcher { contract_address: controller_addr },
            IShrineDispatcher { contract_address: shrine_addr }
        )
    }

    #[inline(always)]
    pub fn set_yin_spot_price(shrine: IShrineDispatcher, spot_price: Wad) {
        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        shrine.update_yin_spot_price(spot_price);
        stop_prank(CheatTarget::One(shrine.contract_address));
    }

    #[inline(always)]
    pub fn fast_forward_1_hour() {
        start_warp(CheatTarget::All, get_block_timestamp() + ONE_HOUR);
    }

    #[inline(always)]
    pub fn fast_forward_by_x_minutes(x: u64) {
        start_warp(CheatTarget::All, get_block_timestamp() + x * 60);
    }
}
