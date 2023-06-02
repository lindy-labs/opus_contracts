#[contract]
mod Allocator {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::ContractAddress;
    use traits::{Default, Into};

    use aura::core::roles::AllocatorRoles;

    use aura::interfaces::IAllocator::IAllocator;
    use aura::utils::access_control::AccessControl;
    use aura::utils::serde::SpanSerde;
    use aura::utils::storage_access;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RayZeroable, RAY_ONE};

    #[starknet::storage]
    struct Storage {
        // Number of recipients in the current allocation
        recipients_count: u32,
        // Keeps track of the address for each recipient by index
        // Note that the index count of recipients stored in this mapping may exceed the 
        // current `recipients_count`. This will happen if any previous allocations had 
        // more recipients than the current allocation.
        // (idx) -> (Recipient Address)
        recipients: LegacyMap::<u32, ContractAddress>,
        // Keeps track of the percentage for each recipient by address
        // (Recipient Address) -> (percentage)
        percentages: LegacyMap::<ContractAddress, Ray>,
    }

    //
    // Events
    //

    #[derive(Drop, starknet::Event)]
    enum Event {
        #[event]
        AllocationUpdated: AllocationUpdated,
    }

    #[derive(Drop, starknet::Event)]
    struct AllocationUpdated {
        recipients: Span<ContractAddress>,
        percentages: Span<Ray>,
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: Storage, admin: ContractAddress, recipients: Span<ContractAddress>, percentages: Span<Ray>
    ) {
        AccessControl::initializer(admin);
        AccessControl::grant_role_internal(AllocatorRoles::default_admin_role(), admin);

        self.set_allocation_internal(recipients, percentages);
    }

    #[external]
    impl IAllocatorImpl of IAllocator<Storage> {
        //
        // Getters
        //

        // Returns a tuple of ordered arrays of recipients' addresses and their respective
        // percentage share of newly minted surplus debt.
        fn get_allocation(self: @Storage) -> (Span<ContractAddress>, Span<Ray>) {
            let mut recipients: Array<ContractAddress> = Default::default();
            let mut percentages: Array<Ray> = Default::default();

            let mut idx: u32 = 0;
            let recipients_count: u32 = self.recipients_count.read();

            loop {
                if idx == recipients_count {
                    break (recipients.span(), percentages.span());
                }

                let recipient: ContractAddress = self.recipients.read(idx);
                recipients.append(recipient);
                percentages.append(self.percentages.read(recipient));

                idx += 1;
            }
        }

        //
        // External
        //

        // Update the recipients and their respective percentage share of newly minted surplus debt
        // by overwriting the existing values in `recipients` and `percentages`.
        fn set_allocation(
            ref self: Storage, recipients: Span<ContractAddress>, percentages: Span<Ray>
        ) {
            AccessControl::assert_has_role(AllocatorRoles::SET_ALLOCATION);

            self.set_allocation_internal(recipients, percentages);
        }
    }

    #[generate_trait]
    impl StorageImpl of StorageTrait {
        //
        // Internal
        //

        // Helper function to update the allocation.
        // Ensures the following:
        // - both arrays of recipient addresses and percentages are of equal length;
        // - there is at least one recipient;
        // - the percentages add up to one Ray.
        fn set_allocation_internal(
            ref self: Storage, mut recipients: Span<ContractAddress>, mut percentages: Span<Ray>
        ) {
            let recipients_len: u32 = recipients.len();
            assert(recipients_len != 0, 'No recipients');
            assert(recipients_len == percentages.len(), 'Array length mismatch');

            let mut total_percentage: Ray = RayZeroable::zero();
            let mut idx: u32 = 0;

            // Event is emitted here because the spans will be modified in the loop below
            self.emit(Event::AllocationUpdated(AllocationUpdated{recipients, percentages}));

            loop {
                match recipients.pop_front() {
                    Option::Some(recipient) => {
                        self.recipients.write(idx, *recipient);

                        let percentage: Ray = *(percentages.pop_front().unwrap());
                        self.percentages.write(*recipient, percentage);

                        total_percentage += percentage;

                        idx += 1;
                    },
                    Option::None(_) => {
                        break;
                    }
                };
            };

            assert(total_percentage == RAY_ONE.into(), 'sum(percentages) != RAY_ONE');

            self.recipients_count.write(recipients_len);
        }
    }
}
