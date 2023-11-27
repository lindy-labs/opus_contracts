mod test_transmuter_registry {
    use opus::core::roles::transmuter_registry_roles;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::ITransmuter::{
        ITransmuterDispatcher, ITransmuterDispatcherTrait, ITransmuterRegistryDispatcher,
        ITransmuterRegistryDispatcherTrait
    };
    use opus::tests::shrine::utils::shrine_utils;
    use opus::tests::transmuter::utils::transmuter_utils;
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use starknet::ContractAddress;
    use starknet::testing::set_contract_address;

    //
    // Tests - Deployment 
    //

    // Check constructor function
    #[test]
    #[available_gas(20000000000)]
    fn test_transmuter_registry_deploy() {
        let registry = transmuter_utils::transmuter_registry_deploy();

        assert(registry.get_transmuters_count().is_zero(), 'should be zero');
        assert(registry.get_transmuters() == array![].span(), 'should be empty');

        let registry_ac: IAccessControlDispatcher = IAccessControlDispatcher {
            contract_address: registry.contract_address
        };
        let admin: ContractAddress = shrine_utils::admin();
        assert(registry_ac.get_admin() == admin, 'wrong admin');
        assert(
            registry_ac.get_roles(admin) == transmuter_registry_roles::default_admin_role(),
            'wrong admin roles'
        );
    }

    //
    // Tests - Add and remove transmuters
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_add_and_remove_transmuters() {
        let registry = transmuter_utils::transmuter_registry_deploy();

        let (shrine, first_transmuter, _) =
            transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();
        let mock_nonwad_usd_stable = transmuter_utils::mock_nonwad_usd_stable_deploy();
        let second_transmuter = transmuter_utils::transmuter_deploy(
            shrine.contract_address,
            mock_nonwad_usd_stable.contract_address,
            transmuter_utils::receiver(),
            Option::None
        );

        set_contract_address(shrine_utils::admin());
        registry.add_transmuter(first_transmuter.contract_address);

        assert(registry.get_transmuters_count() == 1, 'wrong transmuters count #1');
        assert(
            registry.get_transmuters() == array![first_transmuter.contract_address].span(),
            'wrong transmuters #1'
        );

        registry.add_transmuter(second_transmuter.contract_address);

        assert(registry.get_transmuters_count() == 2, 'wrong transmuters count #2');
        assert(
            registry
                .get_transmuters() == array![
                    first_transmuter.contract_address, second_transmuter.contract_address
                ]
                .span(),
            'wrong transmuters #2'
        );

        registry.remove_transmuter(first_transmuter.contract_address);

        assert(registry.get_transmuters_count() == 1, 'wrong transmuters count #3');
        assert(
            registry.get_transmuters() == array![second_transmuter.contract_address].span(),
            'wrong transmuters #3'
        );

        registry.add_transmuter(first_transmuter.contract_address);

        assert(registry.get_transmuters_count() == 2, 'wrong transmuters count #4');
        assert(
            registry
                .get_transmuters() == array![
                    second_transmuter.contract_address, first_transmuter.contract_address
                ]
                .span(),
            'wrong transmuters #4'
        );

        registry.remove_transmuter(first_transmuter.contract_address);

        assert(registry.get_transmuters_count() == 1, 'wrong transmuters count #5');
        assert(
            registry.get_transmuters() == array![second_transmuter.contract_address].span(),
            'wrong transmuters #5'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('TRR: Transmuter already exists', 'ENTRYPOINT_FAILED'))]
    fn test_add_duplicate_transmuter_fail() {
        let registry = transmuter_utils::transmuter_registry_deploy();

        let (_, first_transmuter, _) =
            transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();

        set_contract_address(shrine_utils::admin());
        registry.add_transmuter(first_transmuter.contract_address);
        assert(registry.get_transmuters_count() == 1, 'sanity check');

        registry.add_transmuter(first_transmuter.contract_address);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('TRR: Transmuter does not exist', 'ENTRYPOINT_FAILED'))]
    fn test_remove_nonexistent_transmuter_fail() {
        let registry = transmuter_utils::transmuter_registry_deploy();

        let (_, first_transmuter, _) =
            transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();

        set_contract_address(shrine_utils::admin());
        registry.remove_transmuter(first_transmuter.contract_address);
    }
}
