#[starknet::contract]
pub mod allocator {
    use access_control::access_control_component;
    use core::dict::Felt252Dict;
    use core::num::traits::Zero;
    use opus::core::roles::allocator_roles;
    use opus::interfaces::IAllocator::IAllocator;
    use starknet::ContractAddress;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use wadray::{RAY_ONE, Ray};

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    //
    // Constants
    //

    // Helper constant to set the starting index for iterating over the recipients
    // and percentages in the order they were added
    const LOOP_START: u32 = 1;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        // Number of recipients in the current allocation
        recipients_count: u32,
        // Starts from index 1
        // Keeps track of the address for each recipient by index
        // Note that the index count of recipients stored in this mapping may exceed the
        // current `recipients_count`. This will happen if any previous allocations had
        // more recipients than the current allocation.
        // (idx) -> (Recipient Address)
        recipients: Map<u32, ContractAddress>,
        // Keeps track of the percentage for each recipient by address
        // (Recipient Address) -> (percentage)
        percentages: Map<ContractAddress, Ray>,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AccessControlEvent: access_control_component::Event,
        AllocationUpdated: AllocationUpdated,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct AllocationUpdated {
        pub recipients: Span<ContractAddress>,
        pub percentages: Span<Ray>,
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState, admin: ContractAddress, recipients: Span<ContractAddress>, percentages: Span<Ray>,
    ) {
        self.access_control.initializer(admin, Option::Some(allocator_roles::ADMIN));

        self.set_allocation_helper(recipients, percentages);
    }

    //
    // External Allocator functions
    //

    #[abi(embed_v0)]
    impl IAllocatorImpl of IAllocator<ContractState> {
        //
        // Getters
        //

        // Returns a tuple of ordered arrays of recipients' addresses and their respective
        // percentage share of newly minted surplus debt.
        fn get_allocation(self: @ContractState) -> (Span<ContractAddress>, Span<Ray>) {
            let mut recipients: Array<ContractAddress> = ArrayTrait::new();
            let mut percentages: Array<Ray> = ArrayTrait::new();

            let mut idx: u32 = LOOP_START;
            let loop_end: u32 = self.recipients_count.read() + LOOP_START;

            loop {
                if idx == loop_end {
                    break (recipients.span(), percentages.span());
                }

                let recipient: ContractAddress = self.recipients.read(idx);
                recipients.append(recipient);
                percentages.append(self.percentages.read(recipient));

                idx += 1;
            }
        }

        //
        // Setters
        //

        // Update the recipients and their respective percentage share of newly minted surplus debt
        // by overwriting the existing values in `recipients` and `percentages`.
        fn set_allocation(ref self: ContractState, recipients: Span<ContractAddress>, percentages: Span<Ray>) {
            self.access_control.assert_has_role(allocator_roles::SET_ALLOCATION);

            self.set_allocation_helper(recipients, percentages);
        }
    }

    //
    // Internal Allocator functions
    //

    #[generate_trait]
    impl AllocatorHelpers of AllocatorHelpersTrait {
        // Helper function to update the allocation.
        // Ensures the following:
        // - both arrays of recipient addresses and percentages are of equal length;
        // - there is at least one recipient;
        // - the percentages add up to one Ray.
        fn set_allocation_helper(ref self: ContractState, recipients: Span<ContractAddress>, percentages: Span<Ray>) {
            let recipients_len: u32 = recipients.len();
            assert(recipients_len.is_non_zero(), 'AL: No recipients');
            assert(recipients_len == percentages.len(), 'AL: Array lengths mismatch');

            // Initialize a dictionary that maps an address to its index to easily
            // check for duplicates
            let mut recipients_dict: Felt252Dict<u32> = Default::default();

            let mut total_percentage: Ray = Zero::zero();
            let mut idx: u32 = LOOP_START;

            let mut percentages_copy = percentages;
            for recipient in recipients {
                let recipient_key: felt252 = (*recipient).into();
                assert(recipients_dict.get(recipient_key).is_zero(), 'AL: Duplicate address');
                recipients_dict.insert(recipient_key, idx);

                self.recipients.write(idx, *recipient);

                let percentage: Ray = *(percentages_copy.pop_front().unwrap());
                self.percentages.write(*recipient, percentage);

                total_percentage += percentage;

                idx += 1;
            }

            assert(total_percentage == RAY_ONE.into(), 'AL: sum(percentages) != RAY_ONE');

            self.recipients_count.write(recipients_len);

            self.emit(AllocationUpdated { recipients, percentages });
        }
    }
}
