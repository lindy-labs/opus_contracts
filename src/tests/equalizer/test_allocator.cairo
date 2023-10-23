mod TestAllocator {
    use starknet::ContractAddress;
    use starknet::testing::set_contract_address;

    use opus::core::allocator::Allocator;
    use opus::core::roles::AllocatorRoles;

    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use opus::utils::wadray::Ray;

    use opus::tests::equalizer::utils::EqualizerUtils;
    use opus::tests::shrine::utils::ShrineUtils;
    use opus::tests::common;

    #[test]
    #[available_gas(20000000000)]
    fn test_allocator_deploy() {
        let allocator = EqualizerUtils::allocator_deploy(
            EqualizerUtils::initial_recipients(), EqualizerUtils::initial_percentages()
        );

        let expected_recipients = EqualizerUtils::initial_recipients();
        let expected_percentages = EqualizerUtils::initial_percentages();

        let (recipients, percentages) = allocator.get_allocation();

        assert(recipients == expected_recipients, 'wrong recipients');
        assert(percentages == expected_percentages, 'wrong percentages');
        assert(recipients.len() == 3, 'wrong array length');
        assert(recipients.len() == percentages.len(), 'array length mismatch');

        let allocator_ac = IAccessControlDispatcher {
            contract_address: allocator.contract_address
        };
        let admin = ShrineUtils::admin();
        assert(allocator_ac.get_admin() == admin, 'wrong admin');
        assert(allocator_ac.get_roles(admin) == AllocatorRoles::SET_ALLOCATION, 'wrong role');
        assert(allocator_ac.has_role(AllocatorRoles::SET_ALLOCATION, admin), 'role not granted');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('AL: Array lengths mismatch', 'CONSTRUCTOR_FAILED'))]
    fn test_allocator_deploy_input_arrays_mismatch_fail() {
        let mut recipients = EqualizerUtils::initial_recipients();
        recipients.pop_front();

        let allocator = EqualizerUtils::allocator_deploy(
            recipients, EqualizerUtils::initial_percentages()
        );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('AL: No recipients', 'CONSTRUCTOR_FAILED'))]
    fn test_allocator_deploy_no_recipients_fail() {
        let recipients: Array<ContractAddress> = ArrayTrait::new();
        let percentages: Array<Ray> = ArrayTrait::new();

        let allocator = EqualizerUtils::allocator_deploy(recipients.span(), percentages.span());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('AL: sum(percentages) != RAY_ONE', 'CONSTRUCTOR_FAILED'))]
    fn test_allocator_deploy_invalid_percentage_fail() {
        let allocator = EqualizerUtils::allocator_deploy(
            EqualizerUtils::initial_recipients(), EqualizerUtils::invalid_percentages()
        );
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_allocation_pass() {
        let allocator = EqualizerUtils::allocator_deploy(
            EqualizerUtils::initial_recipients(), EqualizerUtils::initial_percentages()
        );

        set_contract_address(ShrineUtils::admin());
        let new_recipients = EqualizerUtils::new_recipients();
        let new_percentages = EqualizerUtils::new_percentages();
        allocator.set_allocation(new_recipients, new_percentages);

        let (recipients, percentages) = allocator.get_allocation();
        assert(recipients == new_recipients, 'wrong recipients');
        assert(percentages == new_percentages, 'wrong percentages');
        assert(recipients.len() == 4, 'wrong array length');
        assert(recipients.len() == percentages.len(), 'array length mismatch');

        let mut expected_events: Span<Allocator::Event> = array![
            Allocator::Event::AllocationUpdated(
                Allocator::AllocationUpdated { recipients, percentages }
            ),
        ]
            .span();
        common::assert_events_emitted(allocator.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('AL: Array lengths mismatch', 'ENTRYPOINT_FAILED'))]
    fn test_set_allocation_arrays_mismatch_fail() {
        let allocator = EqualizerUtils::allocator_deploy(
            EqualizerUtils::initial_recipients(), EqualizerUtils::initial_percentages()
        );

        set_contract_address(ShrineUtils::admin());
        let new_recipients = EqualizerUtils::new_recipients();
        let mut new_percentages = EqualizerUtils::new_percentages();
        new_percentages.pop_front();
        allocator.set_allocation(new_recipients, new_percentages);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('AL: No recipients', 'ENTRYPOINT_FAILED'))]
    fn test_set_allocation_no_recipients_fail() {
        let allocator = EqualizerUtils::allocator_deploy(
            EqualizerUtils::initial_recipients(), EqualizerUtils::initial_percentages()
        );

        set_contract_address(ShrineUtils::admin());
        let recipients: Array<ContractAddress> = ArrayTrait::new();
        let percentages: Array<Ray> = ArrayTrait::new();
        allocator.set_allocation(recipients.span(), percentages.span());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('AL: sum(percentages) != RAY_ONE', 'ENTRYPOINT_FAILED'))]
    fn test_set_allocation_invalid_percentage_fail() {
        let allocator = EqualizerUtils::allocator_deploy(
            EqualizerUtils::initial_recipients(), EqualizerUtils::initial_percentages()
        );

        set_contract_address(ShrineUtils::admin());
        let mut new_recipients = EqualizerUtils::new_recipients();
        // Pop one off new recipients to set it to same length as invalid percentages
        new_recipients.pop_front();
        let new_percentages = EqualizerUtils::invalid_percentages();
        allocator.set_allocation(new_recipients, new_percentages);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_allocation_unauthorized_fail() {
        let allocator = EqualizerUtils::allocator_deploy(
            EqualizerUtils::initial_recipients(), EqualizerUtils::initial_percentages()
        );

        set_contract_address(common::badguy());
        allocator
            .set_allocation(EqualizerUtils::new_recipients(), EqualizerUtils::new_percentages());
    }
}
