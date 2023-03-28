%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import assert_le, assert_not_zero, split_felt, unsigned_div_rem
from starkware.cairo.common.math_cmp import is_nn_le
from starkware.cairo.common.uint256 import ALL_ONES, Uint256
from starkware.starknet.common.syscalls import get_caller_address, get_contract_address

from contracts.absorber.roles import AbsorberRoles
from contracts.sentinel.interface import ISentinel
from contracts.shrine.interface import IShrine

// these imported public functions are part of the contract's interface
from contracts.lib.accesscontrol.accesscontrol_external import (
    change_admin,
    get_admin,
    get_roles,
    grant_role,
    has_role,
    renounce_role,
    revoke_role,
)
from contracts.lib.accesscontrol.library import AccessControl
from contracts.lib.aliases import address, bool, packed, ray, ufelt, wad
from contracts.lib.convert import pack_felt
from contracts.lib.interfaces import IERC20
from contracts.lib.types import (
    Absorption,
    AssetAbsorption,
    PackedAbsorption,
    PackedRemoval,
    Provision,
    Removal,
    Suspension,
)
from contracts.lib.wad_ray import WadRay

// Constants

// If the amount of yin wad per share drops below this threshold, the epoch is incremented
// to reset the yin per share ratio to 1 : 1 parity for accounting. Otherwise, there will
// eventually be an overflow when converting yin to shares (and vice versa)
// as yin per share approaches 0.
const YIN_PER_SHARE_THRESHOLD = 10 ** 15;

// Shares to be minted without a provider to avoid first provider front-running
const INITIAL_SHARES = 10 ** 3;

// Lower bound of the Shrine's LTV to threshold that can be set for restricting removals
const MIN_LIMIT = 50 * WadRay.RAY_PERCENT;

// Amount of time that needs to elapse after request is submitted before removal, in intervals
// as defined in Shrine
const REMOVAL_TIMELOCK_INTERVAL = 1;

//
// Storage
//

@storage_var
func absorber_purger() -> (purger: address) {
}

@storage_var
func absorber_sentinel() -> (sentinel: address) {
}

@storage_var
func absorber_shrine() -> (shrine: address) {
}

@storage_var
func absorber_live() -> (is_live: bool) {
}

// Epoch starts from 0.
// Both shares and absorptions are tied to an epoch.
// The epoch is incremented when the amount of yin per share drops below the threshold.
// This includes when the absorber's yin balance is completely depleted.
@storage_var
func absorber_current_epoch() -> (epoch: ufelt) {
}

// Absorptions start from 1.
@storage_var
func absorber_absorptions_count() -> (absorption_id: ufelt) {
}

// Mapping from a provider to the last absorption ID accounted for
@storage_var
func absorber_provider_last_absorption(provider: address) -> (absorption_id: ufelt) {
}

// Mapping of address to a packed struct of
// 1. epoch in which the provider's shares are issued
// 2. number of shares for the provider in the above epoch
@storage_var
func absorber_provision(provider: address) -> (provision: packed) {
}

// Mapping from an absorption to its epoch
@storage_var
func absorber_absorption(absorption_id: ufelt) -> (absorption: packed) {
}

// Total number of shares for current epoch
@storage_var
func absorber_total_shares() -> (total: wad) {
}

// Mapping of a tuple of absorption ID and asset to a packed struct of
// 1. the amount of that asset in its decimal precision absorbed per share wad for an absorption
// 2. the rounding error from calculating (1) that is to be added to the next absorption
@storage_var
func absorber_asset_absorption(absorption_id: ufelt, asset: address) -> (info: packed) {
}

// Conversion rate of an epoch's shares to the next
// If an update causes the yin per share to drop below the threshold,
// the epoch is incremented and yin per share is reset to one ray.
// A provider with shares in that epoch will receive new shares in the next epoch
// based on this conversion rate.
// If the absorber's yin balance is wiped out, the conversion rate will be 0.
@storage_var
func absorber_epoch_share_conversion_rate(prev_epoch: ufelt) -> (rate: ray) {
}

// Removals are temporarily suspended if the shrine's LTV to threshold exceeds this limit
@storage_var
func absorber_removal_limit() -> (limit: ray) {
}

// Total amount of shares to be removed at the start of the given interval
// The yin corresponding to these shares will no longer be at risk of absorption, and will not earn
// any rewards
@storage_var
func absorber_removed_shares(interval: ufelt) -> (shares: wad) {
}

// The last amount of yin per share for the given interval
@storage_var
func absorber_last_yin_per_share_for_interval(interval: ufelt) -> (yin_per_share: wad) {
}

// Packed struct of
// 1. the total amount of yin pending removal, are no longer subject to absorption
//    and are not entitled to rewards
// 2. interval in which (1) was last updated
//    the maximum possible value at any given time should be the interval before the current interval,
@storage_var
func absorber_suspension() -> (suspension: packed) {
}

// Mapping of a provider to a packed struct of
// 1. the interval, as determined by Shrine, in which a request to remove yin was submitted
// 2. the amount of shares requested to be removed
// 3. epoch of the shares requested to be removed
@storage_var
func absorber_provider_removal(provider: address) -> (removal: packed) {
}

//
// Events
//

@event
func PurgerUpdated(old_address: address, new_address: address) {
}

@event
func EpochChanged(old_epoch: ufelt, new_epoch: ufelt) {
}

@event
func RemovalLimitUpdated(old_limit: ray, new_limit: ray) {
}

@event
func Provide(provider: address, epoch: ufelt, yin: wad) {
}

@event
func Remove(provider: address, interval: ufelt, yin: wad) {
}

@event
func Request(provider: address, epoch: ufelt, interval: ufelt, yin: wad) {
}

@event
func Reap(
    provider: address,
    assets_len: ufelt,
    assets: address*,
    asset_amts_len: ufelt,
    asset_amts: ufelt*,
) {
}

@event
func Gain(
    assets_len: ufelt,
    assets: address*,
    asset_amts_len: ufelt,
    asset_amts: wad*,
    total_shares: wad,
    epoch: ufelt,
    absorption_id: ufelt,
) {
}

@event
func Killed() {
}

@event
func Compensate(
    recipient: address,
    assets_len: ufelt,
    assets: address*,
    asset_amts_len: ufelt,
    asset_amts: ufelt*,
) {
}

//
// Constructor
//

@constructor
func constructor{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(admin: address, shrine: address, sentinel: address, limit: ray) {
    alloc_locals;

    AccessControl.initializer(admin);
    AccessControl._grant_role(AbsorberRoles.DEFAULT_ABSORBER_ADMIN_ROLE, admin);

    absorber_shrine.write(shrine);
    absorber_sentinel.write(sentinel);
    absorber_live.write(TRUE);
    set_removal_limit_internal(limit);
    return ();
}

//
// Getters
//

@view
func get_purger{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    purger: address
) {
    let purger: address = absorber_purger.read();
    return (purger,);
}

@view
func get_absorbable_yin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    amount: wad
) {
    alloc_locals;

    let shrine: address = absorber_shrine.read();
    let absorber: address = get_contract_address();
    let (yin_balance: wad) = IShrine.get_yin(shrine, absorber);

    let suspension: Suspension = absorber_suspension.read();
    let current_interval: ufelt = IShrine.now(shrine);
    let suspended_yin: wad = get_suspended_yin_loop(
        suspension.interval, current_interval, yin_balance
    );

    let absorbable_yin: wad = WadRay.unsigned_sub(yin_balance, suspended_yin);

    return (absorbable_yin,);
}

@view
func get_current_epoch{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    epoch: ufelt
) {
    let epoch: ufelt = absorber_current_epoch.read();
    return (epoch,);
}

@view
func get_absorptions_count{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    count: ufelt
) {
    let count: ufelt = absorber_absorptions_count.read();
    return (count,);
}

@view
func get_absorption{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    absorption_id: ufelt
) -> (absorption: Absorption) {
    let absorption: Absorption = get_absorption_internal(absorption_id);
    return (absorption,);
}

@view
func get_total_shares_for_current_epoch{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}() -> (total: wad) {
    let shares: wad = absorber_total_shares.read();
    return (shares,);
}

@view
func get_provider_info{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address
) -> (provision: Provision) {
    let provision: Provision = get_provision(provider);
    return (provision,);
}

@view
func get_provider_last_absorption{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address
) -> (absorption_id: ufelt) {
    let absorption_id: ufelt = absorber_provider_last_absorption.read(provider);
    return (absorption_id,);
}

@view
func get_provider_removal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address
) -> (removal: Removal) {
    let removal: Removal = absorber_provider_removal.read(provider);
    return (removal,);
}

@view
func get_asset_absorption_info{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    asset: address, absorption_id: ufelt
) -> (info: AssetAbsorption) {
    let info: AssetAbsorption = get_asset_absorption(asset, absorption_id);
    return (info,);
}

@view
func get_removal_limit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    limit: ray
) {
    let limit: ray = absorber_removal_limit.read();
    return (limit,);
}

@view
func get_live{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    is_live: bool
) {
    return absorber_live.read();
}

//
// View
//

// Returns the maximum amount of yin removable by a provider.
@view
func preview_remove{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address
) -> (amount: wad) {
    let provision: Provision = get_provision(provider);
    let current_epoch: ufelt = absorber_current_epoch.read();
    let current_provider_shares: wad = convert_epoch_shares(
        provision.epoch, current_epoch, provision.shares
    );

    let max_removable_yin: wad = convert_to_yin(current_provider_shares);
    return (max_removable_yin,);
}

@view
func preview_reap{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address
) -> (assets_len: ufelt, assets: address*, asset_amts_len: ufelt, asset_amts: ufelt*) {
    alloc_locals;

    let provision: Provision = get_provision(provider);
    let provider_last_absorption_id: ufelt = absorber_provider_last_absorption.read(provider);
    let current_absorption_id: ufelt = absorber_absorptions_count.read();

    let (
        assets_len, assets: address*, asset_amts: ufelt*
    ) = get_absorbed_assets_for_provider_internal(
        provider, provision, provider_last_absorption_id, current_absorption_id
    );
    return (assets_len, assets, assets_len, asset_amts);
}

//
// Setters
//

@external
func set_purger{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(purger: address) {
    alloc_locals;

    AccessControl.assert_has_role(AbsorberRoles.SET_PURGER);

    with_attr error_message("Absorber: Purger address cannot be zero") {
        assert_not_zero(purger);
    }

    let shrine: address = absorber_shrine.read();
    // Approve new address for unlimited balance of yin
    let max_allowance: Uint256 = Uint256(low=ALL_ONES, high=ALL_ONES);
    IERC20.approve(shrine, purger, max_allowance);

    let old_address: address = absorber_purger.read();
    absorber_purger.write(purger);
    PurgerUpdated.emit(old_address, purger);

    // Remove allowance for previous address
    if (old_address != 0) {
        let zero_allowance: Uint256 = Uint256(low=0, high=0);
        IERC20.approve(shrine, old_address, zero_allowance);
        return ();
    }

    return ();
}

@external
func set_removal_limit{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(limit: ray) {
    alloc_locals;

    AccessControl.assert_has_role(AbsorberRoles.SET_REMOVAL_LIMIT);

    let prev_limit: ray = absorber_removal_limit.read();
    set_removal_limit_internal(limit);
    RemovalLimitUpdated.emit(prev_limit, limit);

    return ();
}

//
// External
//

// Supply yin to the absorber.
// Requires the caller to have approved spending by the absorber.
@external
func provide{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(amount: wad) {
    alloc_locals;

    assert_live();

    with_attr error_message("Absorber: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    let provider: address = get_caller_address();

    // Withdraw absorbed collateral before updating shares
    let provision: Provision = get_provision(provider);
    reap_internal(provider, provision);

    // Calculate number of shares to issue to provider and to add to total for current epoch
    // The two values deviate only when it is the first provision of an epoch and
    // total shares is below the minimum initial shares.
    let (new_provision_shares: wad, issued_shares: wad) = convert_to_shares(amount, FALSE);

    // If epoch has changed, convert shares in previous epoch to new epoch's shares
    let current_epoch: ufelt = absorber_current_epoch.read();
    let converted_shares: wad = convert_epoch_shares(
        provision.epoch, current_epoch, provision.shares
    );

    let new_shares: wad = WadRay.unsigned_add(converted_shares, new_provision_shares);
    let provision: Provision = Provision(current_epoch, new_shares);
    set_provision(provider, provision);

    // Update total shares for current epoch
    let prev_total_shares: wad = absorber_total_shares.read();
    let new_total_shares: wad = WadRay.unsigned_add(prev_total_shares, issued_shares);
    absorber_total_shares.write(new_total_shares);

    // Perform transfer of yin
    let shrine: address = absorber_shrine.read();
    let absorber: address = get_contract_address();
    let amount_uint: Uint256 = WadRay.to_uint(amount);
    with_attr error_message("Absorber: Transfer of yin failed") {
        let (success: bool) = IERC20.transferFrom(shrine, provider, absorber, amount_uint);
        assert success = TRUE;
    }

    Provide.emit(provider, current_epoch, amount);

    return ();
}

// Withdraw all yin submitted for removal earlier
// Guards against front-running by requiring the removal to first be submitted
// in an earlier interval
@external
func remove{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    alloc_locals;

    let (provider: address) = get_caller_address();
    let removal: Removal = get_removal(provider);

    with_attr error_message("Absorber: Nothing to remove") {
        assert_not_zero(removal.shares);
    }

    let shrine: address = absorber_shrine.read();

    assert_can_remove(shrine, provider, removal);

    // TODO calculate amount of yin that can be removed
    let current_interval: ufelt = IShrine.now(shrine);

    let (
        latest_epoch_in_interval: ufelt, latest_absorption_id_in_interval: ufelt
    ) = get_latest_epoch_and_absorption_id_in_interval(
        removal.epoch, removal.interval, removal.absorption_id
    );

    let converted_removed_shares: wad = convert_epoch_shares(
        removal.epoch, latest_epoch_in_interval, removal.shares
    );

    // Get yin per share of the latest absorption in the given epoch and interval
    let latest_absorption: Absorption = get_absorption(removal.absorption_id);
    let removable_yin_amt: wad = WadRay.wmul(
        converted_removed_shares, latest_absorption.after_yin_per_share
    );

    // TODO update total amount of yin pending removal

    let suspension: Suspension = get_suspension();
    let new_total: wad = WadRay.unsigned_sub(suspension.yin, removable_yin_amt);
    let new_suspension: Suspension = Suspension(new_total, suspension.interval);

    let yin_amt_uint: Uint256 = WadRay.to_uint(removable_yin_amt);
    with_attr error_message("Absorber: Transfer of yin failed") {
        let (success: bool) = IERC20.transfer(shrine, provider, yin_amt_uint);
        assert success = TRUE;
    }

    let current_interval: ufelt = IShrine.now(shrine);
    let updated_removal: Removal = Removal(
        removal.interval, removal.absorption_id, 0, removal.epoch
    );
    set_removal(provider, updated_removal);
    Remove.emit(provider, current_interval, removable_yin_amt);

    return ();
}

// Submit a request to remove yin (if any)
// Also instantly withdraws all absorbed collateral assets from the absorber.
@external
func request{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(amount: wad) {
    alloc_locals;

    with_attr error_message("Absorber: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    let provider: address = get_caller_address();
    let provision: Provision = get_provision(provider);
    assert_provider(provision);

    let shrine: address = absorber_shrine.read();
    let current_interval: ufelt = IShrine.now(shrine);
    let existing_removal: Removal = get_removal(provider);
    assert_can_request(shrine, provider, existing_removal, current_interval);

    // Withdraw absorbed collateral before updating shares
    reap_internal(provider, provision);

    // Fetch the shares for current epoch
    let current_epoch: ufelt = absorber_current_epoch.read();
    let current_provider_shares: wad = convert_epoch_shares(
        provision.epoch, current_epoch, provision.shares
    );
    if (current_provider_shares == 0) {
        // If no remaining shares after converting across epochs,
        // provider's deposit has been completely absorbed.
        // Since absorbed collateral have been reaped,
        // we can update the provision to current epoch and shares.
        let new_provision: Provision = Provision(current_epoch, 0);
        set_provision(provider, new_provision);

        Request.emit(provider, current_epoch, current_interval, 0);

        return ();
    } else {
        // Calculations for yin need to be performed before updating total shares.
        // Cap `amount` to maximum removable for provider, then derive the number of shares.
        let max_removable_yin: wad = convert_to_yin(current_provider_shares);
        let yin_amt: wad = WadRay.unsigned_min(amount, max_removable_yin);
        let (shares_to_remove_ceiled: wad, _) = convert_to_shares(yin_amt, TRUE);

        // Due to precision loss, we need to re-check if the amount to remove is the max
        // removable, and then set the shares to remove as the provider's balance to avoid
        // any remaining dust shares.
        if (yin_amt == max_removable_yin) {
            tempvar shares_to_remove: wad = current_provider_shares;
        } else {
            tempvar shares_to_remove: wad = shares_to_remove_ceiled;
        }

        // let prev_total_shares: wad = absorber_total_shares.read();
        // let new_total_shares: wad = WadRay.unsigned_sub(prev_total_shares, shares_to_remove);
        // absorber_total_shares.write(new_total_shares);

        // Update provision
        // let new_provider_shares: wad = WadRay.unsigned_sub(
        //    current_provider_shares, shares_to_remove
        // );
        // let new_provision: Provision = Provision(current_epoch, new_provider_shares);
        // set_provision(provider, new_provision);

        // let current_total_requested_yin: wad = absorber_pending_removal_yin.read();
        // absorber_pending_removal_yin.write(
        //    WadRay.unsigned_add(current_total_requested_yin, yin_amt)
        // );

        let current_absorption_id: ufelt = absorber_absorptions_count.read();
        let removal: Removal = Removal(
            current_interval, current_absorption_id, shares_to_remove, current_epoch
        );
        set_removal(provider, removal);

        Request.emit(provider, current_epoch, current_interval, yin_amt);

        return ();
    }
}

// Withdraw absorbed collateral only from the absorber
// Note that `reap` alone will not update a caller's Provision in storage
@external
func reap{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    alloc_locals;

    let provider: address = get_caller_address();
    let provision: Provision = get_provision(provider);
    assert_provider(provision);

    reap_internal(provider, provision);

    return ();
}

// Update assets received after an absorption
@external
func update{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(assets_len: ufelt, assets: address*, asset_amts_len: ufelt, asset_amts: ufelt*) {
    alloc_locals;

    AccessControl.assert_has_role(AbsorberRoles.UPDATE);

    // Increment absorption ID
    let prev_absorption_id: ufelt = absorber_absorptions_count.read();
    let current_absorption_id: ufelt = prev_absorption_id + 1;
    absorber_absorptions_count.write(current_absorption_id);

    // Loop through assets and calculate amount entitled per share
    let total_shares: wad = absorber_total_shares.read();
    update_assets_loop(current_absorption_id, total_shares, assets_len, assets, asset_amts);

    let current_epoch: ufelt = absorber_current_epoch.read();

    // Increment epoch ID if yin per share drops below threshold or stability pool is emptied
    let absorbable_yin_balance: wad = get_absorbable_yin();
    let yin_per_share: wad = WadRay.wunsigned_div_unchecked(absorbable_yin_balance, total_shares);

    // Update absorption info for absorption ID
    let shrine: address = absorber_shrine.read();
    let current_interval: ufelt = IShrine.now(shrine);
    let absorption: Absorption = Absorption(current_epoch, current_interval, yin_per_share);
    set_absorption(current_absorption_id, absorption);

    // Emit `Gain` event
    Gain.emit(
        assets_len,
        assets,
        asset_amts_len,
        asset_amts,
        total_shares,
        current_epoch,
        current_absorption_id,
    );

    // This also checks for absorber's yin balance being emptied because yin per share will be
    // below threshold if yin balance is 0.
    let above_threshold: bool = is_nn_le(YIN_PER_SHARE_THRESHOLD, yin_per_share);
    if (above_threshold == TRUE) {
        return ();
    }

    let new_epoch: ufelt = current_epoch + 1;
    absorber_current_epoch.write(new_epoch);

    // If new epoch's yin balance exceeds the initial minimum shares, deduct the initial
    // minimum shares worth of yin from the yin balance so that there is at least such amount
    // of yin that cannot be removed in the next epoch.
    let above_initial_shares: bool = is_nn_le(INITIAL_SHARES, absorbable_yin_balance);
    if (above_initial_shares == TRUE) {
        tempvar yin_balance_for_shares: wad = absorbable_yin_balance - INITIAL_SHARES;
    } else {
        tempvar yin_balance_for_shares: wad = absorbable_yin_balance;
    }

    let epoch_share_conversion_rate: ray = WadRay.runsigned_div_unchecked(
        yin_balance_for_shares, total_shares
    );

    // If absorber is emptied, this will be set to 0.
    absorber_epoch_share_conversion_rate.write(current_epoch, epoch_share_conversion_rate);

    // If absorber is emptied, this will be set to 0.
    absorber_total_shares.write(absorbable_yin_balance);
    EpochChanged.emit(current_epoch, new_epoch);
    return ();
}

@external
func kill{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}() {
    AccessControl.assert_has_role(AbsorberRoles.KILL);
    absorber_live.write(FALSE);
    Killed.emit();

    return ();
}

@external
func compensate{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(
    recipient: address,
    assets_len: ufelt,
    assets: address*,
    asset_amts_len: ufelt,
    asset_amts: ufelt*,
) {
    alloc_locals;

    AccessControl.assert_has_role(AbsorberRoles.COMPENSATE);

    transfer_assets(recipient, assets_len, assets, asset_amts);

    Compensate.emit(recipient, assets_len, assets, asset_amts_len, asset_amts);

    return ();
}

//
// Internal
//

func assert_provider{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provision: Provision
) {
    with_attr error_message("Absorber: Caller is not a provider") {
        assert_not_zero(provision.shares);
    }
    return ();
}

func assert_live{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    // Check system is live
    let (is_live: bool) = absorber_live.read();
    with_attr error_message("Absorber: Absorber is not live") {
        assert is_live = TRUE;
    }
    return ();
}

func set_removal_limit_internal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    limit: ray
) {
    with_attr error_message("Absorber: Value of `limit` ({limit}) is out of bounds") {
        WadRay.assert_valid_unsigned(limit);
    }

    with_attr error_message("Absorber: Limit is too low") {
        // We can use `assert_le` here because the value has been checked in the previous statement
        assert_le(MIN_LIMIT, limit);
    }

    absorber_removal_limit.write(limit);
    return ();
}

//
// Internal - helpers for packed structs
//

func get_provision{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address
) -> (provision: Provision) {
    let (provision_packed: packed) = absorber_provision.read(provider);
    let (epoch: ufelt, shares: wad) = split_felt(provision_packed);
    let provision: Provision = Provision(epoch=epoch, shares=shares);
    return (provision,);
}

func set_provision{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address, provision: Provision
) {
    let packed_provision: packed = pack_felt(provision.epoch, provision.shares);
    absorber_provision.write(provider, packed_provision);
    return ();
}

func get_absorption_internal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    absorption_id: ufelt
) -> (absorption: Absorption) {
    let (absorption_packed: packed) = absorber_absorption.read(absorption_id);
    let (info: packed, after_yin_per_share: wad) = split_felt(absorption_packed);
    let (epoch: ufelt, interval: wad) = split_felt(info);
    let absorption: Absorption = Absorption(
        epoch=epoch, interval=interval, after_yin_per_share=after_yin_per_share
    );
    return (absorption,);
}

func set_absorption{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    absorption_id: ufelt, absorption: Absorption
) {
    let info: packed = pack_felt(absorption.epoch, absorption.interval);
    let packed_absorption: packed = pack_felt(info, absorption.after_yin_per_share);
    absorber_absorption.write(absorption_id, packed_absorption);
    return ();
}

func get_asset_absorption{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    asset: address, absorption_id: ufelt
) -> (info: AssetAbsorption) {
    let (info_packed: packed) = absorber_asset_absorption.read(absorption_id, asset);
    let (asset_amt_per_share: wad, error: wad) = split_felt(info_packed);
    let info: AssetAbsorption = AssetAbsorption(
        asset_amt_per_share=asset_amt_per_share, error=error
    );
    return (info,);
}

func get_removal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address
) -> (removal: Removal) {
    let (removal_packed: packed) = absorber_provider_removal.read(provider);
    let (info: packed, shares_info: wad) = split_felt(removal_packed);
    let (interval: ufelt, absorption_id: ufelt) = split_felt(info);
    let (shares: wad, epoch: ufelt) = split_felt(shares_info);
    let removal: Removal = Removal(
        interval=interval, absorption_id=absorption_id, shares=shares, epoch=epoch
    );
    return (removal,);
}

func set_removal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address, removal: Removal
) {
    let info: packed = pack_felt(removal.interval, removal.absorption_id);
    let shares_info: packed = pack_felt(removal.shares, removal.epoch);
    let packed_removal: packed = pack_felt(info, shares_info);
    absorber_provider_removal.write(provider, packed_removal);
    return ();
}

func get_suspension{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    suspension: Suspension
) {
    let (suspension_packed: packed) = absorber_suspension.read();
    let (yin: wad, interval: ufelt) = split_felt(suspension_packed);
    let suspension: Suspension = Suspension(yin=yin, interval=interval);
    return (suspension,);
}

func set_suspension{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    suspension: Suspension
) {
    let suspension_packed: packed = pack_felt(suspension.yin, suspension.interval);
    absorber_suspension.write(suspension_packed);
    return ();
}

//
// Internal - helpers for accounting of shares
//

// Convert to shares with a flag for whether the value should be rounded up or rounded down.
// When converting to shares, we always favour the Absorber to the expense of the provider.
// - Round down for `provide` (default for integer division)
// - Round up for `remove`
// Returns a tuple of the shares to be issued to the provider, and the total number of shares
// issued for the system.
// - There will be a difference between the two values only if it is the first `provide` of an epoch and
//   the total shares is less than the minimum initial shares.
func convert_to_shares{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yin_amt: wad, round_up: bool
) -> (provider_shares: wad, system_shares: wad) {
    let total_shares: wad = absorber_total_shares.read();

    let is_above_minimum: bool = is_nn_le(INITIAL_SHARES, total_shares);
    if (is_above_minimum == FALSE) {
        // This branch should be unreachable when called in `remove` because no address would have
        // any shares if total shares is 0
        with_attr error_message("Absorber: Amount provided is less than minimum initial shares") {
            // By deducting the initial shares from the first provider's shares, we ensure that
            // there is a non-removable amount of shares.
            let provider_shares: wad = WadRay.unsigned_sub(yin_amt, INITIAL_SHARES);
        }

        return (provider_shares, yin_amt);
    } else {
        let shrine: address = absorber_shrine.read();
        let absorber: address = get_contract_address();
        let yin_balance_uint: Uint256 = IERC20.balanceOf(shrine, absorber);
        let yin_balance: wad = WadRay.from_uint(yin_balance_uint);

        let suspension: Suspension = get_suspension();
        let adjusted_yin_balance: wad = WadRay.unsigned_sub(yin_balance, suspension.yin);

        // replicate `WadRay.wunsigned_div_unchecked` to check remainder of integer division
        let (computed_shares: wad, r: wad) = unsigned_div_rem(
            yin_amt * total_shares, adjusted_yin_balance
        );
        if (round_up == TRUE and r != 0) {
            return (computed_shares + 1, computed_shares + 1);
        }

        return (computed_shares, computed_shares);
    }
}

// This implementation is slightly different from Gate because the concept of shares is
// used for internal accounting only, and both shares and yin are wads.
func convert_to_yin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shares_amt: wad
) -> wad {
    let total_shares: wad = absorber_total_shares.read();

    // If no shares are issued yet, then it is a new epoch and absorber is emptied.
    if (total_shares == 0) {
        return 0;
    } else {
        let shrine: address = absorber_shrine.read();
        let absorber: address = get_contract_address();

        let yin_balance_uint: Uint256 = IERC20.balanceOf(shrine, absorber);
        let yin_balance: wad = WadRay.from_uint(yin_balance_uint);

        let suspension: Suspension = get_suspension();
        let adjusted_yin_balance: wad = WadRay.unsigned_sub(yin_balance, suspension.yin);
        let yin: wad = WadRay.wunsigned_div_unchecked(
            WadRay.wmul(shares_amt, adjusted_yin_balance), total_shares
        );
        return yin;
    }
}

// Convert an epoch's shares to a subsequent epoch's shares
// Return argument is named for testing
func convert_epoch_shares{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    start_epoch: ufelt, end_epoch: ufelt, start_shares: wad
) -> (shares: wad) {
    if (start_epoch == end_epoch) {
        return (start_shares,);
    }

    let epoch_conversion_rate: ray = absorber_epoch_share_conversion_rate.read(start_epoch);

    // `rmul` of a wad and a ray returns a wad
    let new_shares: wad = WadRay.rmul(start_shares, epoch_conversion_rate);

    return convert_epoch_shares(start_epoch + 1, end_epoch, new_shares);
}

//
// Internal - helpers for `update`
//

// Helper function to iterate over an array of assets received from an absorption for updating
// each provider's entitlement
func update_assets_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    absorption_id: ufelt, total_shares: wad, asset_count: ufelt, assets: address*, amounts: ufelt*
) {
    if (asset_count == 0) {
        return ();
    }
    update_asset(absorption_id, total_shares, [assets], [amounts]);
    return update_assets_loop(
        absorption_id, total_shares, asset_count - 1, assets + 1, amounts + 1
    );
}

// Helper function to update each provider's entitlement of an absorbed asset
func update_asset{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    absorption_id: ufelt, total_shares: wad, asset: address, amount: ufelt
) {
    if (amount == 0) {
        return ();
    }

    let last_error: wad = get_recent_asset_absorption_error(asset, absorption_id);
    let total_amount_to_distribute: wad = WadRay.unsigned_add(amount, last_error);

    let asset_amt_per_share: wad = WadRay.wunsigned_div(total_amount_to_distribute, total_shares);
    let actual_amount_distributed: wad = WadRay.wmul(asset_amt_per_share, total_shares);
    let error: wad = WadRay.unsigned_sub(total_amount_to_distribute, actual_amount_distributed);

    let packed_asset_absorption: packed = pack_felt(asset_amt_per_share, error);
    absorber_asset_absorption.write(absorption_id, asset, packed_asset_absorption);

    return ();
}

// Returns the last error for an asset at a given `absorption_id` if the packed value is non-zero.
// Otherwise, check `absorption_id - 1` recursively for the last error.
func get_recent_asset_absorption_error{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(asset: address, absorption_id: ufelt) -> (error: wad) {
    if (absorption_id == 0) {
        return (0,);
    }

    let (packed_info: packed) = absorber_asset_absorption.read(absorption_id, asset);
    if (packed_info != 0) {
        let (_, error: wad) = split_felt(packed_info);
        return (error,);
    }

    return get_recent_asset_absorption_error(asset, absorption_id - 1);
}

//
// Internal - helpers for `reap`
//

// Internal function to be called whenever a provider takes an action to ensure absorbed assets
// are properly transferred to the provider before updating the provider's information
func reap_internal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address, provision: Provision
) {
    alloc_locals;

    let provider_last_absorption_id: ufelt = absorber_provider_last_absorption.read(provider);
    let current_absorption_id: ufelt = absorber_absorptions_count.read();

    // This should be updated before early return so that first provision by a new
    // address is properly updated.
    absorber_provider_last_absorption.write(provider, current_absorption_id);

    let (
        assets_len: ufelt, assets: address*, asset_amts: ufelt*
    ) = get_absorbed_assets_for_provider_internal(
        provider, provision, provider_last_absorption_id, current_absorption_id
    );

    // Loop over assets and transfer
    transfer_assets(provider, assets_len, assets, asset_amts);

    Reap.emit(provider, assets_len, assets, assets_len, asset_amts);

    return ();
}

// Internal function to calculate the absorbed assets that a provider is entitled to
func get_absorbed_assets_for_provider_internal{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    provider: address,
    provision: Provision,
    provided_absorption_id: ufelt,
    current_absorption_id: ufelt,
) -> (assets_len: ufelt, assets: address*, asset_amts: ufelt*) {
    alloc_locals;

    let (asset_amts: ufelt*) = alloc();

    // Early termination by returning empty arrays
    if (provision.shares == 0) {
        return (0, asset_amts, asset_amts);
    }

    if (current_absorption_id == provided_absorption_id) {
        return (0, asset_amts, asset_amts);
    }

    let sentinel: address = absorber_sentinel.read();
    let (assets_len: ufelt, assets: address*) = ISentinel.get_yang_addresses(sentinel);

    get_absorbed_assets_for_provider_outer_loop(
        provision, provided_absorption_id, current_absorption_id, assets_len, 0, assets, asset_amts
    );

    return (assets_len, assets, asset_amts);
}

// Outer loop iterating over yangs
// Since we can only write to an array once, we need to compute
// the total amount to transfer for a given asset across all absorption IDs.
// Therefore, we iterate over yangs first.
func get_absorbed_assets_for_provider_outer_loop{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    provision: Provision,
    last_absorption_id: ufelt,
    current_absorption_id: ufelt,
    asset_count: ufelt,
    asset_idx: ufelt,
    assets: address*,
    asset_amts: ufelt*,
) {
    alloc_locals;

    if (asset_count == asset_idx) {
        return ();
    }

    let asset: address = assets[asset_idx];
    let asset_amt: ufelt = get_absorbed_assets_for_provider_inner_loop(
        provision.shares, provision.epoch, last_absorption_id, current_absorption_id, asset, 0
    );

    assert asset_amts[asset_idx] = asset_amt;

    return get_absorbed_assets_for_provider_outer_loop(
        provision,
        last_absorption_id,
        current_absorption_id,
        asset_count,
        asset_idx + 1,
        assets,
        asset_amts,
    );
}

// Inner loop iterating over absorption IDs starting from the ID right after the last absorption ID tracked
// for a provider up to the latest absorption ID, for a given asset.
// We need to iterate from the last absorption ID upwards to the current absorption ID in order to take
// into account the conversion rate of shares from epoch to epoch.
func get_absorbed_assets_for_provider_inner_loop{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    provided_shares: wad,
    current_epoch: ufelt,
    start_absorption_id: ufelt,
    end_absorption_id: ufelt,
    asset: address,
    cumulative: ufelt,
) -> ufelt {
    alloc_locals;

    if (start_absorption_id == end_absorption_id) {
        return cumulative;
    }
    let next_absorption_id: ufelt = start_absorption_id + 1;
    let absorption: Absorption = absorber_absorption.read(next_absorption_id);

    // If `current_epoch == absorption_epoch`, then `adjusted_shares == provided_shares`.
    let adjusted_shares: wad = convert_epoch_shares(
        current_epoch, absorption.epoch, provided_shares
    );

    // Terminate if provider does not have any shares for current epoch,
    if (adjusted_shares == 0) {
        return cumulative;
    }

    let asset_absorption_info: AssetAbsorption = get_asset_absorption(asset, next_absorption_id);
    let provider_assets: ufelt = WadRay.wmul(
        adjusted_shares, asset_absorption_info.asset_amt_per_share
    );

    return get_absorbed_assets_for_provider_inner_loop(
        adjusted_shares,
        absorption.epoch,
        next_absorption_id,
        end_absorption_id,
        asset,
        cumulative + provider_assets,
    );
}

//
// Internal - helpers for asset transfers
//

// Helper function to iterate over an array of assets to transfer to an address
func transfer_assets{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    recipient: address, asset_count: ufelt, assets: address*, asset_amts: ufelt*
) {
    if (asset_count == 0) {
        return ();
    }
    transfer_asset(recipient, [assets], [asset_amts]);
    return transfer_assets(recipient, asset_count - 1, assets + 1, asset_amts + 1);
}

// Helper function to transfer an asset to an address
func transfer_asset{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    recipient: address, asset_address: address, asset_amt: ufelt
) {
    if (asset_amt == 0) {
        return ();
    }

    let asset_amt_uint: Uint256 = WadRay.to_uint(asset_amt);
    IERC20.transfer(asset_address, recipient, asset_amt_uint);

    return ();
}

//
// Internal - helpers for remove
//

func get_shrine_ltv_to_threshold{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    ) -> (ratio: ray) {
    let shrine: address = absorber_shrine.read();
    let (threshold: ray, value: wad) = IShrine.get_shrine_threshold_and_value(shrine);
    let (debt: wad) = IShrine.get_total_debt(shrine);

    let ltv: ray = WadRay.runsigned_div(debt, value);
    let ltv_to_threshold: ray = WadRay.runsigned_div(ltv, threshold);
    return (ltv_to_threshold,);
}

func assert_can_request{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine: address, provider: address, removal: Removal, current_interval: ufelt
) {
    alloc_locals;

    let (ltv_to_threshold: ray) = get_shrine_ltv_to_threshold();
    let (limit: ray) = absorber_removal_limit.read();
    with_attr error_message("Absorber: Relative LTV is above limit") {
        // We can use `assert_le` here because both values have been checked
        assert_le(ltv_to_threshold, limit);
    }

    with_attr error_message("Absorber: Previous removal has not been removed") {
        assert removal.shares = 0;
    }

    with_attr error_message("Absorber: Previous removal is pending") {
        // We can use `assert_le` here because intervals cannot be negative
        assert_le(removal.interval + REMOVAL_TIMELOCK_INTERVAL, current_interval);
    }

    return ();
}

func assert_can_remove{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine: address, provider: address, removal: Removal
) {
    with_attr error_message("Absorber: Nothing to remove") {
        assert_not_zero(removal.shares);
    }

    let (current_interval: ufelt) = IShrine.now(shrine);
    with_attr error_message("Absorber: Removal is not valid yet") {
        // We can use `assert_le` here because intervals cannot be negative
        assert_le(removal.interval + REMOVAL_TIMELOCK_INTERVAL, current_interval);
    }

    return ();
}

// Returns the latest amount of yin per share for the given epoch and interval
// `yin_per_share` should be initialised to `0`.
func get_last_yin_per_share{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    epoch: ufelt, interval: ufelt, absorption_id: ufelt, yin_per_share: wad
) -> wad {
    alloc_locals;

    if (absorption_id == 0) {
        return yin_per_share;
    }

    let current_absorption: Absorption = get_absorption_internal(absorption_id);
    if (current_absorption.epoch != epoch and current_absorption.interval != interval) {
        return yin_per_share;
    }

    return get_last_yin_per_share(
        epoch, interval, absorption_id + 1, current_absorption.after_yin_per_share
    );
}

// Returns the latest epoch and absorption ID in the given interval
// (e.g. absorber is drained multiple times in the same interval)
func get_latest_epoch_and_absorption_id_in_interval{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(current_epoch: ufelt, interval: ufelt, absorption_id: ufelt) -> (
    epoch: ufelt, absorption_id: ufelt
) {
    let current_absorption: Absorption = get_absorption_internal(absorption_id);

    // The recursive call is easier to reason about in a conditional branch
    if (current_absorption.interval == interval) {
        return get_latest_epoch_and_absorption_id_in_interval(
            current_absorption.epoch, interval, absorption_id + 1
        );
    }

    return (current_epoch, absorption_id);
}

// Returns the total amount of yin currently subject to absorptions
// `end_interval` should be called with `current_interval - 1`
func get_suspended_yin_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    current_interval: ufelt, end_interval: ufelt, yin: wad
) -> wad {
    if (current_interval == end_interval) {
        return yin;
    }

    let removed_shares_in_interval: wad = absorber_removed_shares.read(current_interval);
    let yin_per_share: wad = absorber_last_yin_per_share_for_interval.read(current_interval);
    let removed_yin: wad = WadRay.wmul(removed_shares_in_interval, yin_per_share);

    let cumulative_removed_yin: wad = WadRay.unsigned_sub(yin, removed_yin);

    return get_suspended_yin_loop(current_interval + 1, end_interval, cumulative_removed_yin);
}

func update_yin_per_share_for_interval{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(shrine: address, absorber: address, current_interval: ufelt) {
    let absorbable_yin_amt: wad = get_absorbable_yin();

    // TODO

    return ();
}
