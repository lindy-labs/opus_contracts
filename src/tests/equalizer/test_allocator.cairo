mod test_allocator {
    use opus::core::allocator::allocator as allocator_contract;
    use opus::core::roles::allocator_roles;
    use opus::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use opus::tests::common;
    use opus::tests::equalizer::utils::equalizer_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::utils::wadray::Ray;

    use snforge_std::{start_prank, CheatTarget};
    use starknet::ContractAddress;

    #[test]
    fn test_allocator_deploy() {
        let allocator = equalizer_utils::allocator_deploy(
            equalizer_utils::initial_recipients(), equalizer_utils::initial_percentages()
        );

        let expected_recipients = equalizer_utils::initial_recipients();
        let expected_percentages = equalizer_utils::initial_percentages();

        let (recipients, percentages) = allocator.get_allocation();

        assert(recipients == expected_recipients, 'wrong recipients');
        assert(percentages == expected_percentages, 'wrong percentages');
        assert(recipients.len() == 3, 'wrong array length');
        assert(recipients.len() == percentages.len(), 'array length mismatch');

        let allocator_ac = IAccessControlDispatcher {
            contract_address: allocator.contract_address
        };
        let admin = shrine_utils::admin();
        assert(allocator_ac.get_admin() == admin, 'wrong admin');
        assert(allocator_ac.get_roles(admin) == allocator_roles::SET_ALLOCATION, 'wrong role');
        assert(allocator_ac.has_role(allocator_roles::SET_ALLOCATION, admin), 'role not granted');
    }

    #[test]
    #[should_panic(expected: ('AL: Array lengths mismatch', 'CONSTRUCTOR_FAILED'))]
    fn test_allocator_deploy_input_arrays_mismatch_fail() {
        let mut recipients = equalizer_utils::initial_recipients();
        recipients.pop_front();

        let allocator = equalizer_utils::allocator_deploy(
            recipients, equalizer_utils::initial_percentages()
        );
    }

    #[test]
    #[should_panic(expected: ('AL: No recipients', 'CONSTRUCTOR_FAILED'))]
    fn test_allocator_deploy_no_recipients_fail() {
        let recipients: Array<ContractAddress> = ArrayTrait::new();
        let percentages: Array<Ray> = ArrayTrait::new();

        let allocator = equalizer_utils::allocator_deploy(recipients.span(), percentages.span());
    }

    #[test]
    #[should_panic(expected: ('AL: sum(percentages) != RAY_ONE', 'CONSTRUCTOR_FAILED'))]
    fn test_allocator_deploy_invalid_percentage_fail() {
        let allocator = equalizer_utils::allocator_deploy(
            equalizer_utils::initial_recipients(), equalizer_utils::invalid_percentages()
        );
    }

    #[test]
    fn test_set_allocation_pass() {
        let allocator = equalizer_utils::allocator_deploy(
            equalizer_utils::initial_recipients(), equalizer_utils::initial_percentages()
        );

        start_prank(CheatTarget::All, shrine_utils::admin());
        let new_recipients = equalizer_utils::new_recipients();
        let new_percentages = equalizer_utils::new_percentages();
        allocator.set_allocation(new_recipients, new_percentages);

        let (recipients, percentages) = allocator.get_allocation();
        assert(recipients == new_recipients, 'wrong recipients');
        assert(percentages == new_percentages, 'wrong percentages');
        assert(recipients.len() == 4, 'wrong array length');
        assert(recipients.len() == percentages.len(), 'array length mismatch');

        let mut expected_events: Span<allocator_contract::Event> = array![
            allocator_contract::Event::AllocationUpdated(
                allocator_contract::AllocationUpdated { recipients, percentages }
            ),
        ]
            .span();
        common::assert_events_emitted(allocator.contract_address, expected_events, Option::None);
    }

    #[test]
    #[should_panic(expected: ('AL: Array lengths mismatch', 'ENTRYPOINT_FAILED'))]
    fn test_set_allocation_arrays_mismatch_fail() {
        let allocator = equalizer_utils::allocator_deploy(
            equalizer_utils::initial_recipients(), equalizer_utils::initial_percentages()
        );

        start_prank(CheatTarget::All, shrine_utils::admin());
        let new_recipients = equalizer_utils::new_recipients();
        let mut new_percentages = equalizer_utils::new_percentages();
        new_percentages.pop_front();
        allocator.set_allocation(new_recipients, new_percentages);
    }

    #[test]
    #[should_panic(expected: ('AL: No recipients', 'ENTRYPOINT_FAILED'))]
    fn test_set_allocation_no_recipients_fail() {
        let allocator = equalizer_utils::allocator_deploy(
            equalizer_utils::initial_recipients(), equalizer_utils::initial_percentages()
        );

        start_prank(CheatTarget::All, shrine_utils::admin());
        let recipients: Array<ContractAddress> = ArrayTrait::new();
        let percentages: Array<Ray> = ArrayTrait::new();
        allocator.set_allocation(recipients.span(), percentages.span());
    }

    #[test]
    #[should_panic(expected: ('AL: sum(percentages) != RAY_ONE', 'ENTRYPOINT_FAILED'))]
    fn test_set_allocation_invalid_percentage_fail() {
        let allocator = equalizer_utils::allocator_deploy(
            equalizer_utils::initial_recipients(), equalizer_utils::initial_percentages()
        );

        start_prank(CheatTarget::All, shrine_utils::admin());
        let mut new_recipients = equalizer_utils::new_recipients();
        // Pop one off new recipients to set it to same length as invalid percentages
        new_recipients.pop_front();
        let new_percentages = equalizer_utils::invalid_percentages();
        allocator.set_allocation(new_recipients, new_percentages);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_allocation_unauthorized_fail() {
        let allocator = equalizer_utils::allocator_deploy(
            equalizer_utils::initial_recipients(), equalizer_utils::initial_percentages()
        );

        start_prank(CheatTarget::All, common::badguy());
        allocator
            .set_allocation(equalizer_utils::new_recipients(), equalizer_utils::new_percentages());
    }
}
