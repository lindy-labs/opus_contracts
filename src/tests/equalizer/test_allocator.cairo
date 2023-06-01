#[cfg(test)]
mod TestAllocator {
    use array::{ArrayTrait, SpanTrait};
    use starknet::ContractAddress;
    use traits::Default;

    use aura::core::roles::AllocatorRoles;

    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use aura::utils::wadray::Ray;

    use aura::tests::equalizer::utils::EqualizerUtils;
    use aura::tests::shrine::utils::ShrineUtils;
    use aura::tests::test_utils;

    #[test]
    #[available_gas(20000000000)]
    fn test_allocator_deploy() {
        let allocator = EqualizerUtils::allocator_deploy(
            EqualizerUtils::initial_recipients(),
            EqualizerUtils::initial_percentages()
        );

        let expected_recipients = EqualizerUtils::initial_recipients();
        let expected_percentages = EqualizerUtils::initial_percentages();

        let (recipients, percentages) = allocator.get_allocation();

        test_utils::assert_spans_equal(recipients, expected_recipients);
        test_utils::assert_spans_equal(percentages, expected_percentages);
        assert(recipients.len() == percentages.len(), 'array length mismatch');

        let allocator_ac = IAccessControlDispatcher { contract_address: allocator.contract_address };
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
            recipients,
            EqualizerUtils::initial_percentages()
        );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('AL: No recipients', 'CONSTRUCTOR_FAILED'))]
    fn test_allocator_deploy_no_recipients_fail() {
        let recipients: Array<ContractAddress> = Default::default();
        let percentages: Array<Ray> = Default::default();

        let allocator = EqualizerUtils::allocator_deploy(
            recipients.span(),
            percentages.span()
        );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('AL: sum(percentages) != RAY_ONE', 'CONSTRUCTOR_FAILED'))]
    fn test_allocator_deploy_invalid_percentage_fail() {
        let allocator = EqualizerUtils::allocator_deploy(
            EqualizerUtils::initial_recipients(),
            EqualizerUtils::invalid_percentages()
        );
    }
}
