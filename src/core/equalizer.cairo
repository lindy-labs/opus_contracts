#[contract]
mod Equalizer {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::ContractAddress;

    use aura::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::storage_access_impls;
    use aura::utils::wadray::{Ray, rmul_wr, Wad};

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

    #[view]
    fn get_surplus() -> Wad {
        let shrine: IShrineDispatcher = shrine::read();
        let (_, surplus) = get_debt_and_surplus(shrine);
        surplus
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(admin: ContractAddress, shrine: ContractAddress, allocator: ContractAddress) {
        // TODO: initialize access control 
        // TODO: grant SET_ALLOCATOR role to admin

        shrine::write(IShrineDispatcher { contract_address: shrine });
        allocator::write(IAllocatorDispatcher { contract_address: allocator });
    }

    //
    // External
    //

    #[external]
    fn set_allocator(allocator: ContractAddress) {
        // TODO: AccessControl.assert_has_role(EqualizerRoles.SET_ALLOCATOR);

        let old_address: ContractAddress = allocator::read().contract_address;
        allocator::write(IAllocatorDispatcher { contract_address: allocator });

        AllocatorUpdated(old_address, allocator);
    }

    #[external]
    fn equalize() -> Wad {
        let shrine: IShrineDispatcher = shrine::read();
        let (total_debt, surplus) = get_debt_and_surplus(shrine);

        let allocator: IAllocatorDispatcher = allocator::read();
        let (recipients, percentages) = allocator.get_allocation();

        // TODO: kludge until Array<T>.len() works or Serde is implemented for Span
        let mut recipients_span: Span<ContractAddress> = recipients.span();
        let mut percentages_span: Span<Ray> = percentages.span();

        let mut minted_surplus: Wad = Wad { val: 0 };

        let mut idx: u32 = 0;
        let end_idx: u32 = recipients_span.len();
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

        // Assert yin is less than or equal to total debt after minting surplus
        // It may not be equal due to rounding errors
        let updated_total_yin: Wad = shrine.get_total_yin();
        assert(updated_total_yin <= total_debt, 'Yin exceeds debt');

        Equalize(recipients, percentages, minted_surplus);

        minted_surplus
    }

    //
    // Internal
    //

    // Returns a tuple of total debt and surplus
    fn get_debt_and_surplus(shrine: IShrineDispatcher) -> (Wad, Wad) {
        let total_debt: Wad = shrine.get_total_debt();
        let total_yin: Wad = shrine.get_total_yin();
        let surplus: Wad = total_debt - total_yin;
        (total_debt, surplus)
    }
}
