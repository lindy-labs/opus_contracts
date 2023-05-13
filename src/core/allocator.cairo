#[contract]
mod Allocator {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::ContractAddress;

    use aura::core::roles::AllocatorRoles;

    use aura::utils::access_control::AccessControl;
    use aura::utils::storage_access_impls;
    use aura::utils::wadray::{Ray, RayZeroable, RAY_ONE};

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

    #[event]
    fn AllocationUpdated(recipients: Array<ContractAddress>, percentages: Array<Ray>) {}

    //
    // Getters
    //

    // Returns a tuple of ordered arrays of recipients' addresses and their respective
    // percentage share of newly minted surplus debt.
    #[view]
    fn get_allocation() -> (Array<ContractAddress>, Array<Ray>) {
        let mut recipients: Array<ContractAddress> = ArrayTrait::new();
        let mut percentages: Array<Ray> = ArrayTrait::new();

        let mut idx: u32 = 0;
        let recipients_count: u32 = recipients_count::read();
        loop {
            if idx == recipients_count {
                break ();
            }

            let recipient: ContractAddress = recipients::read(idx);
            recipients.append(recipient);
            percentages.append(percentages::read(recipient));

            idx += 1;
        };

        (recipients, percentages)
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        admin: ContractAddress, recipients: Array<ContractAddress>, percentages: Array<Ray>
    ) {
        AccessControl::initializer(admin);
        AccessControl._grant_role(AllocatorRoles::default_admin_role(), admin);

        set_allocation_internal(recipients, percentages);
    }

    //
    // External
    //

    // Update the recipients and their respective percentage share of newly minted surplus debt
    // by overwriting the existing values in `recipients` and `percentages`.
    #[external]
    fn set_allocation(recipients: Array<ContractAddress>, percentages: Array<Ray>) {
        AccessControl::assert_has_role(AllocatorRoles.SET_ALLOCATION);

        set_allocation_internal(recipients, percentages);
    }

    //
    // Internal
    //

    // Helper function to update the allocation.
    // Ensures the following:
    // - both arrays of recipient addresses and percentages are of equal length;
    // - there is at least one recipient;
    // - the percentages add up to one Ray.
    fn set_allocation_internal(recipients: Array<ContractAddress>, percentages: Array<Ray>) {
        let mut recipients_span: Span<ContractAddress> = recipients.span();
        let mut percentages_span: Span<Ray> = percentages.span();

        let recipients_len: u32 = recipients_span.len();
        assert(recipients_len.is_non_zero(), 'No recipients');
        assert(recipients_len == percentages_span.len(), 'Array length mismatch');

        let mut total_percentage: Ray = Ray::zero();
        let mut idx: u32 = 0;
        loop {
            match (recipients_span.pop_front()) {
                Option::Some(recipient) => {
                    recipients::write(idx, *recipient);

                    let percentage: Ray = *(percentages_span.pop_front().unwrap());
                    percentages::write(*recipient, percentage);

                    total_percentage += percentage;

                    idx += 1;
                },
                Option::None(_) => {
                    break ();
                }
            };
        };

        assert(total_percentage == RAY_ONE, 'sum(percentages) != RAY_ONE');

        AllocationUpdated(recipients, percentages);
    }
}
