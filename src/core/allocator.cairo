#[contract]
mod Allocator {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::ContractAddress;
    use traits::{Default, Into};

    use aura::core::roles::AllocatorRoles;

    use aura::utils::access_control::AccessControl;
    use aura::utils::serde::SpanSerde;
    use aura::utils::storage_access;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RayZeroable, RAY_ONE};

    // Helper constant to set the starting index for iterating over the recipients
    // and percentages in the order they were added
    const LOOP_START: u32 = 1;

    struct Storage {
        // Number of recipients in the current allocation
        recipients_count: u32,
        // Starts from index 1
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
    fn AllocationUpdated(recipients: Span<ContractAddress>, percentages: Span<Ray>) {}

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        admin: ContractAddress, recipients: Span<ContractAddress>, percentages: Span<Ray>
    ) {
        AccessControl::initializer(admin);
        AccessControl::grant_role_internal(AllocatorRoles::default_admin_role(), admin);

        set_allocation_internal(recipients, percentages);
    }

    //
    // Getters
    //

    // Returns a tuple of ordered arrays of recipients' addresses and their respective
    // percentage share of newly minted surplus debt.
    #[view]
    fn get_allocation() -> (Span<ContractAddress>, Span<Ray>) {
        let mut recipients: Array<ContractAddress> = Default::default();
        let mut percentages: Array<Ray> = Default::default();

        let mut idx: u32 = LOOP_START;
        let loop_end: u32 = recipients_count::read() + LOOP_START;

        loop {
            if idx == loop_end {
                break (recipients.span(), percentages.span());
            }

            let recipient: ContractAddress = recipients::read(idx);
            recipients.append(recipient);
            percentages.append(percentages::read(recipient));

            idx += 1;
        }
    }

    //
    // External
    //

    // Update the recipients and their respective percentage share of newly minted surplus debt
    // by overwriting the existing values in `recipients` and `percentages`.
    #[external]
    fn set_allocation(recipients: Span<ContractAddress>, percentages: Span<Ray>) {
        AccessControl::assert_has_role(AllocatorRoles::SET_ALLOCATION);

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
    fn set_allocation_internal(recipients: Span<ContractAddress>, percentages: Span<Ray>) {
        let recipients_len: u32 = recipients.len();
        assert(recipients_len != 0, 'AL: No recipients');
        assert(recipients_len == percentages.len(), 'AL: Array lengths mismatch');

        let mut total_percentage: Ray = RayZeroable::zero();
        let mut idx: u32 = LOOP_START;

        let mut recipients_copy = recipients;
        let mut percentages_copy = percentages;
        loop {
            match recipients_copy.pop_front() {
                Option::Some(recipient) => {
                    recipients::write(idx, *recipient);

                    let percentage: Ray = *(percentages_copy.pop_front().unwrap());
                    percentages::write(*recipient, percentage);

                    total_percentage += percentage;

                    idx += 1;
                },
                Option::None(_) => {
                    break;
                }
            };
        };

        assert(total_percentage == RAY_ONE.into(), 'AL: sum(percentages) != RAY_ONE');

        recipients_count::write(recipients_len);

        AllocationUpdated(recipients, percentages);
    }

    //
    // Public AccessControl functions
    //

    #[view]
    fn get_roles(account: ContractAddress) -> u128 {
        AccessControl::get_roles(account)
    }

    #[view]
    fn has_role(role: u128, account: ContractAddress) -> bool {
        AccessControl::has_role(role, account)
    }

    #[view]
    fn get_admin() -> ContractAddress {
        AccessControl::get_admin()
    }

    #[external]
    fn grant_role(role: u128, account: ContractAddress) {
        AccessControl::grant_role(role, account);
    }

    #[external]
    fn revoke_role(role: u128, account: ContractAddress) {
        AccessControl::revoke_role(role, account);
    }

    #[external]
    fn renounce_role(role: u128) {
        AccessControl::renounce_role(role);
    }

    #[external]
    fn set_pending_admin(new_admin: ContractAddress) {
        AccessControl::set_pending_admin(new_admin);
    }

    #[external]
    fn accept_admin() {
        AccessControl::accept_admin();
    }
}
