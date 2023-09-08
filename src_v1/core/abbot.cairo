#[contract]
mod Abbot {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::{ContractAddress, get_caller_address};
    use traits::{Default, Into};
    use zeroable::Zeroable;

    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::reentrancy_guard::ReentrancyGuard;
    use aura::utils::serde;
    use aura::utils::types::AssetBalance;
    use aura::utils::wadray::{BoundedWad, Wad};

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
        let mut trove_ids: Array<u64> = Default::default();
        let user_troves_count: u64 = user_troves_count::read(user);
        let mut idx: u64 = 0;

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
    // optionally forging Yin in the same operation (if `forge_amount` is 0, no Yin is created)
    #[external]
    fn open_trove(
        mut yang_assets: Span<AssetBalance>, forge_amount: Wad, max_forge_fee_pct: Wad
    ) -> u64 {
        assert(yang_assets.len().is_non_zero(), 'ABB: No yangs');

        let troves_count: u64 = troves_count::read();
        troves_count::write(troves_count + 1);

        let user = get_caller_address();
        let user_troves_count: u64 = user_troves_count::read(user);
        user_troves_count::write(user, user_troves_count + 1);

        let new_trove_id: u64 = troves_count + 1;
        user_troves::write((user, user_troves_count), new_trove_id);
        trove_owner::write(new_trove_id, user);

        // deposit all requested Yangs into the system
        loop {
            match yang_assets.pop_front() {
                Option::Some(yang_asset) => {
                    deposit_internal(new_trove_id, user, *yang_asset);
                },
                Option::None(_) => {
                    break;
                }
            };
        };

        // forge Yin
        shrine::read().forge(user, new_trove_id, forge_amount, max_forge_fee_pct);

        TroveOpened(user, new_trove_id);

        new_trove_id
    }

    // close a trove, repaying its debt in full and withdrawing all the Yangs
    #[external]
    fn close_trove(trove_id: u64) {
        let user = get_caller_address();
        assert_trove_owner(user, trove_id);

        let shrine = shrine::read();
        // melting "max Wad" to instruct Shrine to melt *all* of trove's debt
        shrine.melt(user, trove_id, BoundedWad::max());

        let mut yangs: Span<ContractAddress> = sentinel::read().get_yang_addresses();
        // withdraw each and every Yang belonging to the trove from the system
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let yang_amount: Wad = shrine.get_deposit(*yang, trove_id);
                    if yang_amount.is_zero() {
                        continue;
                    }
                    withdraw_internal(trove_id, user, *yang, yang_amount);
                },
                Option::None(_) => {
                    break;
                }
            };
        };

        TroveClosed(trove_id);
    }

    // add Yang (an asset) to a trove
    #[external]
    fn deposit(trove_id: u64, yang_asset: AssetBalance) {
        // There is no need to check the yang address is non-zero because the
        // Sentinel does not allow a zero address yang to be added.

        assert(trove_id != 0, 'ABB: Trove ID cannot be 0');
        assert(trove_id <= troves_count::read(), 'ABB: Non-existent trove');
        // note that caller does not need to be the trove's owner to deposit

        deposit_internal(trove_id, get_caller_address(), yang_asset);
    }

    // remove Yang (an asset) from a trove
    #[external]
    fn withdraw(trove_id: u64, yang_asset: AssetBalance) {
        // There is no need to check the yang address is non-zero because the
        // Sentinel does not allow a zero address yang to be added.

        let user = get_caller_address();
        assert_trove_owner(user, trove_id);

        let yang_amt: Wad = sentinel::read().convert_to_yang(yang_asset.address, yang_asset.amount);
        withdraw_internal(trove_id, user, yang_asset.address, yang_amt);
    }

    // create Yin in a trove
    #[external]
    fn forge(trove_id: u64, amount: Wad, max_forge_fee_pct: Wad) {
        let user = get_caller_address();
        assert_trove_owner(user, trove_id);
        shrine::read().forge(user, trove_id, amount, max_forge_fee_pct);
    }

    // destroy Yin from a trove
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
        assert(user == trove_owner::read(trove_id), 'ABB: Not trove owner')
    }

    #[inline(always)]
    fn deposit_internal(trove_id: u64, user: ContractAddress, yang_asset: AssetBalance) {
        // reentrancy guard is used as a precaution
        ReentrancyGuard::start();

        let yang_amt: Wad = sentinel::read()
            .enter(yang_asset.address, user, trove_id, yang_asset.amount);
        shrine::read().deposit(yang_asset.address, trove_id, yang_amt);

        ReentrancyGuard::end();
    }

    #[inline(always)]
    fn withdraw_internal(
        trove_id: u64, user: ContractAddress, yang: ContractAddress, yang_amt: Wad
    ) {
        // reentrancy guard is used as a precaution
        ReentrancyGuard::start();

        sentinel::read().exit(yang, user, trove_id, yang_amt);
        shrine::read().withdraw(yang, trove_id, yang_amt);

        ReentrancyGuard::end();
    }
}
