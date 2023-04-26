use array::ArrayTrait;
use starknet::ContractAddress;

use aura::utils::wadray::Ray;
use aura::utils::wadray::Wad;

#[abi]
trait IAllocator {
    fn get_allocation() -> (Array<ContractAddress>, Array<Ray>);
}

#[abi]
trait IShrine {
    fn inject(receiver: ContractAddress, amount: Wad);
    fn get_debt_and_surplus() -> (Wad, Wad);
    fn get_total_debt() -> Wad;
    fn get_total_yin() -> Wad;
}

#[contract]
mod Equalizer {
    use array::ArrayTrait;
    use array::SpanTrait;
    use starknet::ContractAddress;

    use aura::utils::wadray::Ray;
    use aura::utils::wadray::rmul_wr;
    use aura::utils::wadray::Wad;

    use super::IAllocatorDispatcher;
    use super::IAllocatorDispatcherTrait;
    use super::IShrineDispatcher;
    use super::IShrineDispatcherTrait;

    struct Storage {
        allocator: ContractAddress,
        shrine: ContractAddress,
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
        allocator::read()
    }

    #[view]
    fn get_surplus() -> Wad {
        let shrine: ContractAddress = shrine::read();
        let (_, surplus) = IShrineDispatcher { contract_address: shrine }.get_debt_and_surplus();
        surplus
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(admin: ContractAddress, shrine: ContractAddress, allocator: ContractAddress) {
        // TODO: initialize access control 
        // TODO: grant SET_ALLOCATOR role to admin

        shrine::write(shrine);
        allocator::write(allocator);
    }

    //
    // External
    //

    #[external]
    fn set_allocator(allocator: ContractAddress) {
        // TODO: AccessControl.assert_has_role(EqualizerRoles.SET_ALLOCATOR);

        let old_address: ContractAddress = allocator::read();
        allocator::write(allocator);

        AllocatorUpdated(old_address, allocator);
    }

    #[external]
    fn equalize() -> Wad {
        let shrine: ContractAddress = shrine::read();
        let (total_debt, surplus) = get_debt_and_surplus(shrine);

        let allocator: ContractAddress = allocator::read();
        let (recipients, percentages) = IAllocatorDispatcher { contract_address: allocator }.get_allocation();

        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine };

        // TODO: kludge until Array<T>.len() works or Serde is implemented for Span
        let recipients_span: Span<ContractAddress> = recipients.span();
        let percentages_span: Span<Ray> = percentages.span();

        let mut minted_surplus: Wad = Wad { val: 0 };

        let mut idx: u32 = 0;
        let end_idx: u32 = recipients_span.len();
        loop {
            if idx == end_idx {
                break ();
            }

            let amount: Wad = rmul_wr(surplus, *percentages_span[idx]);

            shrine.inject(*recipients_span[idx], amount);
            minted_surplus += amount;

            idx += 1;
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
    fn get_debt_and_surplus(shrine: ContractAddress) -> (Wad, Wad) {
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine };
        let total_debt: Wad = shrine.get_total_debt();
        let total_yin: Wad = shrine.get_total_yin();
        let surplus: Wad = total_debt - total_yin;
        (total_debt, surplus)
    }
}
