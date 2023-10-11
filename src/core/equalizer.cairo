#[starknet::contract]
mod Equalizer {
    use cmp::min;
    use starknet::{ContractAddress, get_caller_address};

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
        // amount of deficit debt at the current on-chain conditions
        deficit: Wad
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AllocatorUpdated: AllocatorUpdated,
        Equalize: Equalize,
        Incur: Incur,
        Normalize: Normalize
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

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Incur {
        #[key]
        defaulter: ContractAddress,
        deficit: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Normalize {
        yin_amt: Wad
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

        // Returns the amount of surplus debt that can be minted
        fn get_surplus(self: @ContractState) -> Wad {
            let (_, surplus) = get_debt_and_surplus(self.shrine.read());
            surplus
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
            let (total_debt, surplus) = get_debt_and_surplus(shrine);

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

            // Safety check to assert yin is less than or equal to total debt after minting surplus
            // It may not be equal due to rounding errors
            let updated_total_yin: Wad = shrine.get_total_yin();
            assert(updated_total_yin <= total_debt, 'EQ: Yin exceeds debt');

            self.emit(Equalize { recipients, percentages, amount: minted_surplus });

            // TODO: loop over equalizer's balance and transfer to recipients

            minted_surplus
        }

        // Incur a debt deficit
        fn incur(ref self: ContractState, yin_amt: Wad) {
            AccessControl::assert_has_role(EqualizerRoles::INCUR);

            self.deficit.write(self.deficit.read() + yin_amt);

            self.emit(Incur { defaulter: get_caller_address(), deficit: yin_amt });
        }

        // Burn yin from the caller's balance to wipe off any debt deficit.
        // Anyone can call this function.
        fn normalize(ref self: ContractState, yin_amt: Wad) {
            let shrine: IShrineDispatcher = self.shrine.read();
            let caller: ContractAddress = get_caller_address();

            let balance: Wad = shrine.get_yin(caller);
            let deficit: Wad = self.deficit.read();
            let offset: Wad = min(balance, deficit);

            if offset.is_non_zero() {
                shrine.eject(caller, offset);
                self.emit(Normalize { yin_amt: offset });
            }
        }
    }

    //
    // Internal functions for Equalizer that do not access Equalizer's storage
    //

    // Helper function to return a tuple of the Shrine's total debt and the surplus
    // calculated based on the Shrine's total debt and the total minted yin.
    #[inline(always)]
    fn get_debt_and_surplus(shrine: IShrineDispatcher) -> (Wad, Wad) {
        let total_debt: Wad = shrine.get_total_debt();
        let surplus: Wad = total_debt - shrine.get_total_yin();
        (total_debt, surplus)
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
