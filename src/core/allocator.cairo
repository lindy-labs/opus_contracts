#[starknet::contract]
mod Allocator {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::ContractAddress;
    use traits::{Default, Into};
    use zeroable::Zeroable;

    use aura::core::roles::AllocatorRoles;

    use aura::interfaces::IAllocator::IAllocator;
    use aura::utils::access_control::{AccessControl, IAccessControl};
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RayZeroable, RAY_ONE};

    // Helper constant to set the starting index for iterating over the recipients
    // and percentages in the order they were added
    const LOOP_START: u32 = 1;

    #[storage]
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


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        AllocationUpdated: AllocationUpdated,
    }

    #[derive(Drop, starknet::Event)]
    struct AllocationUpdated {
        recipients: Span<ContractAddress>,
        percentages: Span<Ray>
    }


    //
    // Events
    //

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        recipients: Span<ContractAddress>,
        percentages: Span<Ray>
    ) {
        AccessControl::initializer(admin);
        AccessControl::grant_role_internal(AllocatorRoles::default_admin_role(), admin);

        self.set_allocation_internal(recipients, percentages);
    }

    //
    // External functions
    //

    #[external(v0)]
    impl IAllocatorImpl of IAllocator<ContractState> {
        //
        // Getters
        //

        // Returns a tuple of ordered arrays of recipients' addresses and their respective
        // percentage share of newly minted surplus debt.
        fn get_allocation(self: @ContractState) -> (Span<ContractAddress>, Span<Ray>) {
            let mut recipients: Array<ContractAddress> = Default::default();
            let mut percentages: Array<Ray> = Default::default();

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
        // External
        //

        // Update the recipients and their respective percentage share of newly minted surplus debt
        // by overwriting the existing values in `recipients` and `percentages`.
        fn set_allocation(
            ref self: ContractState, recipients: Span<ContractAddress>, percentages: Span<Ray>
        ) {
            AccessControl::assert_has_role(AllocatorRoles::SET_ALLOCATION);

            self.set_allocation_internal(recipients, percentages);
        }
    }

    //
    // Internal functions
    //

    #[generate_trait]
    impl AllocatorInternalFunctions of AllocatorInternalFunctionsTrait {
        // Helper function to update the allocation.
        // Ensures the following:
        // - both arrays of recipient addresses and percentages are of equal length;
        // - there is at least one recipient;
        // - the percentages add up to one Ray.
        fn set_allocation_internal(
            ref self: ContractState, recipients: Span<ContractAddress>, percentages: Span<Ray>
        ) {
            let recipients_len: u32 = recipients.len();
            assert(recipients_len.is_non_zero(), 'AL: No recipients');
            assert(recipients_len == percentages.len(), 'AL: Array lengths mismatch');

            let mut total_percentage: Ray = RayZeroable::zero();
            let mut idx: u32 = LOOP_START;

            let mut recipients_copy = recipients;
            let mut percentages_copy = percentages;
            loop {
                match recipients_copy.pop_front() {
                    Option::Some(recipient) => {
                        self.recipients.write(idx, *recipient);

                        let percentage: Ray = *(percentages_copy.pop_front().unwrap());
                        self.percentages.write(*recipient, percentage);

                        total_percentage += percentage;

                        idx += 1;
                    },
                    Option::None(_) => {
                        break;
                    }
                };
            };

            assert(total_percentage == RAY_ONE.into(), 'AL: sum(percentages) != RAY_ONE');

            self.recipients_count.write(recipients_len);

            self.emit(AllocationUpdated { recipients: recipients, percentages: percentages });
        }
    }

    //
    // Public AccessControl functions
    //

    #[external(v0)]
    impl IAccessControlImpl of IAccessControl<ContractState> {
        fn get_roles(self: @ContractState, account: ContractAddress) -> u128 {
            AccessControl::get_roles(account)
        }

        fn has_role(self: @ContractState, role: u128, account: ContractAddress) -> bool {
            AccessControl::has_role(role, account)
        }

        fn get_admin(self: @ContractState) -> ContractAddress {
            AccessControl::get_admin()
        }

        fn get_pending_admin(self: @ContractState) -> ContractAddress {
            AccessControl::get_pending_admin()
        }

        fn grant_role(ref self: ContractState, role: u128, account: ContractAddress) {
            AccessControl::grant_role(role, account);
        }

        fn revoke_role(ref self: ContractState, role: u128, account: ContractAddress) {
            AccessControl::revoke_role(role, account);
        }

        fn renounce_role(ref self: ContractState, role: u128) {
            AccessControl::renounce_role(role);
        }

        fn set_pending_admin(ref self: ContractState, new_admin: ContractAddress) {
            AccessControl::set_pending_admin(new_admin);
        }

        fn accept_admin(ref self: ContractState) {
            AccessControl::accept_admin();
        }
    }
}
