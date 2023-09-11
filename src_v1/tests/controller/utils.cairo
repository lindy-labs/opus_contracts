mod ControllerUtils {
    use debug::PrintTrait;
    use array::ArrayTrait;
    use option::OptionTrait;
    use starknet::{
        ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_const,
        contract_address_to_felt252, contract_address_try_from_felt252, deploy_syscall,
        get_block_timestamp, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};
    use traits::{Default, Into};
    use zeroable::Zeroable;

    use aura::core::controller::Controller;
    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IController::{IControllerDispatcher, IControllerDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray_signed;
    use aura::utils::wadray_signed::SignedRay;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, Wad};

    use aura::tests::shrine::utils::ShrineUtils;

    // Controller update interval 
    const ONE_HOUR: u64 = 3600; // 1 hour

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

    #[inline(always)]
    fn bad_guy() -> ContractAddress {
        contract_address_try_from_felt252('bad guy').unwrap()
    }


    fn deploy_controller() -> (IControllerDispatcher, IShrineDispatcher) {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();
        ShrineUtils::make_root(shrine_addr, ShrineUtils::admin());

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(admin()));
        calldata.append(contract_address_to_felt252(shrine_addr));
        calldata.append(P_GAIN.into());
        //calldata.append(1); // for `sign=true
        calldata.append(I_GAIN.into());
        //calldata.append(1); // for `sign=true
        calldata.append(ALPHA_P.into());
        calldata.append(BETA_P.into());
        calldata.append(ALPHA_I.into());
        calldata.append(BETA_I.into());

        let controller_class_hash: ClassHash = class_hash_try_from_felt252(
            Controller::TEST_CLASS_HASH
        )
            .unwrap();
        let (controller_addr, _) = deploy_syscall(controller_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        let shrine_ac = IAccessControlDispatcher { contract_address: shrine_addr };
        set_contract_address(ShrineUtils::admin());
        shrine_ac.grant_role(ShrineRoles::SET_MULTIPLIER, controller_addr);
        shrine_ac.grant_role(ShrineRoles::UPDATE_YIN_SPOT_PRICE, admin());

        set_contract_address(ContractAddressZeroable::zero());

        (
            IControllerDispatcher {
                contract_address: controller_addr
                }, IShrineDispatcher {
                contract_address: shrine_addr
            }
        )
    }

    #[inline(always)]
    fn set_yin_spot_price(shrine: IShrineDispatcher, spot_price: Wad) {
        set_contract_address(ShrineUtils::admin());
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
