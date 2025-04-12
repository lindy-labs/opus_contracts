mod test_transmuter_registry {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::core::roles::transmuter_registry_roles;
    use opus::interfaces::ITransmuter::ITransmuterRegistryDispatcherTrait;
    use opus::tests::common;
    use opus::tests::transmuter::utils::transmuter_utils;
    use snforge_std::{ContractClass, start_cheat_caller_address};
    use starknet::ContractAddress;

    //
    // Tests - Deployment
    //

    // Check constructor function
    #[test]
    fn test_transmuter_registry_deploy() {
        let registry = transmuter_utils::transmuter_registry_deploy();

        assert(registry.get_transmuters() == array![].span(), 'should be empty');

        let registry_ac: IAccessControlDispatcher = IAccessControlDispatcher {
            contract_address: registry.contract_address,
        };
        let admin: ContractAddress = transmuter_utils::admin();
        assert(registry_ac.get_admin() == admin, 'wrong admin');
        assert(registry_ac.get_roles(admin) == transmuter_registry_roles::default_admin_role(), 'wrong admin roles');
    }

    //
    // Tests - Add and remove transmuters
    //

    #[test]
    fn test_add_and_remove_transmuters() {
        let transmuter_class: ContractClass = transmuter_utils::declare_transmuter();
        let token_class = common::declare_token();

        let registry = transmuter_utils::transmuter_registry_deploy();

        let transmuter_utils::TransmuterTestConfig {
            shrine, transmuter, ..,
        } =
            transmuter_utils::shrine_with_wad_usd_stable_transmuter(
                Option::Some(transmuter_class), Option::Some(token_class),
            );
        let first_transmuter = transmuter;
        let nonwad_usd_stable = transmuter_utils::nonwad_usd_stable_deploy(Option::Some(token_class));
        let second_transmuter = transmuter_utils::transmuter_deploy(
            Option::Some(transmuter_class),
            shrine.contract_address,
            nonwad_usd_stable.contract_address,
            transmuter_utils::receiver(),
        );

        start_cheat_caller_address(registry.contract_address, transmuter_utils::admin());
        registry.add_transmuter(first_transmuter.contract_address);

        assert(registry.get_transmuters() == array![first_transmuter.contract_address].span(), 'wrong transmuters #1');

        registry.add_transmuter(second_transmuter.contract_address);

        assert(
            registry
                .get_transmuters() == array![first_transmuter.contract_address, second_transmuter.contract_address]
                .span(),
            'wrong transmuters #2',
        );

        registry.remove_transmuter(first_transmuter.contract_address);

        assert(registry.get_transmuters() == array![second_transmuter.contract_address].span(), 'wrong transmuters #3');

        registry.add_transmuter(first_transmuter.contract_address);

        assert(
            registry
                .get_transmuters() == array![second_transmuter.contract_address, first_transmuter.contract_address]
                .span(),
            'wrong transmuters #4',
        );

        registry.remove_transmuter(first_transmuter.contract_address);

        assert(registry.get_transmuters() == array![second_transmuter.contract_address].span(), 'wrong transmuters #5');
    }

    #[test]
    #[should_panic(expected: 'TRR: Transmuter already exists')]
    fn test_add_duplicate_transmuter_fail() {
        let registry = transmuter_utils::transmuter_registry_deploy();

        let transmuter_utils::TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(registry.contract_address, transmuter_utils::admin());
        registry.add_transmuter(transmuter.contract_address);
        registry.add_transmuter(transmuter.contract_address);
    }

    #[test]
    #[should_panic(expected: 'TRR: Transmuter does not exist')]
    fn test_remove_nonexistent_transmuter_fail() {
        let registry = transmuter_utils::transmuter_registry_deploy();

        let transmuter_utils::TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(registry.contract_address, transmuter_utils::admin());
        registry.remove_transmuter(transmuter.contract_address);
    }
}
