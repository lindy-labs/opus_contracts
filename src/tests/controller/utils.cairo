mod controller_utils {
    use debug::PrintTrait;
    use opus::core::controller::controller as controller_contract;
    use opus::core::roles::shrine_roles;
    use opus::interfaces::IController::{IControllerDispatcher, IControllerDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::shrine::utils::shrine_utils;
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::utils::wadray::{Ray, Wad};
    use opus::utils::wadray;
    use opus::utils::wadray_signed::SignedRay;
    use opus::utils::wadray_signed;
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};
    use starknet::{
        ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_to_felt252,
        contract_address_try_from_felt252, deploy_syscall, get_block_timestamp, SyscallResultTrait
    };

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
    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('controller admin').unwrap()
    }

    fn deploy_controller() -> (IControllerDispatcher, IShrineDispatcher) {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy();
        shrine_utils::make_root(shrine_addr, shrine_utils::admin());

        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(admin()),
            contract_address_to_felt252(shrine_addr),
            P_GAIN.into(),
            I_GAIN.into(),
            ALPHA_P.into(),
            BETA_P.into(),
            ALPHA_I.into(),
            BETA_I.into()
        ];

        let controller_class_hash: ClassHash = class_hash_try_from_felt252(
            controller_contract::TEST_CLASS_HASH
        )
            .unwrap();
        let (controller_addr, _) = deploy_syscall(controller_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        let shrine_ac = IAccessControlDispatcher { contract_address: shrine_addr };
        set_contract_address(shrine_utils::admin());
        shrine_ac.grant_role(shrine_roles::controller(), controller_addr);

        set_contract_address(ContractAddressZeroable::zero());

        (
            IControllerDispatcher { contract_address: controller_addr },
            IShrineDispatcher { contract_address: shrine_addr }
        )
    }

    #[inline(always)]
    fn set_yin_spot_price(shrine: IShrineDispatcher, spot_price: Wad) {
        set_contract_address(shrine_utils::admin());
        shrine.update_yin_spot_price(spot_price);
        set_contract_address(ContractAddressZeroable::zero());
    }

    #[inline(always)]
    fn fast_forward_1_hour() {
        set_block_timestamp(get_block_timestamp() + ONE_HOUR);
    }

    #[inline(always)]
    fn fast_forward_by_x_minutes(x: u64) {
        set_block_timestamp(get_block_timestamp() + x * 60);
    }
}
