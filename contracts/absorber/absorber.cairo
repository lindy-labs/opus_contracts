%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import assert_not_zero, split_felt, unsigned_div_rem
from starkware.cairo.common.math_cmp import is_nn_le
from starkware.cairo.common.uint256 import ALL_ONES, Uint256
from starkware.starknet.common.syscalls import get_caller_address, get_contract_address

from contracts.absorber.interface import IBlesser
from contracts.absorber.roles import AbsorberRoles
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
from contracts.lib.aliases import address, bool, packed, ray, ufelt, wad
from contracts.lib.convert import pack_felt
from contracts.lib.interfaces import IERC20
from contracts.lib.types import AssetApportion, Reward, Checkpoint, Provision
from contracts.lib.wad_ray import WadRay

// Constants

// If the amount of yin wad per share drops below this threshold, the epoch is incremented
// to reset the yin per share ratio to 1 : 1 parity for accounting. Otherwise, there will
// eventually be an overflow when converting yin to shares (and vice versa)
// as yin per share approaches 0.
const YIN_PER_SHARE_THRESHOLD = 10 ** 15;

// Shares to be minted without a provider to avoid first provider front-running
const INITIAL_SHARES = 10 ** 3;

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

// Mapping from a provider to a packed struct of
// 1. the last absorption ID accounted for
// 2. the last blessing ID accounted for
@storage_var
func absorber_provider_checkpoint(provider: address) -> (checkpoint: packed) {
}

// Mapping of address to a packed struct of
// 1. epoch in which the provider's shares are issued
// 2. number of shares for the provider in the above epoch
@storage_var
func absorber_provision(provider: address) -> (provision: packed) {
}

// Mapping from an absorption to its epoch
@storage_var
func absorber_absorption_epoch(absorption_id: ufelt) -> (epoch: ufelt) {
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

// Total number of reward tokens
// A reward token cannot be removed once added.
@storage_var
func absorber_rewards_count() -> (count: ufelt) {
}

@storage_var
func absorber_reward_id(reward: address) -> (id: ufelt) {
}

// Mapping from a reward token ID to its token address and vesting contract (blesser)
@storage_var
func absorber_rewards(idx: ufelt) -> (reward: Reward) {
}

// Blessings start from 1.
@storage_var
func absorber_blessings_count() -> (count: ufelt) {
}

// Mapping from an absorption to its epoch
@storage_var
func absorber_blessing_epoch(blessing_id: ufelt) -> (epoch: ufelt) {
}

// Mapping of a tuple of absorption ID and asset to a packed struct of
// 1. the amount of that asset in its decimal precision rewarded per share wad for a blessing
// 2. the rounding error from calculating (1) that is to be added to the next blessing
@storage_var
func absorber_asset_blessing(blessing_id: ufelt, asset: address) -> (info: packed) {
}

//
// Events
//

@event
func PurgerUpdated(old_address: address, new_address: address) {
}

@event
func RewardSet(asset: address, blesser: address, is_active: bool) {
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
    absorbed_assets_len: ufelt,
    absorbed_assets: address*,
    absorbed_asset_amts_len: ufelt,
    absorbed_asset_amts: ufelt*,
    blessed_assets_len: ufelt,
    blessed_assets: address*,
    blessed_asset_amts_len: wad,
    blessed_asset_amts: wad*,
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
) {
}

@event
func Invoke(
    assets_len: ufelt,
    assets: address*,
    asset_amts_len: ufelt,
    asset_amts: wad*,
    total_shares: wad,
    epoch: ufelt,
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
}(admin: address, shrine: address, sentinel: address) {
    AccessControl.initializer(admin);
    AccessControl._grant_role(AbsorberRoles.DEFAULT_ABSORBER_ADMIN_ROLE, admin);

    absorber_shrine.write(shrine);
    absorber_sentinel.write(sentinel);
    absorber_live.write(TRUE);
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
func get_rewards_count{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    count: ufelt
) {
    let count: ufelt = absorber_rewards_count.read();
    return (count,);
}

@view
func get_rewards{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    assets_len: ufelt,
    assets: address*,
    blessers_len: ufelt,
    blessers: address*,
    is_active_len: ufelt,
    is_active: bool*,
) {
    alloc_locals;

    let rewards_count: ufelt = absorber_rewards_count.read();
    let (assets: address*, blessers: address*, is_active: bool*) = get_rewards_internal(
        rewards_count
    );
    return (rewards_count, assets, rewards_count, blessers, rewards_count, is_active);
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
func get_blessings_count{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    count: ufelt
) {
    let count: ufelt = absorber_blessings_count.read();
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
func get_blessing_epoch{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    blessing_id: ufelt
) -> (epoch: ufelt) {
    let epoch: ufelt = absorber_blessing_epoch.read(blessing_id);
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
func get_provider_checkpoint{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address
) -> (checkpoint: Checkpoint) {
    let checkpoint: Checkpoint = get_checkpoint(provider);
    return (checkpoint,);
}

@view
func get_asset_absorption_info{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    asset: address, absorption_id: ufelt
) -> (info: AssetApportion) {
    let info: AssetApportion = get_asset_absorption(asset, absorption_id);
    return (info,);
}

@view
func get_asset_blessing_info{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    asset: address, blessing_id: ufelt
) -> (info: AssetApportion) {
    let info: AssetApportion = get_asset_blessing(asset, blessing_id);
    return (info,);
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
) -> (
    absorbed_assets_len: ufelt,
    absorbed_assets: address*,
    absorbed_asset_amts_len: ufelt,
    absorbed_asset_amts: ufelt*,
    blessed_assets_len: ufelt,
    blessed_assets: address*,
    blessed_asset_amts_len: wad,
    blessed_asset_amts: wad*,
) {
    alloc_locals;

    let provision: Provision = get_provision(provider);
    let checkpoint: Checkpoint = get_provider_checkpoint(provider);

    let current_absorption_id: ufelt = absorber_absorptions_count.read();
    let (
        absorbed_assets_len, absorbed_assets: address*, absorbed_asset_amts: ufelt*
    ) = get_apportioned_assets_for_provider_internal(
        provider, provision, checkpoint.last_absorption_id, current_absorption_id, TRUE
    );

    let current_blessing_id: ufelt = absorber_blessings_count.read();
    let (
        blessed_assets_len, blessed_assets: address*, blessed_asset_amts: ufelt*
    ) = get_apportioned_assets_for_provider_internal(
        provider, provision, checkpoint.last_blessing_id, current_blessing_id, FALSE
    );

    return (
        absorbed_assets_len,
        absorbed_assets,
        absorbed_assets_len,
        absorbed_asset_amts,
        blessed_assets_len,
        blessed_assets,
        blessed_assets_len,
        blessed_asset_amts,
    );
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
func set_reward{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(asset: address, blesser: address, is_active: bool) {
    AccessControl.assert_has_role(AbsorberRoles.SET_REWARD);

    let reward: Reward = Reward(asset, blesser, is_active);

    let (reward_id: ufelt) = absorber_reward_id.read(asset);
    if (reward_id == 0) {
        let prev_count: ufelt = absorber_rewards_count.read();
        let new_count: ufelt = prev_count + 1;

        absorber_rewards_count.write(new_count);
        absorber_reward_id.write(asset, new_count);
        absorber_rewards.write(new_count, reward);

        RewardSet.emit(asset, blesser, is_active);
        return ();
    }

    absorber_rewards.write(reward_id, reward);
    RewardSet.emit(asset, blesser, is_active);

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

// Withdraw yin (if any) and all absorbed collateral assets from the absorber.
@external
func remove{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(amount: wad) {
    alloc_locals;

    with_attr error_message("Absorber: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    let provider: address = get_caller_address();
    let provision: Provision = get_provision(provider);

    // Early termination if caller is not a provider
    with_attr error_message("Absorber: Caller is not a provider") {
        assert_not_zero(provision.shares);
    }

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
        let new_provider_shares: wad = WadRay.unsigned_sub(
            current_provider_shares, shares_to_remove
        );
        let new_provision: Provision = Provision(current_epoch, new_provider_shares);
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
// Note that `reap` alone will not update a caller's Provision in storage
@external
func reap{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    alloc_locals;

    let provider: address = get_caller_address();
    let provision: Provision = get_provision(provider);

    with_attr error_message("Absorber: Caller is not a provider") {
        assert_not_zero(provision.shares);
    }

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

    // Trigger issuance of rewards
    invoke();

    // Increment absorption ID
    let prev_absorption_id: ufelt = absorber_absorptions_count.read();
    let current_apportion_id: ufelt = prev_absorption_id + 1;
    absorber_absorptions_count.write(current_apportion_id);

    // Update epoch for absorption ID
    let current_epoch: ufelt = absorber_current_epoch.read();
    absorber_absorption_epoch.write(current_apportion_id, current_epoch);

    // Loop through assets and calculate amount entitled per share
    let total_shares: wad = absorber_total_shares.read();
    apportion_assets_loop(current_apportion_id, total_shares, assets_len, assets, asset_amts, TRUE);

    // Emit `Gain` event
    Gain.emit(assets_len, assets, asset_amts_len, asset_amts, total_shares, current_epoch);

    // Increment epoch ID if yin per share drops below threshold or stability pool is emptied
    let shrine: address = absorber_shrine.read();
    let absorber: address = get_contract_address();
    let yin_balance_uint: Uint256 = IERC20.balanceOf(shrine, absorber);
    let yin_balance: wad = WadRay.from_uint(yin_balance_uint);
    let yin_per_share: wad = WadRay.wunsigned_div_unchecked(yin_balance, total_shares);

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
    let above_initial_shares: bool = is_nn_le(INITIAL_SHARES, yin_balance);
    if (above_initial_shares == TRUE) {
        tempvar yin_balance_for_shares: wad = yin_balance - INITIAL_SHARES;
    } else {
        tempvar yin_balance_for_shares: wad = yin_balance;
    }

    let epoch_share_conversion_rate: ray = WadRay.runsigned_div_unchecked(
        yin_balance_for_shares, total_shares
    );

    // If absorber is emptied, this will be set to 0.
    absorber_epoch_share_conversion_rate.write(current_epoch, epoch_share_conversion_rate);

    // If absorber is emptied, this will be set to 0.
    absorber_total_shares.write(yin_balance);
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
// Internal - helpers for packed structs
//

func get_checkpoint{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address
) -> (checkpoint: Checkpoint) {
    let (checkpoint_packed: packed) = absorber_provider_checkpoint.read(provider);
    let (last_absorption_id: ufelt, last_blessing_id: ufelt) = split_felt(checkpoint_packed);
    let checkpoint: Checkpoint = Checkpoint(
        last_absorption_id=last_absorption_id, last_blessing_id=last_blessing_id
    );
    return (checkpoint,);
}

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
    asset: address, absorption_id: ufelt
) -> (info: AssetApportion) {
    let (info_packed: packed) = absorber_asset_absorption.read(absorption_id, asset);
    let (asset_amt_per_share: wad, error: wad) = split_felt(info_packed);
    let info: AssetApportion = AssetApportion(asset_amt_per_share=asset_amt_per_share, error=error);
    return (info,);
}

func get_asset_blessing{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    asset: address, blessing_id: ufelt
) -> (info: AssetApportion) {
    let (info_packed: packed) = absorber_asset_blessing.read(blessing_id, asset);
    let (asset_amt_per_share: wad, error: wad) = split_felt(info_packed);
    let info: AssetApportion = AssetApportion(asset_amt_per_share=asset_amt_per_share, error=error);
    return (info,);
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

        // replicate `WadRay.wunsigned_div_unchecked` to check remainder of integer division
        let (computed_shares: wad, r: wad) = unsigned_div_rem(yin_amt * total_shares, yin_balance);
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
        let yin: wad = WadRay.wunsigned_div_unchecked(
            WadRay.wmul(shares_amt, yin_balance), total_shares
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

    // `rmul` of a wad an a ray returns a wad
    let new_shares: wad = WadRay.rmul(start_shares, epoch_conversion_rate);

    return convert_epoch_shares(start_epoch + 1, end_epoch, new_shares);
}

//
// Internal - helpers for `update`
//

// Helper function to iterate over an array of assets received from an absorption or blessing for updating
// each provider's entitlement
// `apportion_id` is either an absorption ID or a blessing ID
func apportion_assets_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    apportion_id: ufelt,
    total_shares: wad,
    asset_count: ufelt,
    assets: address*,
    amounts: ufelt*,
    is_absorption: bool,
) {
    if (asset_count == 0) {
        return ();
    }
    apportion_asset(apportion_id, total_shares, [assets], [amounts], is_absorption);
    return apportion_assets_loop(
        apportion_id, total_shares, asset_count - 1, assets + 1, amounts + 1, is_absorption
    );
}

// Helper function to update each provider's entitlement of an absorbed asset
// `apportion_id` is either an absorption ID or a blessing ID
func apportion_asset{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    apportion_id: ufelt, total_shares: wad, asset: address, amount: ufelt, is_absorption: bool
) {
    if (amount == 0) {
        return ();
    }

    let last_error: wad = get_recent_asset_apportion_error(asset, apportion_id, is_absorption);

    let total_amount_to_distribute: wad = WadRay.unsigned_add(amount, last_error);

    let asset_amt_per_share: wad = WadRay.wunsigned_div(total_amount_to_distribute, total_shares);
    let actual_amount_distributed: wad = WadRay.wmul(asset_amt_per_share, total_shares);
    let error: wad = WadRay.unsigned_sub(total_amount_to_distribute, actual_amount_distributed);

    let packed_asset_apportion: packed = pack_felt(asset_amt_per_share, error);

    if (is_absorption == TRUE) {
        absorber_asset_absorption.write(apportion_id, asset, packed_asset_apportion);
    } else {
        absorber_asset_blessing.write(apportion_id, asset, packed_asset_apportion);
    }

    return ();
}

// `apportion_id` is either an absorption ID or a blessing ID
// Returns the last error for an asset at a given `apportion_id` if the packed value is non-zero.
// Otherwise, check `apportion_id - 1` recursively for the last error.
// Return type is `ufelt` for absorptions, and `wad` for blessings.
func get_recent_asset_apportion_error{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(asset: address, apportion_id: ufelt, is_absorption: bool) -> (error: ufelt) {
    if (apportion_id == 0) {
        return (0,);
    }

    if (is_absorption == TRUE) {
        let (packed_info: packed) = absorber_asset_absorption.read(apportion_id, asset);
        tempvar packed_info = packed_info;
    } else {
        let (packed_info: packed) = absorber_asset_blessing.read(apportion_id, asset);
        tempvar packed_info = packed_info;
    }

    if (packed_info != 0) {
        let (_, error: wad) = split_felt(packed_info);
        return (error,);
    }

    return get_recent_asset_apportion_error(asset, apportion_id - 1, is_absorption);
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

    let checkpoint: Checkpoint = get_provider_checkpoint(provider);

    let current_absorption_id: ufelt = absorber_absorptions_count.read();
    let current_blessing_id: ufelt = absorber_blessings_count.read();

    // This should be updated before early return so that first provision by a new
    // address is properly updated.
    let new_checkpoint: packed = pack_felt(current_absorption_id, current_blessing_id);
    absorber_provider_checkpoint.write(provider, new_checkpoint);

    // Trigger issuance of rewards
    invoke();

    // Loop over absorbed assets and transfer
    let (
        absorbed_assets_len: ufelt, absorbed_assets: address*, absorbed_asset_amts: ufelt*
    ) = get_apportioned_assets_for_provider_internal(
        provider, provision, checkpoint.last_absorption_id, current_absorption_id, TRUE
    );
    transfer_assets(provider, absorbed_assets_len, absorbed_assets, absorbed_asset_amts);

    // Loop over absorbed assets and transfer
    let (
        blessed_assets_len: ufelt, blessed_assets: address*, blessed_asset_amts: wad*
    ) = get_apportioned_assets_for_provider_internal(
        provider, provision, checkpoint.last_blessing_id, current_blessing_id, FALSE
    );
    transfer_assets(provider, blessed_assets_len, blessed_assets, blessed_asset_amts);

    Reap.emit(
        provider,
        absorbed_assets_len,
        absorbed_assets,
        absorbed_assets_len,
        absorbed_asset_amts,
        blessed_assets_len,
        blessed_assets,
        blessed_assets_len,
        blessed_asset_amts,
    );

    return ();
}

// Internal function to calculate the apportioned assets that a provider is entitled to
// `apportion_id` is either an absorption ID or a blessing ID
func get_apportioned_assets_for_provider_internal{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    provider: address,
    provision: Provision,
    provided_apportion_id: ufelt,
    current_apportion_id: ufelt,
    is_absorption: bool,
) -> (assets_len: ufelt, assets: address*, asset_amts: ufelt*) {
    alloc_locals;

    let (asset_amts: ufelt*) = alloc();

    // Early termination by returning empty arrays
    if (provision.shares == 0) {
        return (0, asset_amts, asset_amts);
    }

    if (current_apportion_id == provided_apportion_id) {
        return (0, asset_amts, asset_amts);
    }

    if (is_absorption == TRUE) {
        let sentinel: address = absorber_sentinel.read();
        let (assets_len: ufelt, assets: address*) = ISentinel.get_yang_addresses(sentinel);

        get_apportioned_assets_for_provider_outer_loop(
            provision,
            provided_apportion_id,
            current_apportion_id,
            assets_len,
            0,
            assets,
            asset_amts,
            is_absorption,
        );

        return (assets_len, assets, asset_amts);
    } else {
        let assets_len: ufelt = absorber_rewards_count.read();
        let (assets: address*, _, _) = get_rewards_internal(assets_len);

        get_apportioned_assets_for_provider_outer_loop(
            provision,
            provided_apportion_id,
            current_apportion_id,
            assets_len,
            0,
            assets,
            asset_amts,
            is_absorption,
        );

        return (assets_len, assets, asset_amts);
    }
}

// Outer loop iterating over yangs
// Since we can only write to an array once, we need to compute
// the total amount to transfer for a given asset across all apportion IDs.
// `apportion_id` is either an absorption ID or a blessing ID
// Therefore, we iterate over yangs first.
func get_apportioned_assets_for_provider_outer_loop{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    provision: Provision,
    last_apportion_id: ufelt,
    current_apportion_id: ufelt,
    asset_count: ufelt,
    asset_idx: ufelt,
    assets: address*,
    asset_amts: ufelt*,
    is_absorption: bool,
) {
    alloc_locals;

    if (asset_count == asset_idx) {
        return ();
    }

    let asset: address = assets[asset_idx];
    let asset_amt: ufelt = get_apportioned_assets_for_provider_inner_loop(
        provision.shares,
        provision.epoch,
        last_apportion_id,
        current_apportion_id,
        asset,
        0,
        is_absorption,
    );

    assert asset_amts[asset_idx] = asset_amt;

    return get_apportioned_assets_for_provider_outer_loop(
        provision,
        last_apportion_id,
        current_apportion_id,
        asset_count,
        asset_idx + 1,
        assets,
        asset_amts,
        is_absorption,
    );
}

// `apportion_id` is either an absorption ID or a blessing ID
// Inner loop iterating over apportion IDs starting from the ID right after the last apportion ID tracked
// for a provider up to the latest apportion ID, for a given asset.
// We need to iterate from the last apportion ID upwards to the current apportion ID in order to take
// into account the conversion rate of shares from epoch to epoch.
func get_apportioned_assets_for_provider_inner_loop{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    provided_shares: wad,
    current_epoch: ufelt,
    start_apportion_id: ufelt,
    end_apportion_id: ufelt,
    asset: address,
    cumulative: ufelt,
    is_absorption: bool,
) -> ufelt {
    alloc_locals;

    if (start_apportion_id == end_apportion_id) {
        return cumulative;
    }
    let next_apportion_id: ufelt = start_apportion_id + 1;
    let apportion_epoch = get_apportion_epoch(next_apportion_id, is_absorption);

    // If `current_epoch == apportion_epoch`, then `adjusted_shares == provided_shares`.
    let adjusted_shares: wad = convert_epoch_shares(
        current_epoch, apportion_epoch, provided_shares
    );

    // Terminate if provider does not have any shares for current epoch,
    if (adjusted_shares == 0) {
        return cumulative;
    }

    if (is_absorption == TRUE) {
        let asset_absorption_info: AssetApportion = get_asset_absorption(asset, next_apportion_id);
        let provider_assets: ufelt = WadRay.wmul(
            adjusted_shares, asset_absorption_info.asset_amt_per_share
        );
    } else {
        let asset_absorption_info: AssetApportion = get_asset_blessing(asset, next_apportion_id);
        let provider_assets: ufelt = WadRay.wmul(
            adjusted_shares, asset_absorption_info.asset_amt_per_share
        );
    }

    return get_apportioned_assets_for_provider_inner_loop(
        adjusted_shares,
        apportion_epoch,
        next_apportion_id,
        end_apportion_id,
        asset,
        cumulative + provider_assets,
        is_absorption,
    );
}

// Helper function to return the epoch for an apportion ID to avoid revoked references
// `apportion_id` is either an absorption ID or a blessing ID
func get_apportion_epoch{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    apportion_id: ufelt, is_absorption: bool
) -> ufelt {
    if (is_absorption == TRUE) {
        let absorption_epoch: ufelt = absorber_absorption_epoch.read(apportion_id);
        return absorption_epoch;
    }
    let blessing_epoch: ufelt = absorber_blessing_epoch.read(apportion_id);
    return blessing_epoch;
}

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

func assert_live{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    // Check system is live
    let (is_live: bool) = absorber_live.read();
    with_attr error_message("Absorber: Absorber is not live") {
        assert is_live = TRUE;
    }
    return ();
}

// Helper function to fetch all rewards as an array
func get_rewards_internal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    rewards_count: ufelt
) -> (assets: address*, blessers: address*, is_active: bool*) {
    alloc_locals;

    let (assets: address*) = alloc();
    let (blessers: address*) = alloc();
    let (is_active: bool*) = alloc();

    get_rewards_internal_loop(rewards_count, assets, blessers, is_active);

    return (assets, blessers, is_active);
}

func get_rewards_internal_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    rewards_count: ufelt, assets: address*, blessers: address*, is_active: bool*
) {
    if (rewards_count == 0) {
        return ();
    }

    let reward: Reward = absorber_rewards.read(rewards_count);
    assert [assets] = reward.asset;
    assert [blessers] = reward.blesser;
    assert [is_active] = reward.is_active;

    return get_rewards_internal_loop(rewards_count - 1, assets + 1, blessers + 1, is_active + 1);
}

// Helper function to trigger issuance of reward tokens and update rewards received
func invoke{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    alloc_locals;

    let blessings_count: ufelt = absorber_blessings_count.read();

    // Increment blessing ID
    let prev_blessing_id: ufelt = absorber_blessings_count.read();
    let current_blessing_id: ufelt = prev_blessing_id + 1;
    absorber_blessings_count.write(current_blessing_id);

    // Update epoch for absorption ID
    let current_epoch: ufelt = absorber_current_epoch.read();
    absorber_blessing_epoch.write(current_blessing_id, current_epoch);

    // Retrieve arrays of reward tokens and their vesting contracts
    let (assets: address*, blessers: address*, is_active: bool*) = get_rewards_internal(
        blessings_count
    );

    // Loop through reward tokens and call `IBlesser.bless` to get amounts
    let (blessed_amts: wad*) = alloc();
    invoke_loop(blessings_count, blessers, is_active, blessed_amts);

    // Loop through reward tokens and calculate amount entitled per share
    let total_shares: wad = absorber_total_shares.read();
    apportion_assets_loop(
        current_blessing_id, total_shares, blessings_count, assets, blessed_amts, FALSE
    );

    // Emit `Invoke` event
    Invoke.emit(
        blessings_count, assets, blessings_count, blessed_amts, total_shares, current_epoch
    );

    return ();
}

// Helper function to loop over vesting contracts and trigger an issuance of reward tokens
func invoke_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    blessings_count: ufelt, blessers: address*, is_active: bool*, blessed_amts: wad*
) {
    if (blessings_count == 0) {
        return ();
    }

    let should_invoke: bool = [is_active];
    if (should_invoke == FALSE) {
        assert [blessed_amts] = 0;
        return invoke_loop(blessings_count - 1, blessers + 1, is_active + 1, blessed_amts + 1);
    }

    let (blessed_amt: wad) = IBlesser.bless([blessers]);
    assert [blessed_amts] = blessed_amt;

    return invoke_loop(blessings_count - 1, blessers + 1, is_active + 1, blessed_amts + 1);
}
