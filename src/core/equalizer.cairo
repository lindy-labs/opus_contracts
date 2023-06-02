#[contract]
mod Equalizer {
    use array::{SpanTrait};
    use option::OptionTrait;
    use starknet::ContractAddress;
    use traits::Into;
    use zeroable::Zeroable;

    use aura::core::roles::EqualizerRoles;

    use aura::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use aura::interfaces::IEqualizer::IEqualizer;
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::AccessControl;
    use aura::utils::serde::SpanSerde;
    use aura::utils::wadray::{Ray, rmul_wr, U128IntoWad, Wad, WadZeroable};

    #[starknet::storage]
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

    #[derive(Drop, starknet::Event)]
    enum Event {
        #[event]
        AllocatorUpdated: AllocatorUpdated,
        #[event]
        Equalize: Equalize,
    }

    #[derive(Drop, starknet::Event)]
    struct AllocatorUpdated {
        old_address: ContractAddress,
        new_address: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct Equalize {
        recipients: Span<ContractAddress>,
        percentages: Span<Ray>,
        amount: Wad,
    }


    //
    // Constructor
    //

    #[constructor]
    fn constructor(ref self: Storage, admin: ContractAddress, shrine: ContractAddress, allocator: ContractAddress) {
        AccessControl::initializer(admin);
        AccessControl::grant_role_internal(EqualizerRoles::default_admin_role(), admin);

        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.allocator.write(IAllocatorDispatcher { contract_address: allocator });
    }

    #[external]
    impl IEqualizerImpl of IEqualizer<Storage> {
        //
        // Getters
        //

        fn get_allocator(self: @Storage) -> ContractAddress {
            self.allocator.read().contract_address
        }

        // Returns the amount of surplus debt that can be minted
        fn get_surplus(self: @Storage) -> Wad {
            let (_, surplus) = self.get_debt_and_surplus(self.shrine.read());
            surplus
        }

        //
        // External
        //

        // Update the Allocator's address
        fn set_allocator(ref self: Storage, allocator: ContractAddress) {
            AccessControl::assert_has_role(EqualizerRoles::SET_ALLOCATOR);

            let old_address: ContractAddress = self.allocator.read().contract_address;
            self.allocator.write(IAllocatorDispatcher { contract_address: allocator });

            self.emit(Event::AllocatorUpdated(AllocatorUpdated { old_address, new_address: allocator }));
        }

        // Mint surplus debt to the recipients in the allocation retrieved from the Allocator
        // according to their respective percentage share.
        // Assumes the allocation from the Allocator has already been checked:
        // - both arrays of recipient addresses and percentages are of equal length;
        // - there is at least one recipient;
        // - the percentages add up to one Ray.
        // Returns the total amount of surplus debt minted.
        #[external]
        fn equalize(ref self: Storage) -> Wad {
            let shrine: IShrineDispatcher = self.shrine.read();
            let (total_debt, surplus) = self.get_debt_and_surplus(shrine);

            if surplus.is_zero() {
                return 0_u128.into();
            }

            let allocator: IAllocatorDispatcher = self.allocator.read();
            let (mut recipients, mut percentages) = allocator.get_allocation();

            let mut minted_surplus: Wad = WadZeroable::zero();

            loop {
                match recipients.pop_front() {
                    Option::Some(recipient) => {
                        let amount: Wad = rmul_wr(surplus, *(percentages.pop_front().unwrap()));

                        shrine.inject(*recipient, amount);
                        minted_surplus += amount;
                    },
                    Option::None(_) => {
                        break;
                    }
                };
            };

            // Safety check to assert yin is less than or equal to total debt after minting surplus
            // It may not be equal due to rounding errors
            let updated_total_yin: Wad = shrine.get_total_yin();
            assert(updated_total_yin <= total_debt, 'Yin exceeds debt');

            self.emit(Event::Equalize(Equalize { recipients, percentages, amount: minted_surplus }));

            minted_surplus
        }
    }

    #[generate_trait]
    impl StorageImpl of StorageTrait {
        //
        // Internal
        //

        // Helper function to return a tuple of the Shrine's total debt and the surplus
        // calculated based on the Shrine's total debt and the total minted yin.
        #[inline(always)]
        fn get_debt_and_surplus(self: @Storage, shrine: IShrineDispatcher) -> (Wad, Wad) {
            let total_debt: Wad = shrine.get_total_debt();
            let surplus: Wad = total_debt - shrine.get_total_yin();
            (total_debt, surplus)
        }
    }
}
