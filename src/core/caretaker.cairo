use starknet::ContractAddress;

use aura::utils::wadray::{Wad};

// TODO: In `Shrine.charge`, perform an early return if shrine is not live. 
// TODO: Add `Shrine.assert_live()` to `Shrine.withdraw` and `Shrine.melt`:
//       - Trove owners should not be able to melt or withdraw via Abbot.
//       - By disabling `Shrine.melt`, liquidations via the Purger will also be disabled.
// TODO: Add `Shrine.assert_live()` to `Shrine.inject().
//       - Flashmint and minting debt surplus should not be possible upon shut.

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
}

#[contract]
mod Caretaker {
    use array::{ArrayTrait, SpanTrait};
    use clone::Clone;
    use cmp::min;
    use option::OptionTrait;
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use traits::{Into, TryInto};
    use zeroable::Zeroable;

    use aura::core::roles::CaretakerRoles;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::AccessControl;
    use aura::utils::storage_access_impls;
    use aura::utils::u256_conversions::{U128IntoU256, U256TryIntoU128};
    use aura::utils::wadray::{Ray, RAY_ONE, U128IntoRay, U128IntoWad, rdiv_ww, rmul_rw, Wad};

    use super::{
        IAbbotDispatcher, IAbbotDispatcherTrait, IEqualizerDispatcher, IEqualizerDispatcherTrait,
        ISentinelDispatcher, ISentinelDispatcherTrait
    };

    //
    // Constants
    //

    // A dummy trove ID for Caretaker
    const DUMMY_TROVE_ID: u64 = 0;

    struct Storage {
        abbot: IAbbotDispatcher,
        equalizer: IEqualizerDispatcher,
        sentinel: ISentinelDispatcher,
        shrine: IShrineDispatcher,
        // Final price of yangs
        // (yang_address) -> (Wad)
        yang_prices: LegacyMap::<ContractAddress, Wad>,
        // Keeps track of whether Caretaker is live or killed
        is_live: bool,
    }

    //
    // Events
    //

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
    fn Reclaim(
        user: ContractAddress, yin_amt: Wad, assets: Array<ContractAddress>, asset_amts: Array<u128>
    ) {}

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        admin: ContractAddress,
        shrine: ContractAddress,
        abbot: ContractAddress,
        sentinel: ContractAddress,
        equalizer: ContractAddress
    ) {
        AccessControl::initializer(admin);
        AccessControl::grant_role_internal(CaretakerRoles::default_admin_role(), admin);

        abbot::write(IAbbotDispatcher { contract_address: abbot });
        shrine::write(IShrineDispatcher { contract_address: shrine });
        sentinel::write(ISentinelDispatcher { contract_address: sentinel });
        equalizer::write(IEqualizerDispatcher { contract_address: equalizer });

        is_live::write(true);
    }

    //
    // External
    //

    // Admin will initially have access to `terminate`. At a later date, this access will be
    // transferred to a new module that allows users to irreversibly deposit AURA tokens to
    // trigger this emergency shutdown.
    #[external]
    fn shut() {
        AccessControl::assert_has_role(CaretakerRoles::SHUT);

        // Prevent repeated `shut`
        assert(is_live::read() == true, 'Caretaker is not live');

        // Mint surplus debt
        // Note that the total debt may stil be higher than total yin after this final
        // minting of surplus debt due to loss of precision. Any excess debt is ignored
        // because trove owners can withdraw all excess collateral in their trove after 
        // assets needed to back yin has been transferred to the Caretaker.
        let equalizer: IEqualizerDispatcher = equalizer::read();
        equalizer.equalize();

        let shrine: IShrineDispatcher = shrine::read();

        // Calculate the percentage of collateral needed to back yin 1 : 1
        // based on the last value
        let (_, total_value) = shrine.get_shrine_threshold_and_value();
        let total_yin: Wad = shrine.get_total_yin();
        let backing_pct: Ray = rdiv_ww(total_yin, total_value);

        // Cap the percentage to 100%
        let capped_backing_pct: Ray = min(backing_pct, RAY_ONE.into());

        // Loop through yangs and transfer the amount of each yang asset needed
        // to back yin to this contract.
        // This is equivalent to a final redistribution enforced on all trove
        // owners.
        // Since yang assets are transferred out of the Gate and the total number 
        // of yang is not updated in Shrine, the asset amount per yang will decrease. 
        let sentinel: ISentinelDispatcher = sentinel::read();
        let yangs: Array<ContractAddress> = sentinel.get_yang_addresses();
        let mut yangs_span = yangs.span();

        let caretaker: ContractAddress = get_contract_address();

        loop {
            match (yangs_span.pop_front()) {
                Option::Some(yang) => {
                    let total_yang: Wad = shrine.get_yang_total(*yang);
                    let backed_yang: Wad = rmul_rw(capped_backing_pct, total_yang);
                    sentinel.exit(*yang, caretaker, DUMMY_TROVE_ID, backed_yang);
                },
                Option::None(_) => {
                    break ();
                },
            };
        };

        // Kill modules
        is_live::write(false);
        shrine.kill();

        // Note that Absorber is not killed. When the final debt surplus is minted, the
        // absorber may be an allocated recipient. If the Absorber has been completely
        // drained (i.e. no shares in current epoch), receives a portion of the minted
        // debt surplus and is killed, then the final yin surplus will be inaccessible
        // if users can no longer call `Absorber.provide()`. Therefore, we do not kill
        // the Absorber, and allow the first provider in such a situation to gain a windfall
        // of the final debt surplus minted to the Absorber.

        let shut_time: u64 = get_block_timestamp();
        Shut(shut_time);
    }

    // Releases all remaining collateral in a trove to the trove owner directly.
    // - After `shut`, troves have the same amount of yang, but the asset amount per yang may 
    //   have decreased because the assets needed to back yin 1 : 1 have been transferred from 
    //   the Gates to the Caretaker.
    // Returns a tuple of arrays of the released asset addresses and released asset amounts.
    #[external]
    fn release(trove_id: u64) -> (Array<ContractAddress>, Array<u128>) {
        assert(is_live::read() == false, 'System is live');

        // Assert caller is trove owner
        let abbot: IAbbotDispatcher = abbot::read();
        let trove_owner: ContractAddress = abbot.get_trove_owner(trove_id);
        let caller: ContractAddress = get_caller_address();
        assert(caller == trove_owner, 'Not trove owner');

        // Calculate trove value using last price
        let shrine: IShrineDispatcher = shrine::read();
        let sentinel: ISentinelDispatcher = sentinel::read();
        let yangs: Array<ContractAddress> = sentinel.get_yang_addresses();
        let mut yangs_span = yangs.span();

        let mut asset_amts: Array<u128> = ArrayTrait::new();

        loop {
            match (yangs_span.pop_front()) {
                Option::Some(yang) => {
                    let deposited_yang: Wad = shrine.get_deposit(*yang, trove_id);

                    if deposited_yang.is_zero() {
                        asset_amts.append(0_u128);
                        continue;
                    }

                    let asset_amt: u128 = sentinel.exit(*yang, caller, trove_id, deposited_yang);
                    // Seize the collateral only after assets have been transferred so that user
                    // receives the correct amount
                    shrine.seize(*yang, trove_id, deposited_yang);

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

    // Allow yin holders to burn their yin and receive their proportionate share of collateral assets
    // withdrawn to the Caretaker contract based on the amount of yin as a proportion of total supply.
    // Example: assuming total system yin of 1_000, and Caretaker has a yang A asset balance of 4_000.
    //          User A and User B each wants to reclaim 100 yin, and expects to receive the same amount 
    //          of yang assets from the Caretaker regardless of who does so first.
    //          1. User A reclaims 100 yin, amounting to 100 / 1_000 = 10%, which entitles him to receive 
    //             10% * 4_000 = 400 yang A assets from the Caretaker.
    //          
    //             After User A reclaims, total system yin decreaes to 900, and the Caretaker's balance of
    //             yang A assets decreases to 3_600.
    //
    //          2. User B reclaims 100 yin, amounting to 100 / 900 = 11.11%, which entitles him to receive 
    //             11.1% * 3_600 = 400 yang A assets approximately.
    //              
    // Returns a tuple of arrays of the reclaimed asset addresses and reclaimed asset amounts
    #[external]
    fn reclaim(yin: Wad) -> (Array<ContractAddress>, Array<u128>) {
        assert(is_live::read() == false, 'System is live');

        let caller: ContractAddress = get_caller_address();
        let shrine: IShrineDispatcher = shrine::read();

        let user_bal: Wad = shrine.get_yin(caller);
        let burn_amt: Wad = min(yin, user_bal);

        // Calculate percentage of amount to be reclaimed out of total yin
        let total_yin: Wad = shrine.get_total_yin();
        let pct_to_reclaim: Ray = rdiv_ww(burn_amt, total_yin);

        let sentinel: ISentinelDispatcher = sentinel::read();
        let yangs: Array<ContractAddress> = sentinel.get_yang_addresses();
        let mut yangs_span = yangs.span();

        let mut asset_amts: Array<u128> = ArrayTrait::new();

        let caretaker: ContractAddress = get_caller_address();

        // Loop through yangs and transfer a proportionate share of each 
        // yang asset in the Caretaker to caller
        loop {
            match (yangs_span.pop_front()) {
                Option::Some(yang) => {
                    let asset: IERC20Dispatcher = IERC20Dispatcher { contract_address: *yang };
                    let caretaker_balance: u128 = asset.balance_of(caretaker).try_into().unwrap();
                    let caretaker_balance: Wad = caretaker_balance.into();
                    let asset_amt: Wad = rmul_rw(pct_to_reclaim, caretaker_balance);

                    if asset_amt.is_zero() {
                        asset_amts.append(0_u128);
                        continue;
                    }

                    let asset_amt_u256: u256 = asset_amt.val.into();

                    let success: bool = asset.transfer(caller, asset_amt_u256);
                    assert(success, 'Asset transfer failed');
                    asset_amts.append(asset_amt.val);
                },
                Option::None(_) => {
                    break ();
                },
            };
        };

        // Burn balance
        shrine.eject(caller, burn_amt);

        Reclaim(caller, burn_amt, yangs.clone(), asset_amts.clone());

        (yangs, asset_amts)
    }
}
