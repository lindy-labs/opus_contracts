#[starknet::contract]
mod equalizer {
    use cmp::min;
    use starknet::{ContractAddress, get_caller_address, get_contract_address};

    use opus::core::roles::equalizer_roles;

    use opus::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use opus::interfaces::IEqualizer::IEqualizer;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::utils::access_control::access_control_component;
    use opus::utils::wadray;
    use opus::utils::wadray::{Ray, Wad, WadZeroable};

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
        // amount of deficit debt at the current on-chain conditions
        deficit: Wad,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AccessControlEvent: access_control_component::Event,
        Allocate: Allocate,
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
        yin_amt: Wad
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

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Allocate {
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

        // Mint surplus debt to the Equalizer.
        // Returns the amount of surplus debt minted.
        fn equalize(ref self: ContractState) -> Wad {
            let shrine: IShrineDispatcher = self.shrine.read();

            let surplus: Wad = shrine.get_surplus_debt();

            if surplus.is_zero() {
                return WadZeroable::zero();
            }

            shrine.inject(get_contract_address(), surplus);
            shrine.reduce_surplus_debt(surplus);

            self.emit(Equalize { yin_amt: surplus });

            surplus
        }

        // Allocate the yin balance of the Equalizer to the recipients in the allocation 
        // retrieved from the Allocator according to their respective percentage share.
        // Assumes the allocation from the Allocator has already been checked:
        // - both arrays of recipient addresses and percentages are of equal length;
        // - there is at least one recipient;
        // - the percentages add up to one Ray.
        fn allocate(ref self: ContractState) {
            let shrine: IShrineDispatcher = self.shrine.read();
            let allocator: IAllocatorDispatcher = self.allocator.read();
            let (recipients, percentages) = allocator.get_allocation();

            // Loop over equalizer's balance and transfer to recipients
            let yin = IERC20Dispatcher { contract_address: shrine.contract_address };
            let balance: Wad = shrine.get_yin(get_contract_address());
            let mut amount_allocated: Wad = WadZeroable::zero();

            let mut recipients_copy = recipients;
            let mut percentages_copy = percentages;
            loop {
                match recipients_copy.pop_front() {
                    Option::Some(recipient) => {
                        let amount: Wad = wadray::rmul_wr(
                            balance, *(percentages_copy.pop_front().unwrap())
                        );

                        yin.transfer(*recipient, amount.into());
                        amount_allocated += amount;
                    },
                    Option::None => { break; }
                };
            };

            self.emit(Allocate { recipients, percentages, amount: amount_allocated });
        }

        // Incur a debt deficit
        fn incur(ref self: ContractState, yin_amt: Wad) {
            self.access_control.assert_has_role(equalizer_roles::INCUR);

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
}
