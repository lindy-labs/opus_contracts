use aura::utils::wadray::Wad;

#[abi]
trait IShrine {
    fn get_total_debt() -> Wad;
    fn get_total_yin() -> Wad;
}

#[contract]
mod Equalizer {
    use starknet::ContractAddress;

    use aura::utils::wadray::Wad

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

    //
    // Getters
    //

    #[view]
    fn get_allocator() -> ContractAddress {
        allocator::read
    }

    #[view]
    fn get_surplus() -> Wad {}

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
    }
    
    //
    // Internal
    //

    fn get_debt_and_surplus(shrine: ContractAddress) {

    }
}
