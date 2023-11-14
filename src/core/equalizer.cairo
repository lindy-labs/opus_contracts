#[starknet::contract]
mod equalizer {
    use opus::core::roles::equalizer_roles;
    use opus::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use opus::interfaces::IEqualizer::IEqualizer;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::types::Health;
    use opus::utils::access_control::access_control_component;
    use opus::utils::wadray::{Ray, Wad, WadZeroable};
    use opus::utils::wadray;
    use starknet::ContractAddress;

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic =
        access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
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
        AccessControlEvent: access_control_component::Event,
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
        self.access_control.initializer(admin, Option::Some(equalizer_roles::default_admin_role()));

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
            self.access_control.assert_has_role(equalizer_roles::SET_ALLOCATOR);

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

            minted_surplus
        }
    }

    //
    // Internal functions for Equalizer that do not access Equalizer's storage
    //

    // Helper function to return a tuple of the Shrine's total debt and the surplus
    // calculated based on the Shrine's total debt and the total minted yin.
    #[inline(always)]
    fn get_debt_and_surplus(shrine: IShrineDispatcher) -> (Wad, Wad) {
        let shrine_health: Health = shrine.get_shrine_info();
        let surplus: Wad = shrine_health.debt - shrine.get_total_yin();
        (shrine_health.debt, surplus)
    }
}
