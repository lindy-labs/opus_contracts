#[starknet::component]
mod address_registry_component {
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::{ContractAddress};

    #[storage]
    struct Storage {
        entries_count: u32,
        entry_ids: LegacyMap::<ContractAddress, u32>,
        entries: LegacyMap::<u32, ContractAddress>,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        EntryAdded: EntryAdded,
        EntryRemoved: EntryRemoved,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct EntryAdded {
        entry: ContractAddress,
        entry_id: u32
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct EntryRemoved {
        entry: ContractAddress,
        entry_id: u32
    }

    #[generate_trait]
    impl AddressRegistryHelpers<
        TContractState, +HasComponent<TContractState>
    > of AddressRegistryHelpersTrait<TContractState> {
        //
        // getters
        //

        fn get_entries_count(self: @ComponentState<TContractState>) -> u32 {
            self.entries_count.read()
        }

        fn get_entry(self: @ComponentState<TContractState>, entry_id: u32) -> ContractAddress {
            self.entries.read(entry_id)
        }

        fn get_entries(self: @ComponentState<TContractState>) -> Span<ContractAddress> {
            let mut entries: Array<ContractAddress> = ArrayTrait::new();

            let mut entry_id: u32 = 1;
            let loop_end: u32 = self.entries_count.read() + 1;
            loop {
                if entry_id == loop_end {
                    break entries.span();
                }

                entries.append(self.entries.read(entry_id));

                entry_id += 1;
            }
        }

        //
        // setters
        //

        fn add_entry(
            ref self: ComponentState<TContractState>, entry: ContractAddress, error: felt252
        ) {
            assert(self.entry_ids.read(entry) == 0, error);
            let entry_id: u32 = self.entries_count.read() + 1;

            self.entries_count.write(entry_id);
            self.entry_ids.write(entry, entry_id);
            self.entries.write(entry_id, entry);

            self.emit(EntryAdded { entry, entry_id });
        }

        fn remove_entry(
            ref self: ComponentState<TContractState>, entry: ContractAddress, error: felt252
        ) {
            let entry_id: u32 = self.entry_ids.read(entry);
            assert(entry_id != 0, error);
            let entries_count: u32 = self.entries_count.read();

            // Reset mapping of entry to entry ID
            self.entry_ids.write(entry, 0);

            // Move last entry ID to removed entry ID
            let last_entry_id: u32 = entries_count;
            self.entries.write(last_entry_id, ContractAddressZeroable::zero());
            if entry_id != last_entry_id {
                let last_entry: ContractAddress = self.entries.read(last_entry_id);
                self.entries.write(entry_id, last_entry);
                self.entry_ids.write(last_entry, entry_id);
            }

            // Decrement entries count
            self.entries_count.write(entries_count - 1);

            self.emit(EntryRemoved { entry, entry_id });
        }
    }
}
