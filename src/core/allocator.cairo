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

    #[event]
    fn AllocationUpdated(recipients: Span<ContractAddress>, percentages: Span<Ray>) {}

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

    #[constructor]
    fn constructor(admin: ContractAddress, recipients: Array<ContractAddress>, percentages: Array<Ray>) {
        // AccessControl.initializer(admin);
        // AccessControl._grant_role(AllocatorRoles.SET_ALLOCATION, admin);

        set_allocation_internal(recipients.span(), percentages.span());
    }

    #[external]
    fn set_allocation(recipients: Array<ContractAddress>, percentages: Array<Ray>) {
        // AccessControl.assert_has_role(AllocatorRoles.SET_ALLOCATION);
        set_allocation_internal(recipients.span(), percentages.span());
    }

    fn set_allocation_internal(recipients: Span<ContractAddress>, percentages: Span<Ray>) {
        let recipients_len: u32 = recipients.len();
        assert(recipients_len != 0, 'No recipients');
        assert(recipients_len == percentages.len(), 'Array length mismatch');

        let mut total_percentage: Ray = Ray { val: 0 };
        let mut idx: u32 = 0;
        loop {
            if idx == recipients_len {
                break ();
            }

            let recipient: ContractAddress = *recipients[idx];
            recipients::write(idx, recipient);

            let percentage: Ray = *percentages[idx];
            percentages::write(recipient, percentage);

            total_percentage += percentage;
        };

        AllocationUpdated(recipients, percentages);
    }

}
