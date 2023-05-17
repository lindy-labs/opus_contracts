#[contract]
mod Abbot {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::{ContractAddress, get_caller_address};
    use zeroable::Zeroable;

    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::utils::reentrancy_guard::ReentrancyGuard;
    use aura::utils::serde;
    use aura::utils::wadray::{Wad};

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
        // up to `user_trove_count` for that address
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

    #[event]
    fn TroveOpened(user: ContractAddress, trove_id: u64) {}

    #[event]
    fn TroveClosed(trove_id: u64) {}

    //
    // Constructor
    //

    #[constructor]
    fn constructor(shrine: ContractAddress, sentinel: ContractAddress) {
        shrine::write(IShrineDispatcher { contract_address: shrine });
        sentinel::write(ISentinelDispatcher { contract_address: sentinel });
    }

    //
    // View functions
    //

    #[view]
    fn get_trove_owner(trove_id: u64) -> ContractAddress {
        trove_owner::read(trove_id)
    }

    #[view]
    fn get_user_trove_ids(user: ContractAddress) -> Span<u64> {
        let mut trove_ids: Array<u64> = ArrayTrait::new();
        let user_troves_count = user_troves_count::read(user);
        let mut idx = 0;

        loop {
            if idx == user_troves_count {
                break trove_ids.span();
            }
            trove_ids.append(user_troves::read((user, idx)));
            idx += 1;
        }
    }

    #[view]
    fn get_troves_count() -> u64 {
        troves_count::read()
    }

    //
    // External functions
    //

    // create a new trove in the system with Yang deposits, 
    // optionally forging Yin in the same operation (if forge_amount is 0, no Yin is created)
    #[external]
    fn open_trove(forge_amount: Wad, mut yangs: Span<ContractAddress>, mut amounts: Span<u128>) {
        assert(yangs.len() != 0_usize, 'no yangs');
        assert(yangs.len() == amounts.len(), 'arrays of different length');

        let troves_count = troves_count::read();
        troves_count::write(troves_count + 1);

        let user = get_caller_address();
        let user_troves_count = user_troves_count::read(user);
        user_troves_count::write(user, user_troves_count + 1);

        let new_trove_id = troves_count + 1;
        user_troves::write((user, user_troves_count), new_trove_id);
        trove_owner::write(new_trove_id, user);

        // deposit all requested Yangs into the system
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let amount = amounts.pop_front().unwrap();
                    deposit_internal(*yang, user, new_trove_id, *amount);
                },
                Option::None(_) => {
                    break ();
                }
            };
        };

        // forge Yin
        shrine::read().forge(user, new_trove_id, forge_amount);

        TroveOpened(user, new_trove_id);
    }

    // close a trove, repaying its debt in full and withdrawing all the Yangs
    #[external]
    fn close_trove(trove_id: u64) {
        let user = get_caller_address();
        assert_trove_owner(user, trove_id);

        let shrine = shrine::read();
        // melting "max Wad" to instruct Shrine to melt *all* of trove's debt
        shrine.melt(user, trove_id, Wad { val: integer::BoundedInt::max() });

        let sentinel = sentinel::read();
        let yang_addresses_count = sentinel.get_yang_addresses_count();

        let mut idx = 0;
        // withdraw each and every Yang belonging to the trove from the system
        loop {
            if idx == yang_addresses_count {
                break ();
            }

            let yang = sentinel.get_yang(idx);
            let yang_amount = shrine.get_deposit(yang, trove_id);

            // increment index counter now to account for the `continue` below
            idx += 1;

            if yang_amount.is_zero() {
                continue;
            }

            withdraw_internal(yang, user, trove_id, yang_amount);
        };

        TroveClosed(trove_id);
    }

    #[external]
    fn deposit(yang: ContractAddress, trove_id: u64, amount: u128) {
        assert(yang.is_non_zero(), 'yang address cannot be zero');
        assert(trove_id != 0, 'trove ID cannot be zero');
        assert(trove_id <= troves_count::read(), 'non-existing trove');
        // note that caller does not need to be the trove's owner to deposit

        deposit_internal(yang, get_caller_address(), trove_id, amount);
    }

    #[external]
    fn withdraw(yang: ContractAddress, trove_id: u64, amount: Wad) {
        assert(yang.is_non_zero(), 'yang address cannot be zero');
        let user = get_caller_address();
        assert_trove_owner(user, trove_id);

        withdraw_internal(yang, user, trove_id, amount);
    }

    #[external]
    fn forge(trove_id: u64, amount: Wad) {
        let user = get_caller_address();
        assert_trove_owner(user, trove_id);
        shrine::read().forge(user, trove_id, amount);
    }

    #[external]
    fn melt(trove_id: u64, amount: Wad) {
        // note that caller does not need to be the trove's owner to melt
        shrine::read().melt(get_caller_address(), trove_id, amount);
    }

    //
    // Internal functions
    //

    #[inline(always)]
    fn assert_trove_owner(user: ContractAddress, trove_id: u64) {
        assert(user == trove_owner::read(trove_id), 'not trove owner')
    }

    #[inline(always)]
    fn deposit_internal(yang: ContractAddress, user: ContractAddress, trove_id: u64, amount: u128) {
        ReentrancyGuard::start();

        let yang_amount = sentinel::read().enter(yang, user, trove_id, amount);
        shrine::read().deposit(yang, trove_id, yang_amount);

        ReentrancyGuard::end();
    }

    #[inline(always)]
    fn withdraw_internal(yang: ContractAddress, user: ContractAddress, trove_id: u64, amount: Wad) {
        ReentrancyGuard::start();

        shrine::read().withdraw(yang, trove_id, amount);
        sentinel::read().exit(yang, user, trove_id, amount);

        ReentrancyGuard::end();
    }
}
