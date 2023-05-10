use starknet::ContractAddress;

use aura::utils::wadray::{Wad};

// TODO: skip `Shrine.charge` if shrine is not live
// TODO: add Shrine.assert_live to Abbot functions - trove owners should not be able to melt or withdraw
// TODO: add Shrine.assert_live to Purger functions - Caretaker needs to access Seize, 

#[abi]
trait IAbbot {
    fn get_trove_owner(trove_id: u64) -> ContractAddress;
}

#[abi]
trait IEqualizer {
    fn equalize();
}

#[abi]
trait ISentinel {
    fn exit(yang: ContractAddress, user: ContractAddress, troveid: u64, yang_amt: Wad) -> u128;
    fn get_yang_addresses() -> Array<ContractAddress>;
    // TODO: delete?
    fn preview_exit(yang: ContractAddress, yang_amt: Wad) -> u128;
}

#[contract]
mod Caretaker {
    use array::{ArrayTrait, SpanTrait};
    use clone::Clone;
    use cmp::min;
    use option::OptionTrait;
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};
    use zeroable::Zeroable;

    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::storage_access_impls;
    use aura::utils::wadray::{Ray, rdiv_ww, rmul_rw, Wad};

    use super::{
        IAbbotDispatcher, IAbbotDispatcherTrait, IEqualizerDispatcher, IEqualizerDispatcherTrait,
        ISentinelDispatcher, ISentinelDispatcherTrait
    };

    // TODO: A dummy trove ID is used because CASH holders may not be trove owners.
    //       Alternatively we can remove `trove_id` from Sentinel and Gate for `enter` and `exit`
    //       it is only used for emitting events.
    const REDEMPTION_TROVE_ID: u64 = 0;

    // Time delay from time of shut before users can burn CASH to redeem collateral
    // so that trove owners have priority to withdraw excess collateral
    // 28 days * 24 hours * 60 minutes * 60 seconds 
    const DELAY: u64 = 2419200;

    struct Storage {
        abbot: IAbbotDispatcher,
        equalizer: IEqualizerDispatcher,
        sentinel: ISentinelDispatcher,
        shrine: IShrineDispatcher,
        // Final price of yangs
        // (yang_address) -> (Wad)
        yang_prices: LegacyMap::<ContractAddress, Wad>,
        // Time when the protocol is shut
        shut_time: u64,
        // Keeps track of whether Caretaker is live or killed
        is_live: bool,
    }

    #[event]
    fn Shut(shut_time: u64) {}

    #[event]
    fn Release(
        user: ContractAddress,
        trove_id: u64,
        assets: Array<ContractAddress>,
        asset_amts: Array<u128>
    ) {}

    #[event]
    fn Redeem(
        user: ContractAddress, yin_amt: Wad, assets: Array<ContractAddress>, asset_amts: Array<u128>
    ) {}

    #[constructor]
    fn constructor(
        shrine: ContractAddress,
        abbot: ContractAddress,
        sentinel: ContractAddress,
        equalizer: ContractAddress
    ) {
        // AccessControl::initializer(admin);
        // AccessControl::grant_role(CaretakerRoles.SHUT, admin);
        abbot::write(IAbbotDispatcher { contract_address: abbot });
        shrine::write(IShrineDispatcher { contract_address: shrine });
        sentinel::write(ISentinelDispatcher { contract_address: sentinel });
        equalizer::write(IEqualizerDispatcher { contract_address: equalizer });

        is_live::write(true);
    }

    // Admin will initially have access to `terminate`. At a later date, this access will be
    // transferred to a new module that allows users to irreversibly deposit AURA tokens to
    // trigger this emergency shutdown.
    #[external]
    fn shut() {
        // AccessControl.assert_has_role(TerminatorRoles.SHUT);

        assert(is_live::read() == true, 'Caretaker is not live');

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

        // Kill modules
        is_live::write(false);
        shrine.kill();

        Shut(get_block_timestamp());
    }

    // Releases excess collateral beyond the debt's value to the trove owner directly
    // Returns a tuple of arrays of the released asset addresses and released asset amounts
    #[external]
    fn release(trove_id: u64) -> (Array<ContractAddress>, Array<u128>) {
        let shut_time = shut_time::read();
        assert(shut_time > 0 & is_live::read() == false, 'Caretaker is not killed');
        assert(get_block_timestamp() < shut_time + DELAY, 'Too late');

        // Assert caller is trove owner
        let abbot: IAbbotDispatcher = abbot::read();
        let trove_owner: ContractAddress = abbot.get_trove_owner(trove_id);
        let caller: ContractAddress = get_caller_address();
        assert(caller == trove_owner, 'Not trove owner');

        // Calculate percentage excess
        let shrine: IShrineDispatcher = shrine::read();
        let (_, _, value, debt) = shrine.get_trove_info(trove_id);

        let pct_to_release: Ray = rdiv_ww(value - debt, value);

        // Loop over yangs and transfer to trove owner
        let sentinel: ISentinelDispatcher = sentinel::read();
        let yangs: Array<ContractAddress> = sentinel.get_yang_addresses();
        let mut yangs_span = yangs.span();

        let mut asset_amts = ArrayTrait::new();

        loop {
            match (yangs_span.pop_front()) {
                Option::Some(yang) => {
                    let deposited_yang: Wad = shrine.get_deposit(*yang, trove_id);

                    if deposited_yang.is_zero() {
                        asset_amts.append(0_u128);
                        continue;
                    }

                    let yang_to_release: Wad = rmul_rw(pct_to_release, deposited_yang);
                    let asset_amt: u128 = sentinel.exit(*yang, caller, trove_id, yang_to_release);
                    // Seize the collateral after assets have been transferred so that user
                    // receives the correct amount
                    shrine.seize(*yang, trove_id, yang_to_release);

                    asset_amts.append(asset_amt);
                },
                Option::None(_) => {
                    break ();
                },
            };
        };

        Release(caller, trove_id, yangs.clone(), asset_amts.clone());

        (yangs, asset_amts)
    }

    // Allow yin holders to burn their yin and receive their proportionate share
    // of collateral based on the amount of yin as a proportion of total supply
    // Note that `redeem` will not change the amount of the yang in Shrine. This does
    // not affect the calculation because the drop in the asset amount per yang is 
    // compensated by the increase in the user's proportion of total remaining yin supply.
    // Returns a tuple of arrays of the redeemed asset addresses and redeemed asset amounts
    #[external]
    fn redeem(yin: Wad) -> (Array<ContractAddress>, Array<u128>) {
        let shut_time = shut_time::read();
        assert(shut_time > 0 & is_live::read() == false, 'Caretaker is not killed');
        assert(get_block_timestamp() >= shut_time + DELAY, 'Redemption has not started');

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

        let mut asset_amts = ArrayTrait::new();

        loop {
            match (yangs_span.pop_front()) {
                Option::Some(yang) => {
                    let yang_total: Wad = shrine.get_yang_total(*yang);
                    let yang_to_redeem: Wad = rmul_rw(pct_to_redeem, yang_total);
                    let asset_amt: u128 = sentinel.exit(
                        *yang, caller, REDEMPTION_TROVE_ID, yang_to_redeem
                    );
                    asset_amts.append(asset_amt);
                },
                Option::None(_) => {
                    break ();
                },
            };
        };

        // Burn balance
        shrine.eject(caller, burn_amt);

        Redeem(caller, burn_amt, yangs.clone(), asset_amts.clone());

        (yangs, asset_amts)
    }
}
