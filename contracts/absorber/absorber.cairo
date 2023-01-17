%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero, split_felt, unsigned_div_rem
from starkware.cairo.common.math_cmp import is_nn_le
from starkware.cairo.common.uint256 import ALL_ONES, Uint256
from starkware.starknet.common.syscalls import get_caller_address, get_contract_address

from contracts.sentinel.interface import ISentinel

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
from contracts.lib.aliases import address, bool, packed, ufelt, wad
from contracts.lib.convert import pack_felt
from contracts.lib.interfaces import IERC20
from contracts.lib.wad_ray import WadRay

// Constants

// Epoch is incremented if the amount of yin wad per share drops below this threshold
// in order to reset yin per share ratio to parity for accounting. Otherwise, there will
// eventually be an overflow of total shares as yin per share drops
const YIN_PER_SHARE_THRESHOLD = 10 ** 9;

// Shares to be minted without a provider to avoid first provider front-running
const INITIAL_SHARES = 10 ** 3;

//
// Structs
//

struct Provision {
    epoch: ufelt,  // Epoch in which shares are issued
    shares: wad,  // Amount of shares for provider in the above epoch
}

struct AssetAbsorption {
    asset_amt_per_share: wad,  // Amount of asset in its decimal precision per share wad
    error: wad,  // Error to be added to next absorption
}

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

// Epoch starts from 0.
@storage_var
func absorber_current_epoch() -> (epoch: ufelt) {
}

// Absorptions start from 1.
// The initial value `0` is used as the terminating condition.
@storage_var
func absorber_absorptions_count() -> (absorption_id: ufelt) {
}

// Mapping from a provider to the last absorption ID accounted for
@storage_var
func absorber_provider_last_absorption(provider: address) -> (absorption_id: ufelt) {
}

// Mapping of address to Provision struct
@storage_var
func absorber_provision(provider: address) -> (provision: packed) {
}

// Mapping from an absorption to its epoch
@storage_var
func absorber_absorption_epoch(absorption_id: ufelt) -> (epoch: ufelt) {
}

// Total number of shares
@storage_var
func absorber_total_shares() -> (deposit_id: ufelt) {
}

// Mapping of a tuple of absorption ID and asset to its distribution
@storage_var
func absorber_asset_absorption(absorption_id: ufelt, asset: address) -> (info: packed) {
}

// Conversion rate of an epoch's shares to the next
// If an update causes the yin per share to drop below the threshold,
// the epoch is incremented and yin per share is reset to one wad.
// A user with shares in that epoch will receive new shares in the next epoch
// based on this conversion rate.
// If the absorber's yin balance is wiped out, the conversion rate will be 0.
@storage_var
func absorber_epoch_share_conversion_rate(before: ufelt) -> (rate: wad) {
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
func Provide(provider: address, epoch: ufelt, yin: wad) {
}

@event
func Remove(provider: address, epoch: ufelt, yin: wad) {
}

@event
func Reap(
    provider: address,
    asset_addresses_len: ufelt,
    asset_addresses: address*,
    asset_amts_len: ufelt,
    asset_amts: ufelt*,
) {
}

@event
func Gain(
    asset_addresses_len: ufelt,
    asset_addresses: address*,
    asset_amts_len: ufelt,
    asset_amts: wad*,
    total_shares: wad,
    epoch: ufelt,
) {
}

//
// Constructor
//

@constructor
func constructor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    admin: address, shrine: address, sentinel: address
) {
    AccessControl.initializer(admin);
    absorber_shrine.write(shrine);
    absorber_sentinel.write(sentinel);
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
func get_absorption_epoch{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    absorption_id: ufelt
) -> (epoch: ufelt) {
    let epoch: ufelt = absorber_absorption_epoch.read(absorption_id);
    return (epoch,);
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
func get_asset_absorption_info{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    absorption_id: ufelt, asset: address
) -> (info: AssetAbsorption) {
    let info: AssetAbsorption = get_asset_absorption(absorption_id, asset);
    return (info,);
}

//
// View
//

@view
func get_max_removable_yin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address
) -> (amount: wad) {
    let provision: Provision = get_provision(provider);
    let max_removable_yin: wad = convert_to_yin(provision.shares);
    return (max_removable_yin,);
}

//
// Setters
//

@external
func set_purger{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(purger: address) {
    alloc_locals;

    AccessControl.assert_admin();

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

//
// External
//

// Supply yin to the absorber.
// Requires the caller to have approved spending by the absorber.
@external
func provide{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(amount: wad) {
    alloc_locals;

    with_attr error_message("Absorber: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    let provider: address = get_caller_address();

    // Withdraw absorbed collateral before updating shares
    let provision: Provision = get_provision(provider);
    reap_internal(provider, provision.shares, provision.epoch);

    // Calculate number of shares to issue to user and to add to total for current epoch
    // There is a discrepancy between these two due to the initial minimum shares only if
    // it is the first provision of an epoch and total shares is 0.
    let (new_provider_shares: wad, issued_shares: wad) = convert_to_shares(amount, FALSE);

    // If epoch has changed, convert shares in previous epoch to new epoch's shares
    let current_epoch: ufelt = absorber_current_epoch.read();
    let converted_shares: wad = convert_epoch_shares(
        provision.epoch, current_epoch, provision.shares
    );

    let new_shares: wad = WadRay.unsigned_add(converted_shares, new_provider_shares);
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

// Withdraw yin (if any) and all absorbed collateral assets from the absorber.
@external
func remove{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(amount: wad) {
    alloc_locals;

    with_attr error_message("Absorber: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    let provider: address = get_caller_address();
    let provision: Provision = get_provision(provider);

    // Early termination if user is not a provider
    with_attr error_message("Absorber: Caller is not a provider") {
        assert_not_zero(provision.shares);
    }

    // Withdraw absorbed collateral before updating shares
    reap_internal(provider, provision.shares, provision.epoch);

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

        Remove.emit(provider, current_epoch, 0);

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

        let prev_total_shares: wad = absorber_total_shares.read();
        let new_total_shares: wad = WadRay.unsigned_sub(prev_total_shares, shares_to_remove);
        absorber_total_shares.write(new_total_shares);

        // Update provision
        let new_user_shares: wad = WadRay.unsigned_sub(current_provider_shares, shares_to_remove);
        let new_provision: Provision = Provision(current_epoch, new_user_shares);
        set_provision(provider, new_provision);

        let yin_amt_uint: Uint256 = WadRay.to_uint(yin_amt);
        let shrine: address = absorber_shrine.read();
        with_attr error_message("Absorber: Transfer of yin failed") {
            let (success: bool) = IERC20.transfer(shrine, provider, yin_amt_uint);
            assert success = TRUE;
        }
        Remove.emit(provider, current_epoch, yin_amt);

        return ();
    }
}

// Withdraw absorbed collateral only from the absorber
// Note that `reap` alone will not update a user's Provision in storage
@external
func reap{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    alloc_locals;

    let provider: address = get_caller_address();
    let provision: Provision = get_provision(provider);

    with_attr error_message("Absorber: Caller is not a provider") {
        assert_not_zero(provision.shares);
    }

    reap_internal(provider, provision.shares, provision.epoch);

    return ();
}

// Update assets received after an absorption
// Can only be called by Purger
@external
func update{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    asset_addresses_len: ufelt, asset_addresses: address*, asset_amts_len: ufelt, asset_amts: ufelt*
) {
    alloc_locals;

    // Purger is not set during deployment
    let purger: address = absorber_purger.read();
    with_attr error_message("Absorber: Purger address cannot be zero") {
        assert_not_zero(purger);
    }

    let caller: address = get_caller_address();
    with_attr error_message("Absorber: Only Purger can call `update`") {
        assert caller = purger;
    }

    // Increment absorption ID
    let prev_absorption_id: ufelt = absorber_absorptions_count.read();
    let current_absorption_id: ufelt = prev_absorption_id + 1;
    absorber_absorptions_count.write(current_absorption_id);

    // Update epoch for absorption ID
    let current_epoch: ufelt = absorber_current_epoch.read();
    absorber_absorption_epoch.write(current_absorption_id, current_epoch);

    // Loop through assets and calculate amount entitled per share
    let total_shares: wad = absorber_total_shares.read();
    update_asset_loop(
        current_absorption_id, total_shares, asset_addresses_len, asset_addresses, asset_amts
    );

    // Emit `Gain` event
    Gain.emit(
        asset_addresses_len,
        asset_addresses,
        asset_amts_len,
        asset_amts,
        total_shares,
        current_epoch,
    );

    // Increment epoch ID if yin per share drops below threshold
    let shrine: address = absorber_shrine.read();
    let absorber: address = get_contract_address();
    let yin_balance_uint: Uint256 = IERC20.balanceOf(shrine, absorber);
    let yin_balance: wad = WadRay.from_uint(yin_balance_uint);
    let yin_per_share: wad = WadRay.wunsigned_div_unchecked(yin_balance, total_shares);

    let below_threshold: bool = is_nn_le(yin_per_share, YIN_PER_SHARE_THRESHOLD);

    if (below_threshold == TRUE) {
        let new_epoch: ufelt = current_epoch + 1;
        absorber_current_epoch.write(new_epoch);

        let epoch_share_conversion_rate: wad = WadRay.wunsigned_div_unchecked(
            yin_balance, total_shares
        );
        absorber_epoch_share_conversion_rate.write(current_epoch, epoch_share_conversion_rate);

        absorber_total_shares.write(yin_balance);
        EpochChanged.emit(current_epoch, new_epoch);
        return ();
    }

    // Increment epoch ID if stability pool is emptied and reset total shares
    if (yin_balance == 0) {
        // Note there is no need to update share conversion rate from current epoch
        // to next epoch if absorber is emptied.
        let new_epoch: ufelt = current_epoch + 1;
        absorber_current_epoch.write(new_epoch);
        absorber_total_shares.write(0);
        EpochChanged.emit(current_epoch, new_epoch);
        return ();
    }

    return ();
}

//
// Internal
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

func get_asset_absorption{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    absorption_id: ufelt, asset: address
) -> (info: AssetAbsorption) {
    let (info_packed: packed) = absorber_asset_absorption.read(absorption_id, asset);
    let (asset_amt_per_share: wad, error: wad) = split_felt(info_packed);
    let info: AssetAbsorption = AssetAbsorption(
        asset_amt_per_share=asset_amt_per_share, error=error
    );
    return (info,);
}

func set_asset_absorption{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    absorption_id: ufelt, asset: address, info: AssetAbsorption
) {
    let packed_info: packed = pack_felt(info.asset_amt_per_share, info.error);
    absorber_asset_absorption.write(absorption_id, asset, packed_info);
    return ();
}

// Convert to shares with a flag for whether the value should be rounded up or rounded down.
// When converting to shares, we always favour the Absorber to the expense of the provider.
// - Round down for `provide` (default for integer division)
// - Round up for `remove`
// Returns a tuple of the shares to be issued to the provider, and the total number of shares
// issued for the system.
// - `remove` does not require the former, which is meant to handle the first `provide` of an epoch.
func convert_to_shares{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yin_amt: wad, round_up: bool
) -> (provider_shares: wad, system_shares: wad) {
    // Get last deposit
    let total_shares: wad = absorber_total_shares.read();

    // Convert
    if (total_shares == 0) {
        // This branch should be unreachable when called in `remove` because no address would have
        // any shares if total shares is 0
        with_attr error_message("Absorber: Amount provided is less than minimum initial shares") {
            let provider_shares: wad = WadRay.unsigned_sub(yin_amt, INITIAL_SHARES);
        }

        return (provider_shares, yin_amt);
    } else {
        // Get current exchange rate
        let shrine: address = absorber_shrine.read();
        let absorber: address = get_contract_address();
        let yin_balance_uint: Uint256 = IERC20.balanceOf(shrine, absorber);
        let yin_balance: wad = WadRay.from_uint(yin_balance_uint);

        // replicate `WadRay.wunsigned_div_unchecked` to check remainder of integer division
        let product: wad = WadRay.wmul(yin_amt, total_shares);
        let scaled_product: wad = product * WadRay.WAD_SCALE;
        let (computed_shares: wad, r: wad) = unsigned_div_rem(scaled_product, yin_balance);
        if (round_up == TRUE and r != 0) {
            return (computed_shares + 1, computed_shares + 1);
        }

        return (computed_shares, computed_shares);
    }
}

// This implementation is slightly different from Gate because shares is only used for
// internal accounting.
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
        let yin: wad = WadRay.wunsigned_div_unchecked(
            WadRay.wmul(shares_amt, yin_balance), total_shares
        );
        return yin;
    }
}

func update_asset_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    absorption_id: ufelt, total_shares: wad, asset_count: ufelt, assets: address*, amounts: ufelt*
) {
    if (asset_count == 0) {
        return ();
    }
    update_asset(absorption_id, total_shares, [assets], [amounts]);
    return update_asset_loop(absorption_id, total_shares, asset_count - 1, assets + 1, amounts + 1);
}

func update_asset{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    absorption_id: ufelt, shares: wad, asset: address, amount: ufelt
) {
    let last_error: wad = get_recent_asset_absorption_error(asset, absorption_id);
    let total_amount_to_distribute: wad = WadRay.unsigned_add(amount, last_error);

    let asset_amt_per_share: wad = WadRay.wunsigned_div(total_amount_to_distribute, shares);
    let actual_amount_distributed: wad = WadRay.wmul(asset_amt_per_share, shares);
    let error: wad = WadRay.unsigned_sub(total_amount_to_distribute, actual_amount_distributed);

    let asset_absorption: AssetAbsorption = AssetAbsorption(asset_amt_per_share, error);
    set_asset_absorption(absorption_id, asset, asset_absorption);

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

func reap_internal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address, provided_shares: wad, provided_epoch: ufelt
) {
    alloc_locals;

    let provider_last_absorption_id: ufelt = absorber_provider_last_absorption.read(provider);
    let current_absorption_id: ufelt = absorber_absorptions_count.read();

    // This should be updated before early return so that first provision by a new
    // address is properly updated.
    absorber_provider_last_absorption.write(provider, current_absorption_id);

    // Early termination
    if (provided_shares == 0) {
        return ();
    }

    if (current_absorption_id == provider_last_absorption_id) {
        return ();
    }

    let sentinel: address = absorber_sentinel.read();
    let (asset_addresses_len: ufelt, asset_addresses: address*) = ISentinel.get_yang_addresses(
        sentinel
    );
    let (asset_amts: ufelt*) = alloc();

    reap_absorbed_assets_outer_loop(
        provided_shares,
        provided_epoch,
        provider_last_absorption_id,
        current_absorption_id,
        asset_addresses_len,
        0,
        asset_addresses,
        asset_amts,
    );

    // Loop over assets and transfer
    transfer_assets(provider, asset_addresses_len, asset_addresses, asset_amts);

    Reap.emit(provider, asset_addresses_len, asset_addresses, asset_addresses_len, asset_amts);

    return ();
}

// Outer loop iterating over yangs
// We iterate over yangs first, because array values cannot be updated.
// Since we can only write the amount of asset to transfer once, we need to compute
// the total amount to transfer for a given asset across all absorption IDs.
func reap_absorbed_assets_outer_loop{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    provided_shares: wad,
    provided_epoch: ufelt,
    last_absorption_id: ufelt,
    current_absorption_id: ufelt,
    asset_count: ufelt,
    asset_idx: ufelt,
    asset_addresses: address*,
    asset_amts: ufelt*,
) {
    alloc_locals;

    if (asset_count == asset_idx) {
        return ();
    }

    let asset: address = asset_addresses[asset_idx];
    let asset_amt: ufelt = derive_absorbed_asset_amount(
        provided_shares, provided_epoch, last_absorption_id, current_absorption_id, asset, 0
    );

    assert asset_amts[asset_idx] = asset_amt;

    return reap_absorbed_assets_outer_loop(
        provided_shares,
        provided_epoch,
        last_absorption_id,
        current_absorption_id,
        asset_count,
        asset_idx + 1,
        asset_addresses,
        asset_amts,
    );
}

// Inner loop iterating over absorption IDs from the latest absorption ID down to the
// last absorption ID tracked for a user for a given asset
// We need to iterate from the last absorption ID upwards to the current absorption ID in order to take
// into account the conversion rate of shares from epoch to epoch
func derive_absorbed_asset_amount{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
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
    let absorption_epoch: ufelt = absorber_absorption_epoch.read(next_absorption_id);

    // If `current_epoch == absorption_epoch`, then `adjusted_shares == provided_shares`.
    let adjusted_shares: wad = convert_epoch_shares(
        current_epoch, absorption_epoch, provided_shares
    );

    // Terminate if provider does not have any shares for current epoch,
    if (adjusted_shares == 0) {
        return cumulative;
    }

    let asset_absorption_info: AssetAbsorption = get_asset_absorption(next_absorption_id, asset);

    // Skip to next absorption if no assets were absorbed for current absorption
    if (asset_absorption_info.asset_amt_per_share == 0) {
        return derive_absorbed_asset_amount(
            adjusted_shares,
            absorption_epoch,
            next_absorption_id,
            end_absorption_id,
            asset,
            cumulative,
        );
    }

    let provider_assets: ufelt = WadRay.wmul(
        adjusted_shares, asset_absorption_info.asset_amt_per_share
    );

    return derive_absorbed_asset_amount(
        adjusted_shares,
        absorption_epoch,
        next_absorption_id,
        end_absorption_id,
        asset,
        cumulative + provider_assets,
    );
}

func transfer_assets{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address, asset_count: ufelt, asset_addresses: address*, asset_amts: ufelt*
) {
    if (asset_count == 0) {
        return ();
    }
    transfer_asset(provider, [asset_addresses], [asset_amts]);
    return transfer_assets(provider, asset_count - 1, asset_addresses + 1, asset_amts + 1);
}

func transfer_asset{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address, asset_address: address, asset_amt: ufelt
) {
    let asset_amt_uint: Uint256 = WadRay.to_uint(asset_amt);

    // TODO: Should this revert?
    with_attr error_message("Absorber: Transfer of asset failed") {
        let (success: bool) = IERC20.transfer(asset_address, provider, asset_amt_uint);
        assert success = TRUE;
    }

    return ();
}

// Return argument is named for testing
func convert_epoch_shares{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    start_epoch: ufelt, end_epoch: ufelt, start_shares: wad
) -> (shares: wad) {
    if (start_epoch == end_epoch) {
        return (start_shares,);
    }

    let epoch_conversion_rate: wad = absorber_epoch_share_conversion_rate.read(start_epoch);
    let new_shares: wad = WadRay.wmul(start_shares, epoch_conversion_rate);

    return convert_epoch_shares(start_epoch + 1, end_epoch, new_shares);
}
