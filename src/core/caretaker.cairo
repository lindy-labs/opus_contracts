use starknet::ContractAddress;

use aura::utils::wadray::{Wad};


#[abi]
trait IEqualizer {
    fn equalize();
}

// TODO: remove `trove_id` from Sentinel and Gate for `enter` and `exit`
//       it is only used for emitting events, but it will block `redeem` 
//       because there is no trove ID
#[abi]
trait ISentinel {
    fn enter(yang: ContractAddress, user: ContractAddress, asset_amt: u128) -> Wad;
    fn exit(yang: ContractAddress, user: ContractAddress, yang_amt: Wad) -> u128;
    fn get_yang_addresses() -> Array<ContractAddress>;
    fn preview_exit(yang: ContractAddress, yang_amt: Wad) -> u128;
}

#[contract]
mod Caretaker {
    use array::{ArrayTrait, SpanTrait};
    use cmp::min;
    use option::OptionTrait;
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};

    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::storage_access_impls;
    use aura::utils::wadray::{Ray, rdiv_ww, rmul_rw, Wad};

    use super::{
        IEqualizerDispatcher, IEqualizerDispatcherTrait, ISentinelDispatcher,
        ISentinelDispatcherTrait
    };

    struct Storage {
        equalizer: IEqualizerDispatcher,
        sentinel: ISentinelDispatcher,
        shrine: IShrineDispatcher,
        // Final price of yangs
        // (yang_address) -> (Wad)
        yang_prices: LegacyMap::<ContractAddress, Wad>,
        // Start time for users to burn CASH and redeem collateral.
        // Trove owners can withdraw excess collateral between time 
        // of `terminate` and `redemption_start_time`.
        redemption_start_time: u64,
    }

    #[constructor]
    fn constructor(shrine: ContractAddress, sentinel: ContractAddress, equalizer: ContractAddress) {
        shrine::write(IShrineDispatcher { contract_address: shrine });
        sentinel::write(ISentinelDispatcher { contract_address: sentinel });
        equalizer::write(IEqualizerDispatcher { contract_address: equalizer });
    }

    #[external]
    fn terminate(delay: u64) {
        // AccessControl.assert_has_role(TerminatorRoles.TERMINATE);

        let shrine: IShrineDispatcher = shrine::read();

        // Loop through yangs and write last price to this contract's storage
        let sentinel: ISentinelDispatcher = sentinel::read();
        let yangs: Array<ContractAddress> = sentinel.get_yang_addresses();
        let mut yangs_span = yangs.span();

        loop {
            match (yangs_span.pop_front()) {
                Option::Some(yang) => {
                    let (yang_price, _, _) = shrine.get_current_yang_price(*yang);
                    yang_prices::write(*yang, yang_price);
                },
                Option::None(_) => {
                    break ();
                },
            };
        };

        // Mint surplus debt
        let equalizer: IEqualizerDispatcher = equalizer::read();
        equalizer.equalize();

        // Kill Shrine
        shrine.kill();

        // TODO: impose lower and upper limit on `delay`?
        redemption_start_time::write(get_block_timestamp() + delay);
    // TODO: add event
    }

    // Allow yin holders to burn their yin and receive their proportionate share
    // of collateral based on the amount of yin as a proportion of total supply
    // Note that `redeem` will not change the amount of the yang in Shrine. This does
    // not affect the calculation because the drop in the asset amount per yang is 
    // compensated by the increase in the user's proportion of total remaining yin supply.
    #[external]
    fn redeem(yin: Wad) {
        let caller: ContractAddress = get_caller_address();
        let shrine: IShrineDispatcher = shrine::read();

        let user_bal: Wad = shrine.get_yin(caller);
        let burn_amt: Wad = min(yin, user_bal);

        let total_debt: Wad = shrine.get_total_debt();
        let pct_to_redeem: Ray = rdiv_ww(burn_amt, total_debt);

        // Loop through yangs and transfer a proportionate share to caller
        let sentinel: ISentinelDispatcher = sentinel::read();
        let yangs: Array<ContractAddress> = sentinel.get_yang_addresses();
        let mut yangs_span = yangs.span();

        loop {
            match (yangs_span.pop_front()) {
                Option::Some(yang) => {
                    let yang_total: Wad = shrine.get_yang_total(*yang);
                    let yang_to_redeem: Wad = rmul_rw(pct_to_redeem, yang_total);
                    sentinel.exit(*yang, caller, yang_to_redeem);
                },
                Option::None(_) => {
                    break ();
                },
            };
        };

        // Burn balance
        shrine.eject(caller, burn_amt);
    // TODO: add event

    // TODO: add return value
    }
}
