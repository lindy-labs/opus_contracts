%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import assert_le, assert_not_zero, split_felt, unsigned_div_rem
from starkware.cairo.common.math_cmp import is_le, is_nn_le, is_not_zero
from starkware.cairo.common.uint256 import ALL_ONES, Uint256
from starkware.starknet.common.syscalls import (
    get_block_timestamp,
    get_caller_address,
    get_contract_address,
)

from contracts.absorber.interface import IBlesser
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
from contracts.lib.convert import pack_felt, pack_125, unpack_125
from contracts.lib.interfaces import IERC20
from contracts.lib.types import AssetApportion, Provision, Request, Reward
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

// Amount of time, in seconds, that needs to elapse after request is submitted before removal
const REQUEST_BASE_TIMELOCK = 60;

// Upper bound of time, in seconds, that needs to elapse after request is submitted before removal
// 7 days * 24 hours per day * 60 minutes per hour * 60 seconds per minute
const REQUEST_MAX_TIMELOCK = 7 * 24 * 60 * 60;

// Multiplier for each request's timelock from the last value if a new request is submitted
// before the cooldown of the previous request has elapsed
const REQUEST_TIMELOCK_MULTIPLIER = 5;

// Amount of time, in seconds, for which a request is valid, starting from expiry of the timelock
// 60 minutes * 60 seconds per minute
const REQUEST_VALIDITY_PERIOD = 60 * 60;

// Amount of time that needs to elapse after a request is submitted before the timelock
// for the next request is reset to the base value.
// 7 days * 24 hours per day * 60 minutes per hour * 60 seconds per minute
const REQUEST_COOLDOWN = 7 * 24 * 60 * 60;

// Helper constant to set the starting index for iterating over the Rewards
// in the order they were added
const REWARDS_LOOP_START = 1;

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

// Total number of reward tokens, starting from 1
// A reward token cannot be removed once added.
@storage_var
func absorber_rewards_count() -> (count: ufelt) {
}

// Mapping from a reward token address to its id for iteration
@storage_var
func absorber_reward_id(asset: address) -> (id: ufelt) {
}

// Mapping from a reward token ID to its Reward struct:
// 1. the ERC-20 token address
// 2. the address of the vesting contract (blesser) implementing `IBlesser` for the ERC-20 token
// 3. a boolean indicating if the blesser should be called
@storage_var
func absorber_rewards(id: ufelt) -> (reward: Reward) {
}

// Mapping from a reward token address and epoch to a packed struct of
// 1. the cumulative amount of that reward asset in its decimal precision per share wad in that epoch
// 2. the rounding error from calculating (1) that is to be added to the next reward distribution
@storage_var
func absorber_reward_by_epoch(asset: address, epoch: ufelt) -> (info: packed) {
}

// Mapping from a provider and reward token address to its last cumulative amount of that reward
// per share wad in the epoch of the provider's Provision struct
@storage_var
func absorber_provider_last_reward_cumulative(provider: address, asset: address) -> (
    cumulative: ufelt
) {
}

// Removals are temporarily suspended if the shrine's LTV to threshold exceeds this limit
@storage_var
func absorber_removal_limit() -> (limit: ray) {
}

// Mapping from a provider to its latest request for removal
// TODO: to implement packing in Cairo 1
@storage_var
func absorber_provider_request(provider: address) -> (request: Request) {
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
func RemovalLimitUpdated(old_limit: ray, new_limit: ray) {
}

@event
func Provide(provider: address, epoch: ufelt, yin: wad) {
}

@event
func RequestSubmitted(provider: address, timestamp: ufelt, timelock: ufelt) {
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
    reward_assets_len: ufelt,
    reward_assets: address*,
    reward_asset_amts_len: ufelt,
    reward_asset_amts: ufelt*,
) {
}

@event
func Gain(
    assets_len: ufelt,
    assets: address*,
    asset_amts_len: ufelt,
    asset_amts: ufelt*,
    total_shares: wad,
    epoch: ufelt,
    absorption_id: ufelt,
) {
}

@event
func Bestow(
    assets_len: ufelt,
    assets: address*,
    asset_amts_len: ufelt,
    asset_amts: ufelt*,
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
func get_rewards_count{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    count: ufelt
) {
    let count: ufelt = absorber_rewards_count.read();
    return (count,);
}

@view
func get_rewards{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    rewards_len: ufelt, rewards: Reward*
) {
    alloc_locals;

    let rewards_count: ufelt = absorber_rewards_count.read();
    let rewards: Reward* = alloc();
    get_rewards_loop(REWARDS_LOOP_START, rewards_count, rewards);
    return (rewards_count, rewards);
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
func get_provider_request{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address
) -> (request: Request) {
    let request: Request = absorber_provider_request.read(provider);
    return (request,);
}

@view
func get_asset_absorption_info{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    asset: address, absorption_id: ufelt
) -> (info: AssetApportion) {
    let info: AssetApportion = get_asset_absorption(asset, absorption_id);
    return (info,);
}

@view
func get_asset_reward_info{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    asset: address, epoch: ufelt
) -> (info: AssetApportion) {
    let info: AssetApportion = get_asset_reward(asset, epoch);
    return (info,);
}

@view
func get_provider_last_reward_cumulative{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(provider: address, asset: address) -> (cumulative: ufelt) {
    let cumulative: ufelt = absorber_provider_last_reward_cumulative.read(provider, asset);
    return (cumulative,);
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
) -> (
    absorbed_assets_len: ufelt,
    absorbed_assets: address*,
    absorbed_asset_amts_len: ufelt,
    absorbed_asset_amts: ufelt*,
    reward_assets_len: ufelt,
    reward_assets: address*,
    reward_asset_amts_len: ufelt,
    reward_asset_amts: ufelt*,
) {
    alloc_locals;

    let provision: Provision = get_provision(provider);
    let provider_last_absorption_id: ufelt = absorber_provider_last_absorption.read(provider);
    let current_absorption_id: ufelt = absorber_absorptions_count.read();

    let (
        absorbed_assets_len: ufelt, absorbed_assets: address*, absorbed_asset_amts: ufelt*
    ) = get_absorbed_assets_for_provider_internal(
        provider, provision, provider_last_absorption_id, current_absorption_id
    );

    // Get accumulated rewards
    let rewards_count: ufelt = absorber_rewards_count.read();
    let current_epoch: ufelt = absorber_current_epoch.read();
    let (reward_assets: address*) = alloc();
    let (reward_asset_amts: ufelt*) = alloc();
    get_provider_accumulated_rewards(
        provider,
        provision,
        current_epoch,
        REWARDS_LOOP_START,
        rewards_count,
        reward_assets,
        reward_asset_amts,
    );

    // Add pending rewards
    let total_shares: wad = absorber_total_shares.read();
    let has_providers: bool = is_not_zero(total_shares);

    let current_provider_shares: wad = convert_epoch_shares(
        provision.epoch, current_epoch, provision.shares
    );
    let has_shares: bool = is_not_zero(current_provider_shares);

    let has_pending_rewards: bool = has_providers * has_shares;
    if (has_pending_rewards == FALSE) {
        return (
            absorbed_assets_len,
            absorbed_assets,
            absorbed_assets_len,
            absorbed_asset_amts,
            rewards_count,
            reward_assets,
            rewards_count,
            reward_asset_amts,
        );
    }

    let (updated_reward_asset_amts: ufelt*) = alloc();
    get_provider_pending_rewards(
        provider,
        current_provider_shares,
        total_shares,
        current_epoch,
        1,
        rewards_count,
        reward_asset_amts,
        updated_reward_asset_amts,
    );

    return (
        absorbed_assets_len,
        absorbed_assets,
        absorbed_assets_len,
        absorbed_asset_amts,
        rewards_count,
        reward_assets,
        rewards_count,
        updated_reward_asset_amts,
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

    with_attr error_message("Absorber: Address cannot be zero") {
        assert_not_zero(asset);
        assert_not_zero(blesser);
    }

    let reward: Reward = Reward(asset, blesser, is_active);

    let (reward_id: ufelt) = absorber_reward_id.read(asset);
    if (reward_id == 0) {
        let current_count: ufelt = absorber_rewards_count.read();
        let new_count: ufelt = current_count + 1;

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

@external
func set_removal_limit{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(limit: ray) {
    alloc_locals;

    AccessControl.assert_has_role(AbsorberRoles.SET_REMOVAL_LIMIT);
    set_removal_limit_internal(limit);

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

    let current_epoch: ufelt = absorber_current_epoch.read();
    let provider: address = get_caller_address();

    // Withdraw absorbed collateral before updating shares
    let provision: Provision = get_provision(provider);
    reap_internal(provider, provision, current_epoch);

    // Calculate number of shares to issue to provider and to add to total for current epoch
    // The two values deviate only when it is the first provision of an epoch and
    // total shares is below the minimum initial shares.
    let (new_provision_shares: wad, issued_shares: wad) = convert_to_shares(amount, FALSE);

    // If epoch has changed, convert shares in previous epoch to new epoch's shares
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

// Submit a request to `remove` that is valid for a fixed period of time after a variable timelock.
// - This is intended to prevent atomic removals to avoid risk-free yield (from rewards and interest)
//   frontrunning tactics.
//   The timelock increases if another request is submitted before the previous has cooled down.
// - A request is expended by either (1) a removal; (2) expiry; or (3) submitting a new request.
// - Note: A request may become valid in the next epoch if a provider in the previous epoch
//         submitted a request, a draining absorption occurs, and the provider provides again
//         in the next epoch. This is expected to be rare, and the maximum risk-free profit is
//         in any event greatly limited.
@external
func request{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    alloc_locals;

    let (provider: address) = get_caller_address();
    let provision: Provision = get_provision(provider);
    assert_provider(provision);

    let request: Request = absorber_provider_request.read(provider);
    let current_timestamp: ufelt = get_block_timestamp();

    // We can use `is_le` because timestamp cannot be negative
    let cooled_down: bool = is_le(request.timestamp + REQUEST_COOLDOWN, current_timestamp);
    if (cooled_down == TRUE) {
        tempvar timelock: ufelt = REQUEST_BASE_TIMELOCK;
    } else {
        tempvar timelock: ufelt = request.timelock * REQUEST_TIMELOCK_MULTIPLIER;
    }

    let capped_timelock: ufelt = WadRay.unsigned_min(timelock, REQUEST_MAX_TIMELOCK);
    let new_request: Request = Request(current_timestamp, capped_timelock, FALSE);
    absorber_provider_request.write(provider, new_request);
    RequestSubmitted.emit(provider, current_timestamp, capped_timelock);

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
    let request: Request = absorber_provider_request.read(provider);
    assert_provider(provision);
    assert_can_remove(request);

    let current_epoch: ufelt = absorber_current_epoch.read();

    // Withdraw absorbed collateral before updating shares
    reap_internal(provider, provision, current_epoch);

    // Fetch the shares for current epoch
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

        let request: Request = Request(request.timestamp, request.timelock, TRUE);
        absorber_provider_request.write(provider, request);

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

        let request: Request = Request(request.timestamp, request.timelock, TRUE);
        absorber_provider_request.write(provider, request);

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
    assert_provider(provision);

    let current_epoch: ufelt = absorber_current_epoch.read();

    reap_internal(provider, provision, current_epoch);

    // Update provider's epoch and shares to current epoch's
    // Epoch must be updated to prevent provider from repeatedly claiming rewards
    let current_provider_shares: wad = convert_epoch_shares(
        provision.epoch, current_epoch, provision.shares
    );
    let new_provision: Provision = Provision(current_epoch, current_provider_shares);
    set_provision(provider, new_provision);

    return ();
}

// Update assets received after an absorption
@external
func update{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(assets_len: ufelt, assets: address*, asset_amts_len: ufelt, asset_amts: ufelt*) {
    alloc_locals;

    AccessControl.assert_has_role(AbsorberRoles.UPDATE);

    let current_epoch: ufelt = absorber_current_epoch.read();

    // Trigger issuance of rewards
    let rewards_count: ufelt = absorber_rewards_count.read();
    bestow(current_epoch, rewards_count);

    // Increment absorption ID
    let prev_absorption_id: ufelt = absorber_absorptions_count.read();
    let current_absorption_id: ufelt = prev_absorption_id + 1;
    absorber_absorptions_count.write(current_absorption_id);

    // Update epoch for absorption ID
    absorber_absorption_epoch.write(current_absorption_id, current_epoch);

    // Loop through assets and calculate amount entitled per share
    let total_shares: wad = absorber_total_shares.read();
    update_absorbed_assets_loop(
        current_absorption_id, total_shares, assets_len, assets, asset_amts
    );

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

    // Transfer reward errors of current epoch to the next epoch
    propagate_reward_errors_loop(REWARDS_LOOP_START, rewards_count, current_epoch);

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
    with_attr error_message("Absorber: Caller is not a provider in the current epoch") {
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

    let prev_limit: ray = absorber_removal_limit.read();
    absorber_removal_limit.write(limit);

    RemovalLimitUpdated.emit(prev_limit, limit);

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

func get_asset_absorption{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    asset: address, absorption_id: ufelt
) -> (info: AssetApportion) {
    alloc_locals;

    let (info_packed: packed) = absorber_asset_absorption.read(absorption_id, asset);
    let (asset_amt_per_share: ufelt, error: ufelt) = unpack_125(info_packed);
    let info: AssetApportion = AssetApportion(asset_amt_per_share=asset_amt_per_share, error=error);
    return (info,);
}

func get_asset_reward{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    asset: address, epoch: ufelt
) -> (info: AssetApportion) {
    alloc_locals;

    let (info_packed: packed) = absorber_reward_by_epoch.read(asset, epoch);
    let (asset_amt_per_share: ufelt, error: ufelt) = unpack_125(info_packed);
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

    // `rmul` of a wad and a ray returns a wad
    let new_shares: wad = WadRay.rmul(start_shares, epoch_conversion_rate);

    return convert_epoch_shares(start_epoch + 1, end_epoch, new_shares);
}

//
// Internal - helpers for `update`
//

// Helper function to iterate over an array of assets received from an absorption for updating
// each provider's entitlement
func update_absorbed_assets_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    absorption_id: ufelt, total_shares: wad, asset_count: ufelt, assets: address*, amounts: ufelt*
) {
    if (asset_count == 0) {
        return ();
    }
    update_absorbed_asset(absorption_id, total_shares, [assets], [amounts]);
    return update_absorbed_assets_loop(
        absorption_id, total_shares, asset_count - 1, assets + 1, amounts + 1
    );
}

// Helper function to update each provider's entitlement of an absorbed asset
func update_absorbed_asset{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    absorption_id: ufelt, total_shares: wad, asset: address, amount: ufelt
) {
    if (amount == 0) {
        return ();
    }

    let last_error: ufelt = get_recent_asset_absorption_error(asset, absorption_id);
    let total_amount_to_distribute: ufelt = WadRay.unsigned_add(amount, last_error);

    let asset_amt_per_share: ufelt = WadRay.wunsigned_div(total_amount_to_distribute, total_shares);
    let actual_amount_distributed: ufelt = WadRay.wmul(asset_amt_per_share, total_shares);
    let error: ufelt = WadRay.unsigned_sub(total_amount_to_distribute, actual_amount_distributed);

    let packed_asset_absorption: packed = pack_125(asset_amt_per_share, error);
    absorber_asset_absorption.write(absorption_id, asset, packed_asset_absorption);

    return ();
}

// Returns the last error for an asset at a given `absorption_id` if the packed value is non-zero.
// Otherwise, check `absorption_id - 1` recursively for the last error.
func get_recent_asset_absorption_error{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(asset: address, absorption_id: ufelt) -> (error: ufelt) {
    alloc_locals;

    if (absorption_id == 0) {
        return (0,);
    }

    let (packed_info: packed) = absorber_asset_absorption.read(absorption_id, asset);
    if (packed_info != 0) {
        let (_, error: ufelt) = unpack_125(packed_info);
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
    provider: address, provision: Provision, current_epoch: ufelt
) {
    alloc_locals;

    // Trigger issuance of rewards
    let rewards_count: ufelt = absorber_rewards_count.read();
    bestow(current_epoch, rewards_count);

    let provider_last_absorption_id: ufelt = absorber_provider_last_absorption.read(provider);
    let current_absorption_id: ufelt = absorber_absorptions_count.read();

    // This should be updated before early return so that first provision by a new
    // address is properly updated.
    absorber_provider_last_absorption.write(provider, current_absorption_id);

    // Loop over absorbed assets and transfer
    let (
        absorbed_assets_len: ufelt, absorbed_assets: address*, absorbed_asset_amts: ufelt*
    ) = get_absorbed_assets_for_provider_internal(
        provider, provision, provider_last_absorption_id, current_absorption_id
    );
    transfer_assets(provider, absorbed_assets_len, absorbed_assets, absorbed_asset_amts);

    // Loop over accumulated rewards, transfer and update provider's rewards cumulative
    let (reward_assets: address*) = alloc();
    let (reward_asset_amts: ufelt*) = alloc();
    get_provider_accumulated_rewards(
        provider,
        provision,
        current_epoch,
        REWARDS_LOOP_START,
        rewards_count,
        reward_assets,
        reward_asset_amts,
    );
    transfer_assets(provider, rewards_count, reward_assets, reward_asset_amts);

    update_provider_cumulative_rewards_loop(
        provider, current_epoch, REWARDS_LOOP_START, rewards_count, reward_assets
    );

    Reap.emit(
        provider,
        absorbed_assets_len,
        absorbed_assets,
        absorbed_assets_len,
        absorbed_asset_amts,
        rewards_count,
        reward_assets,
        rewards_count,
        reward_asset_amts,
    );

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
    let absorption_epoch: ufelt = absorber_absorption_epoch.read(next_absorption_id);

    // If `current_epoch == absorption_epoch`, then `adjusted_shares == provided_shares`.
    let adjusted_shares: wad = convert_epoch_shares(
        current_epoch, absorption_epoch, provided_shares
    );

    // Terminate if provider does not have any shares for current epoch,
    if (adjusted_shares == 0) {
        return cumulative;
    }

    let asset_absorption_info: AssetApportion = get_asset_absorption(asset, next_absorption_id);
    let provider_assets: ufelt = WadRay.wmul(
        adjusted_shares, asset_absorption_info.asset_amt_per_share
    );

    return get_absorbed_assets_for_provider_inner_loop(
        adjusted_shares,
        absorption_epoch,
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

func assert_can_remove{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    request: Request
) {
    let (ltv_to_threshold: ray) = get_shrine_ltv_to_threshold();
    let (limit: ray) = absorber_removal_limit.read();
    with_attr error_message("Absorber: Relative LTV is above limit") {
        // We can use `assert_le` here because both values have been checked
        assert_le(ltv_to_threshold, limit);
    }

    let (current_timestamp: ufelt) = get_block_timestamp();

    with_attr error_message("Absorber: No request found") {
        assert_not_zero(request.timestamp);
    }

    with_attr error_message("Absorber: Only one removal per request") {
        assert request.has_removed = FALSE;
    }

    let removal_start_timestamp: ufelt = request.timestamp + request.timelock;
    with_attr error_message("Absorber: Request is not valid yet") {
        // We can use `assert_le` here because timestamp cannot be negative
        assert_le(removal_start_timestamp, current_timestamp);
    }

    with_attr error_message("Absorber: Request has expired") {
        // We can use `assert_le` here because timestamp cannot be negative
        assert_le(current_timestamp, removal_start_timestamp + REQUEST_VALIDITY_PERIOD);
    }

    return ();
}

//
// Internal - helpers for rewards
//

// Helper function to get all rewards in the Reward struct
// To get all rewards in the order in which they were added, `current_rewards_id` should be set to `1`.
func get_rewards_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    current_rewards_id: ufelt, rewards_count: ufelt, rewards: Reward*
) {
    // Terminate when the number of rewards is exceeded
    if (current_rewards_id == rewards_count + REWARDS_LOOP_START) {
        return ();
    }

    let reward: Reward = absorber_rewards.read(current_rewards_id);
    assert [rewards] = reward;

    return get_rewards_loop(current_rewards_id + 1, rewards_count, rewards + Reward.SIZE);
}

// Helper function to trigger issuance of reward tokens and update rewards received
func bestow{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    epoch: ufelt, rewards_count: ufelt
) {
    alloc_locals;

    // Defer rewards until at least one provider deposits
    let total_shares: wad = absorber_total_shares.read();
    if (total_shares == 0) {
        return ();
    }

    // Trigger issuance of active rewards
    let (reward_assets: address*) = alloc();
    let (blessed_amts: ufelt*) = alloc();
    let (active_rewards_count: ufelt, has_rewards: bool) = bestow_loop(
        epoch,
        total_shares,
        REWARDS_LOOP_START,
        rewards_count,
        reward_assets,
        blessed_amts,
        0,
        FALSE,
    );

    // Do not emit event if no rewards were distributed
    if (has_rewards == FALSE) {
        return ();
    }

    Bestow.emit(
        active_rewards_count, reward_assets, active_rewards_count, blessed_amts, total_shares, epoch
    );

    return ();
}

// Helper function to loop over vesting contracts and trigger an issuance of reward tokens
// and update the amount distributed per share wad.
// Returns a tuple of:
// 1. number of active rewards; and
// 2. boolean for whether the current round of blessings has any rewards
// It also writes the asset address and blessed amounts for active rewards to two respective arrays.
func bestow_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    epoch: ufelt,
    total_shares: wad,
    current_rewards_id: ufelt,
    rewards_count: ufelt,
    assets: address*,
    blessed_amts: ufelt*,
    active_rewards_count: ufelt,
    has_rewards: bool,
) -> (active_rewards_count: ufelt, has_rewards: bool) {
    alloc_locals;

    if (current_rewards_id == rewards_count + REWARDS_LOOP_START) {
        return (active_rewards_count, has_rewards);
    }

    let reward: Reward = absorber_rewards.read(current_rewards_id);

    if (reward.is_active == FALSE) {
        return bestow_loop(
            epoch,
            total_shares,
            current_rewards_id + 1,
            rewards_count,
            assets,
            blessed_amts,
            active_rewards_count,
            has_rewards,
        );
    }

    let new_active_rewards_count: ufelt = active_rewards_count + 1;

    assert [assets] = reward.asset;

    let (blessed_amt: ufelt) = IBlesser.bless(reward.blesser);
    assert [blessed_amts] = blessed_amt;

    if (blessed_amt != 0) {
        let epoch_reward_info: AssetApportion = get_asset_reward(reward.asset, epoch);
        let total_amount_to_distribute: ufelt = WadRay.unsigned_add(
            blessed_amt, epoch_reward_info.error
        );

        let asset_amt_per_share: ufelt = WadRay.wunsigned_div(
            total_amount_to_distribute, total_shares
        );
        let actual_amount_distributed: ufelt = WadRay.wmul(asset_amt_per_share, total_shares);
        let error: ufelt = WadRay.unsigned_sub(
            total_amount_to_distribute, actual_amount_distributed
        );

        let updated_asset_amt_per_share: ufelt = WadRay.unsigned_add(
            epoch_reward_info.asset_amt_per_share, asset_amt_per_share
        );
        let packed_reward_asset_info: packed = pack_125(updated_asset_amt_per_share, error);

        absorber_reward_by_epoch.write(reward.asset, epoch, packed_reward_asset_info);

        return bestow_loop(
            epoch,
            total_shares,
            current_rewards_id + 1,
            rewards_count,
            assets + 1,
            blessed_amts + 1,
            new_active_rewards_count,
            TRUE,
        );
    }

    return bestow_loop(
        epoch,
        total_shares,
        current_rewards_id + 1,
        rewards_count,
        assets + 1,
        blessed_amts + 1,
        new_active_rewards_count,
        has_rewards,
    );
}

// Helper function to perform an outer loop over all rewards and calculate the accumulated amounts
// for a provider. It also writes the asset address and accumulated amounts for rewards to two respective arrays.
// To get all rewards, `current_rewards_id` should start at `1`.
func get_provider_accumulated_rewards{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    provider: address,
    provision: Provision,
    current_epoch: ufelt,
    current_rewards_id: ufelt,
    rewards_count: ufelt,
    assets: address*,
    asset_amts: ufelt*,
) {
    alloc_locals;

    if (current_rewards_id == rewards_count + REWARDS_LOOP_START) {
        return ();
    }

    let reward: Reward = absorber_rewards.read(current_rewards_id);
    let asset_amt: ufelt = get_provider_accumulated_rewards_inner_loop(
        provider, provision.shares, provision.epoch, provision.epoch, current_epoch, reward.asset, 0
    );

    assert [assets] = reward.asset;
    assert [asset_amts] = asset_amt;

    return get_provider_accumulated_rewards(
        provider,
        provision,
        current_epoch,
        current_rewards_id + 1,
        rewards_count,
        assets + 1,
        asset_amts + 1,
    );
}

// For a reward, iterate from the provider's Provision epoch up to the current epoch, and
// calculate the accumulated amount.
func get_provider_accumulated_rewards_inner_loop{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    provider: address,
    provided_shares: wad,
    provided_epoch: ufelt,
    epoch: ufelt,
    current_epoch: ufelt,
    asset: address,
    accumulated_amt: ufelt,
) -> ufelt {
    alloc_locals;

    // Terminate after the current epoch because we need to calculate rewards for the current
    // epoch first
    if (epoch == current_epoch + 1) {
        return accumulated_amt;
    }

    // Early termination if no shares
    if (provided_shares == 0) {
        return accumulated_amt;
    }

    let rate: ufelt = get_reward_cumulative_diff(provider, provided_epoch, epoch, asset);
    let asset_amt: ufelt = WadRay.wmul(provided_shares, rate);
    let updated_accumulated_amt: ufelt = WadRay.unsigned_add(accumulated_amt, asset_amt);

    let next_epoch_shares: wad = convert_epoch_shares(epoch, epoch + 1, provided_shares);

    return get_provider_accumulated_rewards_inner_loop(
        provider,
        next_epoch_shares,
        provided_epoch,
        epoch + 1,
        current_epoch,
        asset,
        updated_accumulated_amt,
    );
}

// Returns the accumulated reward asset amount per share wad due to the provider for the given epoch
// Workaround to avoid revoked references
func get_reward_cumulative_diff{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address, provided_epoch: ufelt, epoch: ufelt, asset: address
) -> ufelt {
    let epoch_reward_info: AssetApportion = get_asset_reward(asset, epoch);

    // Calculate the difference with the provider's cumulative value if it is the
    // same epoch as the provider's Provision epoch.
    if (provided_epoch == epoch) {
        let provider_epoch_reward_cumulative: ufelt = absorber_provider_last_reward_cumulative.read(
            provider, asset
        );
        let cumulative_diff: ufelt = WadRay.unsigned_sub(
            epoch_reward_info.asset_amt_per_share, provider_epoch_reward_cumulative
        );

        return cumulative_diff;
    }

    // Otherwise, the provider is entitled to the epoch's entire cumulative value.
    return epoch_reward_info.asset_amt_per_share;
}

// Update a provider's cumulative rewards to the given epoch
// All rewards should be updated for a provider because an inactive reward may be set to active,
// receive a distribution, and set to inactive again. If a provider's cumulative is not updated
// for this reward, the provider can repeatedly claim the difference and drain the absorber.
func update_provider_cumulative_rewards_loop{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    provider: address,
    epoch: ufelt,
    current_rewards_id: ufelt,
    rewards_count: ufelt,
    assets: address*,
) {
    alloc_locals;

    if (current_rewards_id == rewards_count + REWARDS_LOOP_START) {
        return ();
    }

    let asset: address = [assets];
    let epoch_reward_info: AssetApportion = get_asset_reward(asset, epoch);
    absorber_provider_last_reward_cumulative.write(
        provider, asset, epoch_reward_info.asset_amt_per_share
    );

    return update_provider_cumulative_rewards_loop(
        provider, epoch, current_rewards_id + 1, rewards_count, assets + 1
    );
}

// Transfers the error for a reward from the given epoch to the next epoch
// `current_rewards_id` should start at `1`.
func propagate_reward_errors_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    current_rewards_id: ufelt, rewards_count: ufelt, epoch: ufelt
) {
    alloc_locals;

    // Terminate when the number of rewards is exceeded
    if (current_rewards_id == rewards_count + REWARDS_LOOP_START) {
        return ();
    }

    let reward: Reward = absorber_rewards.read(current_rewards_id);
    let epoch_reward_info: AssetApportion = get_asset_reward(reward.asset, epoch);
    let next_epoch_reward_info: packed = pack_125(0, epoch_reward_info.error);
    absorber_reward_by_epoch.write(reward.asset, epoch + 1, next_epoch_reward_info);

    return propagate_reward_errors_loop(current_rewards_id + 1, rewards_count, epoch);
}

// Helper function to iterate over all rewards and calculate the pending reward amounts
// for a provider.
// Takes in an array of accumulated amounts, and writes the sum of the accumulated amount and
// the pending amount to a new array.
// To get all rewards, `current_rewards_id` should start at `1`.
func get_provider_pending_rewards{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    provider: address,
    current_provider_shares: wad,
    total_shares: wad,
    current_epoch: ufelt,
    current_rewards_id: ufelt,
    rewards_count: ufelt,
    accumulated_asset_amts: ufelt*,
    updated_asset_amts: ufelt*,
) {
    alloc_locals;

    if (current_rewards_id == rewards_count + 1) {
        return ();
    }

    let provider_accumulated_amt: ufelt = [accumulated_asset_amts];

    let reward: Reward = absorber_rewards.read(current_rewards_id);
    let pending_amt: ufelt = IBlesser.preview_bless(reward.blesser);
    let reward_info: AssetApportion = get_asset_reward(reward.asset, current_epoch);

    let pending_amt_per_share: ufelt = WadRay.wunsigned_div(
        pending_amt + reward_info.error, total_shares
    );

    let provider_pending_amt: ufelt = WadRay.wmul(pending_amt_per_share, current_provider_shares);
    let provider_updated_amt: ufelt = provider_accumulated_amt + provider_pending_amt;

    assert [updated_asset_amts] = provider_updated_amt;

    return get_provider_pending_rewards(
        provider,
        current_provider_shares,
        total_shares,
        current_epoch,
        current_rewards_id + 1,
        rewards_count,
        accumulated_asset_amts + 1,
        updated_asset_amts + 1,
    );
}