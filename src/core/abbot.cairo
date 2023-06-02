#[contract]
mod Abbot {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::{ContractAddress, get_caller_address};
    use traits::{Default, Into};
    use zeroable::Zeroable;

    use aura::interfaces::IAbbot::IAbbot;
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::reentrancy_guard::ReentrancyGuard;
    use aura::utils::serde;
    use aura::utils::wadray::{Wad, U128IntoWad};

    #[starknet::storage]
    struct Storage {
        // Shrine associated with this Abbot
        shrine: IShrineDispatcher,
        // Sentinel associated with this Abbot
        sentinel: ISentinelDispatcher,
        // total number of troves in a Shrine; monotonically increasing
        // also used to calculate the next ID (count+1) when opening a new trove
        // in essence, it serves as an index / primary key in a SQL table
        troves_count: u64,
        // the total number of troves of a particular address;
        // used to build the tuple key of `user_troves` variable
        // (user) -> (number of troves opened)
        user_troves_count: LegacyMap<ContractAddress, u64>,
        // a mapping of an address and index to a trove ID
        // belonging to this address; the index is a number from 0
        // up to `user_troves_count` for that address
        // (user, idx) -> (trove ID)
        user_troves: LegacyMap<(ContractAddress, u64), u64>,
        // a mapping of a trove ID to the contract address which
        // was used to open the trove
        // (trove ID) -> (owner)
        trove_owner: LegacyMap<u64, ContractAddress>,
    }

    //
    // Events
    //

    #[derive(Drop, starknet::Event)]
    enum Event {
        #[event]
        TroveOpened: TroveOpened,
        #[event]
        TroveClosed: TroveClosed,
    }

    #[derive(Drop, starknet::Event)]
    struct TroveOpened {
        user: ContractAddress,
        new_trove_id: u64,
    }
    #[derive(Drop, starknet::Event)]
    struct TroveClosed {
        trove_id: u64
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(ref self: Storage, shrine: ContractAddress, sentinel: ContractAddress) {
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
    }


    impl IAbbotImpl of IAbbot<Storage> {
        //
        // View functions
        //

        fn get_trove_owner(self: @Storage, trove_id: u64) -> ContractAddress {
            self.trove_owner.read(trove_id)
        }

        fn get_user_trove_ids(self: @Storage, user: ContractAddress) -> Span<u64> {
            let mut trove_ids: Array<u64> = Default::default();
            let user_troves_count: u64 = self.user_troves_count.read(user);
            let mut idx: u64 = 0;

            loop {
                if idx == user_troves_count {
                    break trove_ids.span();
                }
                trove_ids.append(self.user_troves.read((user, idx)));
                idx += 1;
            }
        }

        fn get_troves_count(self: @Storage, ) -> u64 {
            self.troves_count.read()
        }

        //
        // External functions
        //

        // create a new trove in the system with Yang deposits, 
        // optionally forging Yin in the same operation (if `forge_amount` is 0, no Yin is created)
        // `amounts` are denominated in asset's decimals
        fn open_trove(
            ref self: Storage,
            forge_amount: Wad,
            mut yangs: Span<ContractAddress>,
            mut amounts: Span<u128>
        ) {
            assert(yangs.len() != 0_usize, 'no yangs');
            assert(yangs.len() == amounts.len(), 'arrays of different length');

            let troves_count: u64 = self.troves_count.read();
            self.troves_count.write(troves_count + 1);

            let user = get_caller_address();
            let user_troves_count: u64 = self.user_troves_count.read(user);
            self.user_troves_count.write(user, user_troves_count + 1);

            let new_trove_id: u64 = troves_count + 1;
            self.user_troves.write((user, user_troves_count), new_trove_id);
            self.trove_owner.write(new_trove_id, user);

            // deposit all requested Yangs into the system
            loop {
                match yangs.pop_front() {
                    Option::Some(yang) => {
                        let amount: u128 = *amounts.pop_front().unwrap();
                        self.deposit_internal(*yang, user, new_trove_id, amount);
                    },
                    Option::None(_) => {
                        break;
                    }
                };
            };

            // forge Yin
            self.shrine.read().forge(user, new_trove_id, forge_amount);

            self.emit(Event::TroveOpened(TroveOpened{user, new_trove_id}));
        }

        // close a trove, repaying its debt in full and withdrawing all the Yangs
        fn close_trove(ref self: Storage, trove_id: u64) {
            let user = get_caller_address();
            self.assert_trove_owner(user, trove_id);

            let shrine = self.shrine.read();
            // melting "max Wad" to instruct Shrine to melt *all* of trove's debt
            shrine.melt(user, trove_id, integer::BoundedU128::max().into());

            let mut yangs: Span<ContractAddress> = self.sentinel.read().get_yang_addresses();
            // withdraw each and every Yang belonging to the trove from the system
            loop {
                match yangs.pop_front() {
                    Option::Some(yang) => {
                        let yang_amount: Wad = shrine.get_deposit(*yang, trove_id);
                        if yang_amount.is_zero() {
                            continue;
                        }
                        self.withdraw_internal(*yang, user, trove_id, yang_amount);
                    },
                    Option::None(_) => {
                        break;
                    }
                };
            };

            self.emit(Event::TroveClosed(TroveClosed{trove_id}));
        }

        // add Yang (an asset) to a trove; `amount` is denominated in asset's decimals
        fn deposit(ref self: Storage, yang: ContractAddress, trove_id: u64, amount: u128) {
            assert(yang.is_non_zero(), 'yang address cannot be zero');
            assert(trove_id != 0, 'trove ID cannot be zero');
            assert(trove_id <= self.troves_count.read(), 'non-existing trove');
            // note that caller does not need to be the trove's owner to deposit

            self.deposit_internal(yang, get_caller_address(), trove_id, amount);
        }

        // remove Yang (an asset) from a trove; `amount` is denominated in WAD_DECIMALS
        fn withdraw(ref self: Storage, yang: ContractAddress, trove_id: u64, amount: Wad) {
            assert(yang.is_non_zero(), 'yang address cannot be zero');
            let user = get_caller_address();
            self.assert_trove_owner(user, trove_id);

            self.withdraw_internal(yang, user, trove_id, amount);
        }

        // create Yin in a trove; `amount` is denominated in WAD_DECIMALS
        fn forge(ref self: Storage, trove_id: u64, amount: Wad) {
            let user = get_caller_address();
            self.assert_trove_owner(user, trove_id);
            self.shrine.read().forge(user, trove_id, amount);
        }

        // destroy Yin from a trove; `amount` is denominated in WAD_DECIMALS
        fn melt(ref self: Storage, trove_id: u64, amount: Wad) {
            // note that caller does not need to be the trove's owner to melt
            self.shrine.read().melt(get_caller_address(), trove_id, amount);
        }
    }

    #[generate_trait]
    impl StorageImpl of StorageTrait {
        //
        // Internal functions
        //

        #[inline(always)]
        fn assert_trove_owner(self: @Storage, user: ContractAddress, trove_id: u64) {
            assert(user == self.trove_owner.read(trove_id), 'not trove owner')
        }

        #[inline(always)]
        fn deposit_internal(
            ref self: Storage,
            yang: ContractAddress,
            user: ContractAddress,
            trove_id: u64,
            amount: u128
        ) {
            // reentrancy guard is used as a precaution
            ReentrancyGuard::start();

            let yang_amount: Wad = self.sentinel.read().enter(yang, user, trove_id, amount);
            self.shrine.read().deposit(yang, trove_id, yang_amount);

            ReentrancyGuard::end();
        }

        #[inline(always)]
        fn withdraw_internal(
            ref self: Storage,
            yang: ContractAddress,
            user: ContractAddress,
            trove_id: u64,
            amount: Wad
        ) {
            // reentrancy guard is used as a precaution
            ReentrancyGuard::start();

            self.sentinel.read().exit(yang, user, trove_id, amount);
            self.shrine.read().withdraw(yang, trove_id, amount);

            ReentrancyGuard::end();
        }
    }
}
