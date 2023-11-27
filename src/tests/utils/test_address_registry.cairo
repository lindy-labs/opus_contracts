mod test_address_registry {
    use opus::tests::common;
    use opus::tests::utils::mock_address_registry::mock_address_registry;
    use opus::utils::address_registry::address_registry_component::AddressRegistryHelpers;
    use opus::utils::address_registry::address_registry_component;
    use starknet::contract_address::{
        ContractAddress, ContractAddressZeroable, contract_address_try_from_felt252
    };
    use starknet::testing::{pop_log, pop_log_raw, set_caller_address};

    //
    // Constants
    //

    fn entry1() -> ContractAddress {
        contract_address_try_from_felt252('entry 1').unwrap()
    }

    fn entry2() -> ContractAddress {
        contract_address_try_from_felt252('entry 2').unwrap()
    }

    fn entry3() -> ContractAddress {
        contract_address_try_from_felt252('entry 3').unwrap()
    }

    fn zero_addr() -> ContractAddress {
        ContractAddressZeroable::zero()
    }

    //
    // Test setup
    //

    fn state() -> mock_address_registry::ContractState {
        mock_address_registry::contract_state_for_testing()
    }

    //
    // Tests
    //

    #[test]
    #[available_gas(10000000)]
    fn test_setup() {
        let state = state();

        assert(state.address_registry.get_entries_count().is_zero(), 'should be zero entries');
        let empty_entries: Span<ContractAddress> = array![].span();
        assert(state.address_registry.get_entries() == empty_entries, 'should be empty');
    }

    #[test]
    #[available_gas(10000000)]
    fn test_add_and_remove_entry() {
        let mut state = state();

        // add first entry
        // order: 1

        state.address_registry.add_entry(entry1(), 'Dummy message');

        let expected_entry_id: u32 = 1;
        let event = pop_log::<address_registry_component::EntryAdded>(zero_addr()).unwrap();
        assert(event.entry == entry1(), 'should be entry 1');
        assert(event.entry_id == expected_entry_id, 'should be ID 1');

        assert(pop_log_raw(zero_addr()).is_none(), 'unexpected event');

        assert(state.address_registry.get_entry(expected_entry_id) == entry1(), 'wrong entry #1');
        assert(state.address_registry.get_entries_count() == 1, 'should be 1 entry');
        let expected_entries: Span<ContractAddress> = array![entry1()].span();
        assert(state.address_registry.get_entries() == expected_entries, 'wrong entries #1');

        // add second entry
        // order: 1, 2

        state.address_registry.add_entry(entry2(), 'Dummy message');

        let expected_entry_id: u32 = 2;
        let event = pop_log::<address_registry_component::EntryAdded>(zero_addr()).unwrap();
        assert(event.entry == entry2(), 'should be entry 2');
        assert(event.entry_id == expected_entry_id, 'should be ID 2');

        assert(pop_log_raw(zero_addr()).is_none(), 'unexpected event');

        assert(state.address_registry.get_entry(expected_entry_id) == entry2(), 'wrong entry #2');
        assert(state.address_registry.get_entries_count() == 2, 'should be 2 entries');
        let expected_entries: Span<ContractAddress> = array![entry1(), entry2()].span();
        assert(state.address_registry.get_entries() == expected_entries, 'wrong entries #2');

        // add third entry
        // order: 1, 2, 3

        state.address_registry.add_entry(entry3(), 'Dummy message');

        let expected_entry_id: u32 = 3;
        let event = pop_log::<address_registry_component::EntryAdded>(zero_addr()).unwrap();
        assert(event.entry == entry3(), 'should be entry 3');
        assert(event.entry_id == expected_entry_id, 'should be ID 3');

        assert(pop_log_raw(zero_addr()).is_none(), 'unexpected event');

        assert(state.address_registry.get_entry(expected_entry_id) == entry3(), 'wrong entry #3');
        assert(state.address_registry.get_entries_count() == 3, 'should be 3 entries');
        let expected_entries: Span<ContractAddress> = array![entry1(), entry2(), entry3()].span();
        assert(state.address_registry.get_entries() == expected_entries, 'wrong entries #3');

        // remove entry at last index 
        // order: 1, 2

        state.address_registry.remove_entry(entry3(), 'Dummy message');

        let expected_entry_id: u32 = 3;
        let event = pop_log::<address_registry_component::EntryRemoved>(zero_addr()).unwrap();
        assert(event.entry == entry3(), 'should be entry 3');
        assert(event.entry_id == expected_entry_id, 'should be ID 3');

        assert(pop_log_raw(zero_addr()).is_none(), 'unexpected event');

        assert(state.address_registry.get_entry(expected_entry_id).is_zero(), 'wrong entry #4');
        assert(state.address_registry.get_entries_count() == 2, 'should be 2 entries');
        let expected_entries: Span<ContractAddress> = array![entry1(), entry2()].span();
        assert(state.address_registry.get_entries() == expected_entries, 'wrong entries #4');

        // add back removed entry
        // order: 1, 2, 3
        state.address_registry.add_entry(entry3(), 'Dummy message');
        assert(state.address_registry.get_entries_count() == 3, 'sanity check #1');
        let _ = pop_log_raw(zero_addr());

        // remove entry at first index
        // order: 3, 2
        state.address_registry.remove_entry(entry1(), 'Dummy message');

        let expected_entry_id: u32 = 1;
        let event = pop_log::<address_registry_component::EntryRemoved>(zero_addr()).unwrap();
        assert(event.entry == entry1(), 'should be entry 1');
        assert(event.entry_id == expected_entry_id, 'should be ID 1');

        assert(pop_log_raw(zero_addr()).is_none(), 'unexpected event');

        assert(state.address_registry.get_entry(expected_entry_id) == entry3(), 'wrong entry #5');
        assert(state.address_registry.get_entries_count() == 2, 'should be 2 entries');
        let expected_entries: Span<ContractAddress> = array![entry3(), entry2()].span();
        assert(state.address_registry.get_entries() == expected_entries, 'wrong entries #5');

        // add back removed entry
        // order: 3, 2, 1
        state.address_registry.add_entry(entry1(), 'Dummy message');
        assert(state.address_registry.get_entries_count() == 3, 'sanity check #2');
        let _ = pop_log_raw(zero_addr());

        // remove entry that is not first or last index
        // order: 3, 1
        state.address_registry.remove_entry(entry2(), 'Dummy message');

        let expected_entry_id: u32 = 2;
        let event = pop_log::<address_registry_component::EntryRemoved>(zero_addr()).unwrap();
        assert(event.entry == entry2(), 'should be entry 2');
        assert(event.entry_id == expected_entry_id, 'should be ID 2');

        assert(pop_log_raw(zero_addr()).is_none(), 'unexpected event');

        assert(state.address_registry.get_entry(expected_entry_id) == entry1(), 'wrong entry #6');
        assert(state.address_registry.get_entries_count() == 2, 'should be 2 entries');
        let expected_entries: Span<ContractAddress> = array![entry3(), entry1()].span();
        assert(state.address_registry.get_entries() == expected_entries, 'wrong entries #6');

        // reset to zero
        state.address_registry.remove_entry(entry3(), 'Dummy message');
        state.address_registry.remove_entry(entry1(), 'Dummy message');

        assert(state.address_registry.get_entry(1).is_zero(), 'wrong entry #1');
        assert(state.address_registry.get_entries_count().is_zero(), 'should be 0 entries');
        let expected_entries: Span<ContractAddress> = array![].span();
        assert(state.address_registry.get_entries() == expected_entries, 'wrong entries #7');
    }

    #[test]
    #[available_gas(10000000)]
    #[should_panic(expected: ('Dummy message #2',))]
    fn test_add_duplicate_entry_fail() {
        let mut state = state();

        state.address_registry.add_entry(entry1(), 'Dummy message #1');
        assert(state.address_registry.get_entries_count() == 1, 'should be 1 entry');

        state.address_registry.add_entry(entry1(), 'Dummy message #2');
    }

    #[test]
    #[available_gas(10000000)]
    #[should_panic(expected: ('Dummy message #1',))]
    fn test_remove_non_existent_entry_fail() {
        let mut state = state();

        state.address_registry.remove_entry(entry1(), 'Dummy message #1');
    }
}
