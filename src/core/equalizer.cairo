#[starknet::contract]
mod Equalizer {
    use starknet::ContractAddress;

    use opus::core::roles::EqualizerRoles;

    use opus::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use opus::interfaces::IEqualizer::IEqualizer;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::utils::access_control::{AccessControl, IAccessControl};
    use opus::utils::wadray;
    use opus::utils::wadray::{Ray, Wad, WadZeroable};

    #[storage]
    struct Storage {
        // the Allocator to read the current allocation of recipients of any minted
        // surplus debt, and their respective percentages
        allocator: IAllocatorDispatcher,
        // the Shrine that this Equalizer mints surplus debt for
        shrine: IShrineDispatcher,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AllocatorUpdated: AllocatorUpdated,
        Equalize: Equalize,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct AllocatorUpdated {
        old_address: ContractAddress,
        new_address: ContractAddress
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Equalize {
        recipients: Span<ContractAddress>,
        percentages: Span<Ray>,
        amount: Wad
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        shrine: ContractAddress,
        allocator: ContractAddress
    ) {
        AccessControl::initializer(admin, Option::Some(EqualizerRoles::default_admin_role()));

        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.allocator.write(IAllocatorDispatcher { contract_address: allocator });
    }

    //
    // External Equalizer functions
    //

    #[external(v0)]
    impl IEqualizerImpl of IEqualizer<ContractState> {
        //
        // Getters
        //

        fn get_allocator(self: @ContractState) -> ContractAddress {
            self.allocator.read().contract_address
        }

        //
        // Setters
        //

        // Update the Allocator's address
        fn set_allocator(ref self: ContractState, allocator: ContractAddress) {
            AccessControl::assert_has_role(EqualizerRoles::SET_ALLOCATOR);

            let old_address: ContractAddress = self.allocator.read().contract_address;
            self.allocator.write(IAllocatorDispatcher { contract_address: allocator });

            self.emit(AllocatorUpdated { old_address, new_address: allocator });
        }

        //
        // Core functions - External
        //

        // Mint surplus debt to the recipients in the allocation retrieved from the Allocator
        // according to their respective percentage share.
        // Assumes the allocation from the Allocator has already been checked:
        // - both arrays of recipient addresses and percentages are of equal length;
        // - there is at least one recipient;
        // - the percentages add up to one Ray.
        // Returns the total amount of surplus debt minted.
        fn equalize(ref self: ContractState) -> Wad {
            let shrine: IShrineDispatcher = self.shrine.read();

            let surplus: Wad = shrine.get_surplus_debt();

            if surplus.is_zero() {
                return WadZeroable::zero();
            }

            let allocator: IAllocatorDispatcher = self.allocator.read();
            let (recipients, percentages) = allocator.get_allocation();

            let mut minted_surplus: Wad = WadZeroable::zero();

            let mut recipients_copy = recipients;
            let mut percentages_copy = percentages;
            loop {
                match recipients_copy.pop_front() {
                    Option::Some(recipient) => {
                        let amount: Wad = wadray::rmul_wr(
                            surplus, *(percentages_copy.pop_front().unwrap())
                        );

                        shrine.inject(*recipient, amount);
                        minted_surplus += amount;
                    },
                    Option::None => { break; }
                };
            };

            shrine.reduce_surplus_debt(minted_surplus);

            self.emit(Equalize { recipients, percentages, amount: minted_surplus });

            minted_surplus
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
