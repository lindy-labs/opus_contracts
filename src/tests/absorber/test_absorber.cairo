#[cfg(test)]
mod TestAbsorber {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::{
        contract_address_const, deploy_syscall, ClassHash, class_hash_try_from_felt252,
        ContractAddress, contract_address_to_felt252, SyscallResultTrait
    };
    use starknet::testing::set_contract_address;
    use traits::{Default, Into};

    use aura::core::absorber::Absorber;
    use aura::core::roles::AbsorberRoles;

    use aura::interfaces::IAbsorber::{IAbsorberDispatcher, IAbsorberDispatcherTrait, IBlesserDispatcher, IBlesserDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::types::Reward;
    use aura::utils::wadray;
    use aura::utils::wadray::{Wad, WadZeroable, Ray};

    use aura::tests::shrine::utils::ShrineUtils;

    //
    // Constants
    //

    const REMOVAL_LIMIT: u128 = 900000000000000000000000000; // 90% (Ray)

    //
    // Address constants
    //

    // TODO: delete once sentinel is up
    fn mock_sentinel() -> ContractAddress {
        contract_address_const::<0xeeee>()
    }


    //
    // Test setup helpers
    //

    fn absorber_deploy() -> (IShrineDispatcher, IAbsorberDispatcher) {
        // TODO: update to Shrine with real yangs
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        let sentinel: ContractAddress = mock_sentinel();

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(ShrineUtils::admin()));
        calldata.append(contract_address_to_felt252(shrine.contract_address));
        calldata.append(contract_address_to_felt252(sentinel));
        calldata.append(REMOVAL_LIMIT.into());

        let absorber_class_hash: ClassHash = class_hash_try_from_felt252(Absorber::TEST_CLASS_HASH)
            .unwrap();
        let (absorber_addr, _) = deploy_syscall(absorber_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        let absorber = IAbsorberDispatcher { contract_address: absorber_addr };
        (shrine, absorber)
    }

    // Helper function to deploy a blesser for a token, and mint tokens to the deployed blesser.
    fn blesser_for_asset(asset: IERC20Dispatcher, absorber: IAbsorberDispatcher) -> IBlesserDispatcher {
        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(ShrineUtils::admin()));
        calldata.append(contract_address_to_felt252(asset.contract_address));
        calldata.append(contract_address_to_felt252(absorber.contract_address));

        let mock_blesser_class_hash: ClassHash = class_hash_try_from_felt252(MockBlesser::TEST_CLASS_HASH)
            .unwrap();
        let (mock_blesser_addr, _) = deploy_syscall(mock_blesser_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        let mock_blesser = IBlesserDispatcher{ contract_address: mock_blesser_addr };


        mock_blesser
    }

    //
    // Tests - Setup
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_absorber_setup() {
        let (_, absorber) = absorber_deploy();

        assert(
            absorber.get_total_shares_for_current_epoch() == WadZeroable::zero(),
            'total shares should be 0'
        );
        assert(absorber.get_current_epoch() == 0, 'epoch should be 0');
        assert(absorber.get_absorptions_count() == 0, 'absorptions count should be 0');
        assert(absorber.get_rewards_count() == 0, 'rewards should be 0');
        assert(absorber.get_removal_limit() == REMOVAL_LIMIT.into(), 'wrong limit');
        assert(absorber.get_live(), 'should be live');

        let absorber_ac = IAccessControlDispatcher { contract_address: absorber.contract_address };
        assert(
            absorber_ac.get_roles(ShrineUtils::admin()) == AbsorberRoles::default_admin_role(),
            'wrong role for admin'
        );
    }

    //
    // Tests - Setters
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_set_removal_limit_pass() {
        let (_, absorber) = absorber_deploy();

        set_contract_address(ShrineUtils::admin());

        let new_limit: Ray = 750000000000000000000000000_u128.into();  // 75% (Ray)
        absorber.set_removal_limit(new_limit);

        assert(absorber.get_removal_limit() == new_limit, 'limit not updated');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Limit is too low', 'ENTRYPOINT_FAILED'))]
    fn test_set_removal_limit_too_low_fail() {
        let (_, absorber) = absorber_deploy();

        set_contract_address(ShrineUtils::admin());

        let invalid_limit: Ray = (Absorber::MIN_LIMIT - 1).into(); 
        absorber.set_removal_limit(invalid_limit);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_removal_limit_unauthorized_fail() {
        let (_, absorber) = absorber_deploy();

        set_contract_address(ShrineUtils::badguy());

        let new_limit: Ray = 750000000000000000000000000_u128.into();  // 75% (Ray)
        absorber.set_removal_limit(new_limit);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_reward_pass() {
        let (_, absorber) = absorber_deploy();

        set_contract_address(ShrineUtils::badguy());

        //let new_limit: Ray = 750000000000000000000000000_u128.into();  // 75% (Ray)
        //absorber.set_removal_limit(new_limit);
    }  
}
