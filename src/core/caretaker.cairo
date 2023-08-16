#[contract]
mod Caretaker {
    use array::{ArrayTrait, SpanTrait};
    use cmp::min;
    use option::OptionTrait;
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use traits::{Default, Into, TryInto};
    use zeroable::Zeroable;

    use aura::core::roles::CaretakerRoles;

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IEqualizer::{IEqualizerDispatcher, IEqualizerDispatcherTrait};
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::AccessControl;
    use aura::utils::reentrancy_guard::ReentrancyGuard;
    use aura::utils::serde;
    use aura::utils::storage_access;
    use aura::utils::types::AssetBalance;
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RAY_ONE, Wad};

    //
    // Constants
    //

    // A dummy trove ID for Caretaker, required in Gate to emit events
    const DUMMY_TROVE_ID: u64 = 0;

    struct Storage {
        // Abbot associated with the Shrine for this Caretaker
        abbot: IAbbotDispatcher,
        // Equalizer associated with the Shrine for this Caretaker
        equalizer: IEqualizerDispatcher,
        // Sentinel associated with the Shrine for this Caretaker
        sentinel: ISentinelDispatcher,
        // Shrine associated with this Caretaker
        shrine: IShrineDispatcher,
    }

    //
    // Events
    //

    #[event]
    fn Shut() {}

    #[event]
    fn Release(user: ContractAddress, trove_id: u64, assets: Span<AssetBalance>) {}

    #[event]
    fn Reclaim(user: ContractAddress, yin_amt: Wad, assets: Span<AssetBalance>) {}

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
    }

    //
    // View functions
    //

    // Simulates the effects of `release` at the current on-chain conditions.
    #[view]
    fn preview_release(trove_id: u64) -> Span<AssetBalance> {
        let shrine: IShrineDispatcher = shrine::read();

        assert(shrine.get_live() == false, 'CA: System is live');

        let sentinel: ISentinelDispatcher = sentinel::read();
        let yangs: Span<ContractAddress> = sentinel.get_yang_addresses();

        let mut releasable_assets: Array<AssetBalance> = Default::default();
        let mut yangs_copy = yangs;

        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => {
                    let deposited_yang: Wad = shrine.get_deposit(*yang, trove_id);

                    let asset_amt: u128 = if deposited_yang.is_zero() {
                        0
                    } else {
                        sentinel.convert_to_assets(*yang, deposited_yang)
                    };

                    releasable_assets.append(AssetBalance { asset: *yang, amount: asset_amt });
                },
                Option::None(_) => {
                    break releasable_assets.span();
                },
            };
        }
    }

    // Simulates the effects of `reclaim` at the current on-chain conditions.
    #[view]
    fn preview_reclaim(yin: Wad) -> Span<AssetBalance> {
        let shrine: IShrineDispatcher = shrine::read();

        assert(shrine.get_live() == false, 'CA: System is live');

        // Cap percentage of amount to be reclaimed to 100% to catch
        // invalid values beyond total yin
        let pct_to_reclaim: Ray = wadray::rdiv_ww(yin, shrine.get_total_yin());
        let capped_pct: Ray = min(pct_to_reclaim, RAY_ONE.into());

        let yangs: Span<ContractAddress> = sentinel::read().get_yang_addresses();

        let mut reclaimable_assets: Array<AssetBalance> = Default::default();
        let caretaker = get_contract_address();
        let mut yangs_copy = yangs;
        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => {
                    let asset = IERC20Dispatcher { contract_address: *yang };
                    let caretaker_balance: u128 = asset.balance_of(caretaker).try_into().unwrap();
                    let asset_amt: Wad = wadray::rmul_rw(pct_to_reclaim, caretaker_balance.into());
                    reclaimable_assets.append(AssetBalance { asset: *yang, amount: asset_amt.val });
                },
                Option::None(_) => {
                    break reclaimable_assets.span();
                },
            };
        }
    }

    //
    // External
    //

    // Admin will initially have access to `shut`.
    #[external]
    fn shut() {
        AccessControl::assert_has_role(CaretakerRoles::SHUT);

        let shrine: IShrineDispatcher = shrine::read();

        // Prevent repeated `shut`
        assert(shrine.get_live(), 'CA: System is not live');

        // Mint surplus debt
        // Note that the total system debt may stil be higher than total yin after this
        // final minting of surplus debt due to loss of precision. However, any such
        // excess system debt is inconsequential because only the total yin supply will
        // be backed by collateral, and it would not be possible to mint this excess
        // system debt from this point onwards. Therefore, this excess system debt would
        // not affect the accounting for `release` and `reclaim` in this contract.
        equalizer::read().equalize();

        // Calculate the percentage of collateral needed to back yin 1 : 1
        // based on the last value of all collateral in Shrine
        let (_, total_value) = shrine.get_shrine_threshold_and_value();
        let backing_pct: Ray = wadray::rdiv_ww(shrine.get_total_yin(), total_value);

        // Cap the percentage to 100%
        let capped_backing_pct: Ray = min(backing_pct, RAY_ONE.into());

        // Loop through yangs and transfer the amount of each yang asset needed to back
        // yin to this contract. This is equivalent to a final redistribution enforced
        // on all trove owners.
        // Since yang assets are transferred out of the Gate and the total number of yang
        // is not updated in Shrine, the asset amount per yang in Gate will decrease.
        let sentinel: ISentinelDispatcher = sentinel::read();
        let mut yangs: Span<ContractAddress> = sentinel.get_yang_addresses();
        let caretaker = get_contract_address();

        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let backed_yang: Wad = wadray::rmul_rw(
                        capped_backing_pct, shrine.get_yang_total(*yang)
                    );
                    sentinel.exit(*yang, caretaker, DUMMY_TROVE_ID, backed_yang);
                },
                Option::None(_) => {
                    break;
                },
            };
        };

        // Kill modules
        shrine.kill();

        // Note that Absorber is not killed. When the final debt surplus is minted, the
        // absorber may be an allocated recipient. If the Absorber has been completely
        // drained (i.e. no shares in current epoch), receives a portion of the minted
        // debt surplus and is killed, then the final yin surplus will be inaccessible
        // if users can no longer call `Absorber.provide()`. Therefore, we do not kill
        // the Absorber, and allow the first provider in such a situation to gain a windfall
        // of the final debt surplus minted to the Absorber.

        Shut();
    }

    // Releases all remaining collateral in a trove to the trove owner directly.
    // - Note that after `shut` is triggered, the amount of yang in a trove will be fixed,
    //   but the asset amount per yang may have decreased because the assets needed to back
    //   yin 1 : 1 have been transferred from the Gates to the Caretaker.
    // Returns a tuple of arrays of the released asset addresses and released asset amounts
    // denominated in each respective asset's decimals.
    #[external]
    fn release(trove_id: u64) -> Span<AssetBalance> {
        let shrine: IShrineDispatcher = shrine::read();

        assert(shrine.get_live() == false, 'CA: System is live');

        // reentrancy guard is used as a precaution
        ReentrancyGuard::start();

        // Assert caller is trove owner
        let trove_owner: ContractAddress = abbot::read().get_trove_owner(trove_id);
        assert(trove_owner == get_caller_address(), 'CA: Not trove owner');

        let sentinel: ISentinelDispatcher = sentinel::read();
        let yangs: Span<ContractAddress> = sentinel.get_yang_addresses();

        let mut released_assets: Array<AssetBalance> = Default::default();
        let mut yangs_copy = yangs;

        // Loop over yangs deposited in trove and transfer to trove owner
        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => {
                    let deposited_yang: Wad = shrine.get_deposit(*yang, trove_id);
                    let asset_amt: u128 = if deposited_yang.is_zero() {
                        0
                    } else {
                        let exit_amt: u128 = sentinel
                            .exit(*yang, trove_owner, trove_id, deposited_yang);
                        // Seize the collateral only after assets have been
                        // transferred so that the asset amount per yang in Gate
                        // does not change and user receives the correct amount
                        shrine.seize(*yang, trove_id, deposited_yang);
                        exit_amt
                    };
                    released_assets.append(AssetBalance { asset: *yang, amount: asset_amt });
                },
                Option::None(_) => {
                    break;
                },
            };
        };

        Release(trove_owner, trove_id, released_assets.span());

        ReentrancyGuard::end();
        released_assets.span()
    }

    // Allow yin holders to burn their yin and receive their proportionate share of collateral assets
    // in the Caretaker contract based on the amount of yin as a proportion of total supply.
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
    // Returns a tuple of arrays of the reclaimed asset addresses and reclaimed asset amounts denominated
    // in each respective asset's decimals.
    #[external]
    fn reclaim(yin: Wad) -> Span<AssetBalance> {
        let shrine: IShrineDispatcher = shrine::read();

        assert(shrine.get_live() == false, 'CA: System is live');

        // reentrancy guard is used as a precaution
        ReentrancyGuard::start();

        let caller = get_caller_address();

        // Calculate amount of collateral corresponding to amount of yin reclaimed.
        // This needs to be done before burning the reclaimed yin amount from the caller
        // or the total supply would be incorrect.
        let reclaimable_assets: Span<AssetBalance> = preview_reclaim(yin);

        // This call will revert if `yin` is greater than the caller's balance.
        shrine.eject(caller, yin);

        // Loop through yangs and transfer a proportionate share of each yang asset in
        // the Caretaker to caller
        let mut reclaimable_assets_copy = reclaimable_assets;
        loop {
            match reclaimable_assets_copy.pop_front() {
                Option::Some(reclaimable_asset) => {
                    if (*reclaimable_asset.amount).is_zero() {
                        continue;
                    }

                    let success: bool = IERC20Dispatcher {
                        contract_address: *reclaimable_asset.asset
                    }.transfer(caller, (*reclaimable_asset.amount).into());
                    assert(success, 'CA: Asset transfer failed');
                },
                Option::None(_) => {
                    break;
                },
            };
        };

        Reclaim(caller, yin, reclaimable_assets);

        ReentrancyGuard::end();
        reclaimable_assets
    }

    //
    // Public AccessControl functions
    //

    #[view]
    fn get_roles(account: ContractAddress) -> u128 {
        AccessControl::get_roles(account)
    }

    #[view]
    fn has_role(role: u128, account: ContractAddress) -> bool {
        AccessControl::has_role(role, account)
    }

    #[view]
    fn get_admin() -> ContractAddress {
        AccessControl::get_admin()
    }

    #[view]
    fn get_pending_admin() -> ContractAddress {
        AccessControl::get_pending_admin()
    }

    #[external]
    fn grant_role(role: u128, account: ContractAddress) {
        AccessControl::grant_role(role, account);
    }

    #[external]
    fn revoke_role(role: u128, account: ContractAddress) {
        AccessControl::revoke_role(role, account);
    }

    #[external]
    fn renounce_role(role: u128) {
        AccessControl::renounce_role(role);
    }

    #[external]
    fn set_pending_admin(new_admin: ContractAddress) {
        AccessControl::set_pending_admin(new_admin);
    }

    #[external]
    fn accept_admin() {
        AccessControl::accept_admin();
    }
}
