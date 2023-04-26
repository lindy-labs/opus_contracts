#[contract]
mod Allocator {
    use array::ArrayTrait;
    use array::SpanTrait;
    use starknet::ContractAddress;

    use aura::utils::storage_access_impls::RayTupleStorageAccess;
    use aura::utils::wadray::Ray;

    struct Storage {
        recipients_count: u32,
        recipients: LegacyMap::<u32, ContractAddress>,
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
        // AccessControl.initializer(admin);
        // AccessControl._grant_role(AllocatorRoles.SET_ALLOCATION, admin);

        set_allocation_internal(recipients, percentages);
    }

    //
    // External
    //

    #[external]
    fn set_allocation(recipients: Array<ContractAddress>, percentages: Array<Ray>) {
        // AccessControl.assert_has_role(AllocatorRoles.SET_ALLOCATION);
        set_allocation_internal(recipients, percentages);
    }

    //
    // Internal
    //

    fn set_allocation_internal(recipients: Array<ContractAddress>, percentages: Array<Ray>) {
        // TODO: kludge until `Serde` is implemented for Span or variable moved error is gone for Array
        let recipients_span: Span<ContractAddress> = recipients.span();
        let percentages_span: Span<Ray> = percentages.span();

        let recipients_len: u32 = recipients_span.len();
        assert(recipients_len != 0, 'No recipients');
        assert(recipients_len == percentages_span.len(), 'Array length mismatch');

        let mut total_percentage: Ray = Ray { val: 0 };
        let mut idx: u32 = 0;
        loop {
            if idx == recipients_len {
                break ();
            }

            let recipient: ContractAddress = *recipients_span[idx];
            recipients::write(idx, recipient);

            let percentage: Ray = *percentages_span[idx];
            percentages::write(recipient, percentage);

            total_percentage += percentage;
        };

        AllocationUpdated(recipients, percentages);
    }
}
