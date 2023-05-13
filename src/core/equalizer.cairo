#[contract]
mod Equalizer {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::ContractAddress;

    use aura::core::roles::EqualizerRoles;

    use aura::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::AccessControl;
    use aura::utils::storage_access_impls;
    use aura::utils::wadray::{Ray, rmul_wr, Wad, WadZeroable};

    struct Storage {
        allocator: IAllocatorDispatcher,
        shrine: IShrineDispatcher,
    }

    //
    // Events
    //

    #[event]
    fn AllocatorUpdated(old_address: ContractAddress, new_address: ContractAddress) {}

    #[event]
    fn Equalize(recipients: Array<ContractAddress>, percentages: Array<Ray>, amount: Wad) {}

    //
    // Getters
    //

    #[view]
    fn get_allocator() -> ContractAddress {
        allocator::read().contract_address
    }

    // Returns the amount of surplus debt that can be minted
    #[view]
    fn get_surplus() -> Wad {
        let (_, surplus) = get_debt_and_surplus(shrine::read().contract_address);
        surplus
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(admin: ContractAddress, shrine: ContractAddress, allocator: ContractAddress) {
        AccessControl::initializer(admin);
        AccessControl._grant_role(EqualizerRoles::default_admin_role(), admin);

        shrine::write(IShrineDispatcher { contract_address: shrine });
        allocator::write(IAllocatorDispatcher { contract_address: allocator });
    }

    //
    // External
    //

    // Update the Allocator's address
    #[external]
    fn set_allocator(allocator: ContractAddress) {
        AccessControl::assert_has_role(EqualizerRoles.SET_ALLOCATOR);

        let old_address: ContractAddress = allocator::read().contract_address;
        allocator::write(IAllocatorDispatcher { contract_address: allocator });

        AllocatorUpdated(old_address, allocator);
    }

    // Mint surplus debt to the recipients in the allocation retrieved from the Allocator
    // according to their respective percentage share.
    // Assumes the allocation from the Allocator has already been checked:
    // - both arrays of recipient addresses and percentages are of equal length;
    // - there is at least one recipient;
    // - the percentages add up to one Ray.
    // Returns the total amount of surplus debt minted.
    #[external]
    fn equalize() -> Wad {
        let shrine: IShrineDispatcher = shrine::read();
        let (total_debt, surplus) = get_debt_and_surplus(shrine);

        let (recipients, percentages) = allocator::read().get_allocation();

        let mut recipients_span: Span<ContractAddress> = recipients.span();
        let mut percentages_span: Span<Ray> = percentages.span();
        let mut minted_surplus: Wad = Wad::zero();

        loop {
            match (recipients_span.pop_front()) {
                Option::Some(recipient) => {
                    let amount: Wad = rmul_wr(surplus, *(percentages_span.pop_front().unwrap()));

                    shrine.inject(*recipient, amount);
                    minted_surplus += amount;
                },
                Option::None(_) => {
                    break ();
                }
            };
        };

        // Safety check to assert yin is less than or equal to total debt after minting surplus
        // It may not be equal due to rounding errors
        let updated_total_yin: Wad = shrine.get_total_yin();
        assert(updated_total_yin <= total_debt, 'Yin exceeds debt');

        Equalize(recipients, percentages, minted_surplus);

        minted_surplus
    }

    //
    // Internal
    //

    // Helper function to return a tuple of the Shrine's total debt and the surplus
    // calculated based on the Shrine's total debt and the total minted yin.
    fn get_debt_and_surplus(shrine: IShrineDispatcher) -> (Wad, Wad) {
        let total_debt: Wad = shrine.get_total_debt();
        let surplus: Wad = total_debt - shrine.get_total_yin();
        (total_debt, surplus)
    }
}
