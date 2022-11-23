%lang starknet

from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import (
    assert_le,
    assert_nn_le,
    assert_not_zero,
    split_felt,
    unsigned_div_rem,
)
from starkware.cairo.common.math_cmp import is_le, is_not_zero
from starkware.starknet.common.syscalls import get_block_timestamp

from contracts.shrine.roles import ShrineRoles

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
from contracts.lib.exp import exp
from contracts.lib.types import Trove, Yang
from contracts.lib.wad_ray import WadRay

//
// Constants
//

// Initial multiplier value to ensure `get_recent_multiplier_from` terminates
const INITIAL_MULTIPLIER = WadRay.RAY_ONE;

const MAX_THRESHOLD = WadRay.RAY_ONE;

const TIME_INTERVAL = 30 * 60;  // 30 minutes * 60 seconds per minute
const TIME_INTERVAL_DIV_YEAR = 57077625570776;  // 1 / (48 30-minute segments per day) / (365 days per year) = 0.000057077625 (wad)
// Interest rate piece-wise function parameters - all rays
const RATE_M1 = 2 * 10 ** 25;  // 0.02
const RATE_B1 = 0;
const RATE_M2 = 1 * 10 ** 26;  // 0.1
const RATE_B2 = (-4) * 10 ** 25;  // -0.04
const RATE_M3 = 10 ** 27;  // 1
const RATE_B3 = (-715) * 10 ** 23;  // -0.715
const RATE_M4 = 3101908 * 10 ** 21;  // 3.101908
const RATE_B4 = (-2651908222) * 10 ** 18;  // -2.651908222

// Interest rate piece-wise range bounds (Bound 0 is implicitly zero) - all rays
const RATE_BOUND1 = 5 * 10 ** 26;  // 0.5
const RATE_BOUND2 = 75 * 10 ** 25;  // 0.75
const RATE_BOUND3 = 9215 * 10 ** 23;  // 0.9215

//
// Events
//

@event
func YangAdded(yang: address, yang_id: ufelt, max: wad, start_price: wad) {
}

@event
func YangUpdated(yang: address, yang_info: Yang) {
}

@event
func DebtTotalUpdated(total: wad) {
}

@event
func YinTotalUpdated(total: wad) {
}

@event
func YangsCountUpdated(count: ufelt) {
}

@event
func MultiplierUpdated(multiplier: ray, cumulative_multiplier: ray, interval: ufelt) {
}

@event
func ThresholdUpdated(yang: address, threshold: ray) {
}

@event
func TroveUpdated(trove_id: ufelt, trove: Trove) {
}

@event
func YinUpdated(user: address, amount: wad) {
}

@event
func DepositUpdated(yang: address, trove_id: ufelt, amount: wad) {
}

@event
func YangPriceUpdated(yang: address, price: wad, cumulative_price: wad, interval: ufelt) {
}

@event
func CeilingUpdated(ceiling: wad) {
}

@event
func Killed() {
}

//
// Storage
//

// A trove can forge debt up to its threshold depending on the yangs deposited.
// This mapping maps a trove to a `packed` felt containing its information.
// The first 128 bits stores the amount of debt in the trove.
// The last 123 bits stores the start time interval of the next interest accumulation period.
@storage_var
func shrine_troves(trove_id: ufelt) -> (trove: packed) {
}

// Stores the amount of the "yin" (synthetic) each user owns.
// yin can be exchanged for ERC20 synthetic tokens via the yin gate.
@storage_var
func shrine_yin(user: address) -> (balance: wad) {
}

// Stores information about each collateral (see Yang struct)
@storage_var
func shrine_yangs(yang_id: ufelt) -> (yang: Yang) {
}

// Number of collateral accepted by the system.
// The return value is also the ID of the last added collateral.
@storage_var
func shrine_yangs_count() -> (count: ufelt) {
}

// Mapping from yang address to yang ID.
// Yang ID starts at 1.
@storage_var
func shrine_yang_id(yang: address) -> (id: ufelt) {
}

// Keeps track of how much of each yang has been deposited into each Trove - wad
@storage_var
func shrine_deposits(yang_id: ufelt, trove_id: ufelt) -> (balance: wad) {
}

// Total amount of debt accrued
@storage_var
func shrine_total_debt() -> (total_debt: wad) {
}

// Total amount of synthetic forged
@storage_var
func shrine_total_yin() -> (total_yin: wad) {
}

// Keeps track of the price history of each Yang - packed
// interval: timestamp divided by TIME_INTERVAL.
// packed contains both the actual price (high 125 bits) and the cumulative price (low 125 bits) of
// the yang at each time interval, both as wads
@storage_var
func shrine_yang_price(yang_id: ufelt, interval: ufelt) -> (price_and_cumulative_price: packed) {
}

// Total debt ceiling - wad
@storage_var
func shrine_ceiling() -> (ceiling: wad) {
}

// Global interest rate multiplier - packed
// packed contains both the actual multiplier (high 125 bits), and the cumulative multiplier (low 125 bits) of
// the yang at each time interval, both as rays
@storage_var
func shrine_multiplier(interval: ufelt) -> (mul_and_cumulative_mul: packed) {
}

// Liquidation threshold per yang (as LTV) - ray
@storage_var
func shrine_thresholds(yang_id: ufelt) -> (threshold: ray) {
}

@storage_var
func shrine_live() -> (is_live: bool) {
}

//
// Getters
//

// Returns a tuple of a trove's threshold, LTV based on compounded debt, trove value and compounded debt
@view
func get_trove_info{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt
) -> (threshold: ray, ltv: ray, value: wad, debt: wad) {
    alloc_locals;

    let interval: ufelt = now();

    // Get threshold and trove value
    let (yang_count: ufelt) = shrine_yangs_count.read();
    let (threshold: ray, value: wad) = get_trove_threshold_and_value_internal(
        trove_id, interval, interval, yang_count, 0, 0
    );

    // Calculate debt
    let (trove: Trove) = get_trove(trove_id);
    let debt: wad = compound(trove_id, trove.debt, trove.charge_from, interval);

    // Catch troves with no value
    if (value == 0) {
        let has_debt: bool = is_not_zero(debt);
        if (has_debt == TRUE) {
            // Handles corner case: forging non-zero debt for a trove with zero value
            return (threshold, WadRay.BOUND, value, debt);
        } else {
            return (threshold, 0, value, debt);
        }
    }

    let ltv: ray = WadRay.runsigned_div(debt, value);  // Using WadRay.runsigned_div on two wads returns a ray
    return (threshold, ltv, value, debt);
}

@view
func get_yin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(user: address) -> (
    balance: wad
) {
    return shrine_yin.read(user);
}

@view
func get_total_yin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    total_yin: wad
) {
    return shrine_total_yin.read();
}

@view
func get_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(yang: address) -> (
    yang: Yang
) {
    let (yang_id: ufelt) = shrine_yang_id.read(yang);
    return shrine_yangs.read(yang_id);
}

@view
func get_yangs_count{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    count: ufelt
) {
    return shrine_yangs_count.read();
}

@view
func get_deposit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address, trove_id: ufelt
) -> (balance: wad) {
    let (yang_id: ufelt) = shrine_yang_id.read(yang);
    return shrine_deposits.read(yang_id, trove_id);
}

@view
func get_total_debt{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    total_debt: wad
) {
    return shrine_total_debt.read();
}

@view
func get_yang_price{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address, interval: ufelt
) -> (price: wad, cumulative_price: wad) {
    alloc_locals;
    let (yang_id: ufelt) = shrine_yang_id.read(yang);
    let (price_and_cumulative_price: packed) = shrine_yang_price.read(yang_id, interval);
    let (price: wad, cumulative_price: wad) = unpack_125(price_and_cumulative_price);
    return (price, cumulative_price);
}

@view
func get_ceiling{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    ceiling: wad
) {
    return shrine_ceiling.read();
}

@view
func get_multiplier{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    interval: ufelt
) -> (multiplier: ray, cumulative_multiplier: ray) {
    alloc_locals;
    let (mul_and_cumulative_mul: packed) = shrine_multiplier.read(interval);
    let (multiplier: ray, cumulative_multiplier: ray) = unpack_125(mul_and_cumulative_mul);
    return (multiplier, cumulative_multiplier);
}

@view
func get_yang_threshold{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address
) -> (threshold: ray) {
    let yang_id: ufelt = get_valid_yang_id(yang);
    return shrine_thresholds.read(yang_id);
}

@view
func get_live{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    is_live: bool
) {
    return shrine_live.read();
}

//
// Setters
//

@external
func add_yang{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, max: wad, threshold: ray, initial_price: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.ADD_YANG);

    // Assert that yang is not already added
    let (potential_yang_id: ufelt) = shrine_yang_id.read(yang);
    with_attr error_message("Shrine: Yang already exists") {
        assert potential_yang_id = 0;
    }

    // Assert validity of `max` argument
    with_attr error_message("Shrine: Value of `max` ({max}) is out of bounds") {
        WadRay.assert_valid_unsigned(max);
    }

    // Validity of `threshold` is asserted in set_threshold
    // Validity of `initial_price` is asserted in pack_125

    // Assign ID to yang and add yang struct
    let (yang_count: ufelt) = shrine_yangs_count.read();
    let yang_id: ufelt = yang_count + 1;

    shrine_yang_id.write(yang, yang_id);
    shrine_yangs.write(yang_id, Yang(0, max));

    // Update yangs count
    shrine_yangs_count.write(yang_id);

    // Set threshold
    set_threshold(yang, threshold);

    // Since `initial_price` is the first price in the price history, the cumulative price is also set to `initial_price`
    let init_price_and_cumulative_price: packed = pack_125(initial_price, initial_price);

    let current_interval: ufelt = now();
    let previous_interval: ufelt = current_interval - 1;
    // seeding initial price to the previous interval to ensure `get_recent_price_from` terminates
    // new prices are pushed to Shrine from an oracle via `advance` and are always set on the current
    // interval (`now()`); if we wouldn't set this initial price to `now() - 1` and oracle could
    // update a price still in the current interval (as oracle update times are independent of
    // Shrine's intervals, a price can be updated multiple times in a single interval) which would
    // result in an endless loop of `get_recent_price_from` since it wouldn't find the initial price
    shrine_yang_price.write(yang_id, previous_interval, init_price_and_cumulative_price);

    // Events
    YangAdded.emit(yang, yang_id, max, initial_price);
    YangsCountUpdated.emit(yang_id);

    return ();
}

@external
func set_yang_max{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, new_max: wad) {
    alloc_locals;
    AccessControl.assert_has_role(ShrineRoles.SET_YANG_MAX);

    with_attr error_message("Shrine: Value of `new_max` ({new_max}) is out of bounds") {
        WadRay.assert_valid_unsigned(new_max);
    }

    let yang_id: ufelt = get_valid_yang_id(yang);
    let (old_yang_info: Yang) = shrine_yangs.read(yang_id);
    let new_yang_info: Yang = Yang(old_yang_info.total, new_max);
    shrine_yangs.write(yang_id, new_yang_info);

    YangUpdated.emit(yang, new_yang_info);

    return ();
}

@external
func set_ceiling{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(new_ceiling: wad) {
    AccessControl.assert_has_role(ShrineRoles.SET_CEILING);

    with_attr error_message("Shrine: Value of `new_ceiling` ({new_ceiling}) is out of bounds") {
        WadRay.assert_valid_unsigned(new_ceiling);
    }

    shrine_ceiling.write(new_ceiling);

    CeilingUpdated.emit(new_ceiling);

    return ();
}

@external
func set_threshold{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, new_threshold: ray) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.SET_THRESHOLD);

    with_attr error_message("Shrine: Value of `new_threshold` ({new_threshold}) is out of bounds") {
        WadRay.assert_valid_unsigned(new_threshold);
    }

    // Check that threshold value is not greater than max threshold
    with_attr error_message("Shrine: Threshold exceeds 100%") {
        assert_le(new_threshold, MAX_THRESHOLD);
    }

    let yang_id: ufelt = get_valid_yang_id(yang);
    shrine_thresholds.write(yang_id, new_threshold);

    ThresholdUpdated.emit(yang, new_threshold);

    return ();
}

@external
func kill{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}() {
    AccessControl.assert_has_role(ShrineRoles.KILL);

    shrine_live.write(FALSE);

    Killed.emit();

    return ();
}

//
// Constructor
//

@constructor
func constructor{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(admin: address) {
    alloc_locals;

    AccessControl.initializer(admin);

    // Grant admin permission
    AccessControl._grant_role(ShrineRoles.DEFAULT_SHRINE_ADMIN_ROLE, admin);

    shrine_live.write(TRUE);

    // Set initial multiplier value
    let interval: ufelt = now();
    // The initial cumulative multiplier is set to `INITIAL_MULTIPLIER`
    let init_mul_cumulative_mul: packed = pack_125(INITIAL_MULTIPLIER, INITIAL_MULTIPLIER);
    shrine_multiplier.write(interval, init_mul_cumulative_mul);

    // Events
    MultiplierUpdated.emit(INITIAL_MULTIPLIER, INITIAL_MULTIPLIER, interval);
    return ();
}

//
// Core functions - External
//

// Set the price of the specified Yang for a given interval
// price of 1 unit of yang = price of underlying asset * amount of underlying asset represented by 1 unit of yang
@external
func advance{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, asset_price: wad, asset_amt_per_yang: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.ADVANCE);

    with_attr error_message("Shrine: Cannot set a price value to zero") {
        assert_not_zero(asset_price);  // Cannot set a price value to zero
    }

    with_attr error_message("Shrine: Exchange rate of yang to asset cannot be lower than 1") {
        assert_nn_le(WadRay.WAD_ONE, asset_amt_per_yang);
    }

    let interval: ufelt = now();
    let yang_id: ufelt = get_valid_yang_id(yang);

    let yang_price: wad = WadRay.wmul(asset_price, asset_amt_per_yang);

    // Calculating the new cumulative price
    // To do this, we get the interval of the last price update, find the number of
    // intervals BETWEEN the current interval and the last_interval (non-inclusive), multiply that by
    // the last price, and add it to the last cumulative price. Then we add the new price, `price`.
    let (last_price: wad, last_cumulative_price: wad, last_interval: ufelt) = get_recent_price_from(
        yang_id, interval - 1
    );
    // TODO: should there be an overflow check here?
    let new_cumulative: wad = last_cumulative_price + (interval - last_interval - 1) * last_price + yang_price;

    let price_and_cumulative_price: packed = pack_125(yang_price, new_cumulative);
    shrine_yang_price.write(yang_id, interval, price_and_cumulative_price);

    YangPriceUpdated.emit(yang, yang_price, new_cumulative, interval);

    return ();
}

// Appends a new multiplier value
@external
func set_multiplier{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(new_multiplier: ray) {
    alloc_locals;
    AccessControl.assert_has_role(ShrineRoles.SET_MULTIPLIER);

    with_attr error_message("Shrine: Cannot set a multiplier value to zero") {
        assert_not_zero(new_multiplier);  // Cannot set a multiplier value to zero
    }

    let interval: ufelt = now();

    let (
        last_multiplier: ray, last_cumulative_multiplier: ray, last_interval: ufelt
    ) = get_recent_multiplier_from(interval - 1);

    // TODO: should there be an overflow check here?
    let new_cumulative_multiplier: ray = last_cumulative_multiplier + (interval - last_interval - 1) * last_multiplier + new_multiplier;

    let mul_and_cumulative_mul: packed = pack_125(new_multiplier, new_cumulative_multiplier);
    shrine_multiplier.write(interval, mul_and_cumulative_mul);

    MultiplierUpdated.emit(new_multiplier, new_cumulative_multiplier, interval);

    return ();
}

// Move Yang between two Troves
// Checks should be performed beforehand by the module calling this function
@external
func move_yang{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, src_trove_id: ufelt, dst_trove_id: ufelt, amount: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.MOVE_YANG);

    with_attr error_message("Shrine: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    let yang_id: ufelt = get_valid_yang_id(yang);

    // Charge interest for source trove to ensure it remains safe
    charge(src_trove_id);

    // Charge interest for destination trove since its collateral balance will be changed,
    // affecting its personalized interest rate due to the underlying assumption in `get_trove_threshold_and_value_internal`
    // TODO: maybe move this under `assert_healthy` call so failed `move_yang` calls are cheaper?
    // It depends on starknet handles fees for failed transactions
    charge(dst_trove_id);

    let (src_yang_balance: wad) = shrine_deposits.read(yang_id, src_trove_id);

    // Ensure source trove has sufficient yang
    with_attr error_message("Shrine: Insufficient yang") {
        // WadRay.sub_unsigned asserts (src_yang_balance - amount) >= 0
        let new_src_balance: wad = WadRay.sub_unsigned(src_yang_balance, amount);
    }

    // Update yang balance of source trove
    shrine_deposits.write(yang_id, src_trove_id, new_src_balance);

    // Assert source trove is within limits
    assert_healthy(src_trove_id);

    // Update yang balance of destination trove
    let (dst_yang_balance: wad) = shrine_deposits.read(yang_id, dst_trove_id);
    let new_dst_balance: wad = WadRay.add_unsigned(dst_yang_balance, amount);
    shrine_deposits.write(yang_id, dst_trove_id, new_dst_balance);

    // Events
    DepositUpdated.emit(yang, src_trove_id, new_src_balance);
    DepositUpdated.emit(yang, dst_trove_id, new_dst_balance);

    return ();
}

@external
func move_yin{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(src: address, dst: address, amount: wad) {
    AccessControl.assert_has_role(ShrineRoles.MOVE_YIN);

    with_attr error_message("Shrine: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    let (src_balance: wad) = shrine_yin.read(src);
    let (dst_balance: wad) = shrine_yin.read(dst);

    // WadRay.sub_unsigned reverts on underflow, so this function cannot be used to move more yin than src_address owns
    with_attr error_message("Shrine: Transfer amount exceeds yin balance") {
        shrine_yin.write(src, WadRay.sub_unsigned(src_balance, amount));
    }

    shrine_yin.write(dst, WadRay.add(dst_balance, amount));

    // No event emissions - this is because `move-yin` should only be called by an
    // ERC20 wrapper contract which emits a `Transfer` event on transfers anyway.

    return ();
}

// Deposit a specified amount of a Yang into a Trove
@external
func deposit{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, trove_id: ufelt, amount: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.DEPOSIT);

    // Check system is live
    assert_live();

    with_attr error_message("Shrine: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    // Charge interest
    charge(trove_id);

    // Update yang balance of system
    let yang_id: ufelt = get_valid_yang_id(yang);
    let (old_yang_info: Yang) = shrine_yangs.read(yang_id);
    let new_total: wad = WadRay.add(old_yang_info.total, amount);

    // Asserting that the deposit does not cause the total amount of yang deposited to exceed the max.
    with_attr error_message("Shrine: Exceeds maximum amount of Yang allowed for system") {
        assert_le(new_total, old_yang_info.max);
    }

    let new_yang_info: Yang = Yang(total=new_total, max=old_yang_info.max);
    shrine_yangs.write(yang_id, new_yang_info);

    // Update yang balance of trove
    let (trove_yang_balance: wad) = shrine_deposits.read(yang_id, trove_id);
    let new_trove_balance: wad = WadRay.add(trove_yang_balance, amount);
    shrine_deposits.write(yang_id, trove_id, new_trove_balance);

    // Events
    YangUpdated.emit(yang, new_yang_info);
    DepositUpdated.emit(yang, trove_id, new_trove_balance);

    return ();
}

// Withdraw a specified amount of a Yang from a Trove with trove safety check
@external
func withdraw{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, trove_id: ufelt, amount: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.WITHDRAW);

    withdraw_internal(yang, trove_id, amount);

    // Check if Trove is within limits
    assert_healthy(trove_id);

    return ();
}

// Mint a specified amount of synthetic for a Trove
@external
func forge{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(user: address, trove_id: ufelt, amount: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.FORGE);

    // Check system is live
    assert_live();

    with_attr error_message("Shrine: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    // Charge interest
    charge(trove_id);  // TODO: Maybe move this under the debt ceiling check to save gas in case of failed tx

    // Get current Trove information
    let (old_trove_info: Trove) = get_trove(trove_id);

    // Get current interval
    let current_interval: ufelt = now();

    // Check that debt ceiling has not been reached
    let (current_system_debt: wad) = shrine_total_debt.read();

    with_attr error_message("Shrine: System debt overflow") {
        let new_system_debt: wad = WadRay.add(current_system_debt, amount);  // WadRay.add checks for overflow
    }

    let (debt_ceiling: wad) = shrine_ceiling.read();

    // Debt ceiling check
    with_attr error_message("Shrine: Debt ceiling reached") {
        assert_le(new_system_debt, debt_ceiling);
    }

    // Update system debt
    shrine_total_debt.write(new_system_debt);

    // Initialise `Trove.charge_from` to current interval if old debt was 0.
    // Otherwise, set `Trove.charge_from` to current interval + 1 because interest has been
    // charged up to current interval.
    if (old_trove_info.debt == 0) {
        tempvar new_charge_from: ufelt = current_interval;
    } else {
        tempvar new_charge_from: ufelt = old_trove_info.charge_from;
    }

    // Update trove information
    let new_debt: wad = WadRay.add(old_trove_info.debt, amount);
    let new_trove_info: Trove = Trove(charge_from=new_charge_from, debt=new_debt);
    set_trove(trove_id, new_trove_info);

    // Check if Trove is within limits
    assert_healthy(trove_id);

    // Update the user's yin
    let (user_yin: wad) = shrine_yin.read(user);
    let new_user_yin: wad = WadRay.add(user_yin, amount);
    shrine_yin.write(user, new_user_yin);

    // Update the total yin
    let (total_yin: wad) = shrine_total_yin.read();
    let new_total_yin: wad = WadRay.add(total_yin, amount);
    shrine_total_yin.write(new_total_yin);

    // Events
    DebtTotalUpdated.emit(new_system_debt);
    TroveUpdated.emit(trove_id, new_trove_info);
    YinTotalUpdated.emit(new_total_yin);
    YinUpdated.emit(user, new_user_yin);

    return ();
}

// Repay a specified amount of synthetic for a Trove
// The module calling this function should ensure that `amount` does not exceed Trove's debt.
@external
func melt{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(user: address, trove_id: ufelt, amount: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.MELT);

    with_attr error_message("Shrine: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    // Charge interest
    charge(trove_id);

    // Get current Trove information
    let (old_trove_info: Trove) = get_trove(trove_id);

    // Get current interval
    let current_interval: ufelt = now();

    // Update system debt
    let (current_system_debt: wad) = shrine_total_debt.read();

    with_attr error_message("Shrine: System debt underflow") {
        let new_system_debt: wad = WadRay.sub_unsigned(current_system_debt, amount);  // WadRay.sub_unsigned contains an underflow check
    }

    shrine_total_debt.write(new_system_debt);

    // Update trove information
    with_attr error_message("Shrine: Cannot pay back more debt than exists in this trove") {
        let new_debt: wad = WadRay.sub_unsigned(old_trove_info.debt, amount);  // Reverts if amount > old_trove_info.debt
    }

    let new_trove_info: Trove = Trove(charge_from=current_interval, debt=new_debt);
    set_trove(trove_id, new_trove_info);

    // Updating the user's yin
    let (user_yin: wad) = shrine_yin.read(user);

    // Updating the total yin
    let (total_yin: wad) = shrine_total_yin.read();

    // Reverts if amount > user_yin or amount > total_yin.
    with_attr error_message("Shrine: Not enough yin to melt debt") {
        let new_user_yin: wad = WadRay.sub_unsigned(user_yin, amount);
        let new_total_yin: wad = WadRay.sub_unsigned(total_yin, amount);
    }

    shrine_yin.write(user, new_user_yin);
    shrine_total_yin.write(new_total_yin);

    // Events

    DebtTotalUpdated.emit(new_system_debt);
    TroveUpdated.emit(trove_id, new_trove_info);
    YinTotalUpdated.emit(new_total_yin);
    YinUpdated.emit(user, new_user_yin);

    return ();
}

// Withdraw a specified amount of a Yang from a Trove without trove safety check.
// This is intended for liquidations where collateral needs to be withdrawn and transferred to the liquidator
// even if the trove is still unsafe.
@external
func seize{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, trove_id: ufelt, amount: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.SEIZE);

    withdraw_internal(yang, trove_id, amount);

    return ();
}

@external
func start_flash_mint{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(receiver: address, amount: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.FLASH_MINT);

    with_attr error_message("Shrine: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    let (current_balance: wad) = shrine_yin.read(receiver);
    with_attr error_message("Shrine: Mint overflow") {
        let new_balance: wad = WadRay.add_unsigned(current_balance, amount);
    }

    // mint yin
    shrine_yin.write(receiver, new_balance);
    let (total_yin: wad) = shrine_total_yin.read();
    shrine_total_yin.write(WadRay.add_unsigned(total_yin, amount));

    return ();
}

@external
func end_flash_mint{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(receiver: address, amount: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.FLASH_MINT);

    // skipping amount validation because it already had to
    // pass validation in start_flash_loan

    let (current_balance: wad) = shrine_yin.read(receiver);
    with_attr error_message("Shrine: Invalid post flash mint state") {
        let post_mint_balance: wad = WadRay.sub_unsigned(current_balance, amount);
    }

    // burn yin
    shrine_yin.write(receiver, post_mint_balance);
    let (total_yin: wad) = shrine_total_yin.read();
    shrine_total_yin.write(WadRay.sub_unsigned(total_yin, amount));

    return ();
}

//
// Core Functions - View
//

// Get the last updated price for a yang
@view
func get_current_yang_price{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang
) -> (price: wad, cumulative_price: wad, interval: ufelt) {
    alloc_locals;

    let (yang_id: ufelt) = shrine_yang_id.read(yang);
    let interval: ufelt = now();  // Get current interval
    return get_recent_price_from(yang_id, interval);
}

// Gets last updated multiplier value
@view
func get_current_multiplier{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    multiplier: ray, cumulative_multiplier: ray, interval: ufelt
) {
    let interval: ufelt = now();
    return get_recent_multiplier_from(interval);
}

// Returns a bool indicating whether the given trove is healthy or not
@view
func is_healthy{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt
) -> (healthy: bool) {
    let (threshold: ray, ltv: ray, _, _) = get_trove_info(trove_id);
    return (is_le(ltv, threshold),);
}

@view
func get_max_forge{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt
) -> (max: wad) {
    let (threshold: ray, _, value: wad, debt: wad) = get_trove_info(trove_id);

    // Calculate the maximum amount of debt the trove can have
    let max_debt: wad = WadRay.rmul(threshold, value);

    // Early termination if trove cannot forge new debt
    let can_forge: bool = is_le(debt, max_debt);
    if (can_forge == FALSE) {
        return (0,);
    }

    let max_forge_amt: wad = max_debt - debt;
    return (max_forge_amt,);
}

//
// Internal
//

func assert_live{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    // Check system is live
    let (live: bool) = shrine_live.read();

    with_attr error_message("Shrine: System is not live") {
        assert live = TRUE;
    }

    return ();
}

// Helper function to get the yang ID given a yang address, and throw an error if
// yang address has not been added (i.e. yang ID = 0)
func get_valid_yang_id{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address
) -> ufelt {
    let (yang_id: ufelt) = shrine_yang_id.read(yang);

    with_attr error_message("Shrine: Yang does not exist") {
        assert_not_zero(yang_id);
    }

    return yang_id;
}

func get_trove{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt
) -> (trove: Trove) {
    let (trove_packed: packed) = shrine_troves.read(trove_id);
    let (charge_from: ufelt, debt: wad) = split_felt(trove_packed);
    let trove: Trove = Trove(charge_from=charge_from, debt=debt);
    return (trove,);
}

func set_trove{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt, trove: Trove
) {
    let packed_trove: packed = pack_felt(trove.charge_from, trove.debt);
    shrine_troves.write(trove_id, packed_trove);
    return ();
}

func now{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> ufelt {
    let (time: ufelt) = get_block_timestamp();
    let (interval: ufelt, _) = unsigned_div_rem(time, TIME_INTERVAL);
    return interval;
}

// Withdraw a specified amount of a Yang from a Trove
func withdraw_internal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address, trove_id: ufelt, amount: wad
) {
    alloc_locals;

    with_attr error_message("Shrine: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    // Retrieve yang info
    let yang_id: ufelt = get_valid_yang_id(yang);
    let (old_yang_info: Yang) = shrine_yangs.read(yang_id);

    // Ensure trove has sufficient yang
    let (trove_yang_balance: wad) = shrine_deposits.read(yang_id, trove_id);

    with_attr error_message("Shrine: Insufficient yang") {
        // WadRay.sub_unsigned asserts (trove_yang_balance - amount) >= 0
        let new_trove_balance: wad = WadRay.sub_unsigned(trove_yang_balance, amount);
    }

    // Charge interest
    charge(trove_id);

    // Update yang balance of system
    let new_total: wad = WadRay.sub_unsigned(old_yang_info.total, amount);
    let new_yang_info: Yang = Yang(total=new_total, max=old_yang_info.max);
    shrine_yangs.write(yang_id, new_yang_info);

    // Update yang balance of trove
    shrine_deposits.write(yang_id, trove_id, new_trove_balance);

    // Events
    YangUpdated.emit(yang, new_yang_info);
    DepositUpdated.emit(yang, trove_id, new_trove_balance);

    return ();
}

// Adds the accumulated interest as debt to the trove
func charge{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(trove_id) {
    alloc_locals;
    // Get trove info
    let (trove: Trove) = get_trove(trove_id);

    // Early termination if no debt
    if (trove.debt == 0) {
        return ();
    }

    // Get current interval
    let current_interval: ufelt = now();

    // Get new debt amount
    let new_debt: wad = compound(trove_id, trove.debt, trove.charge_from, current_interval);

    // Catch troves with zero value
    if (new_debt == trove.debt) {
        return ();
    }

    // Update trove
    let updated_trove: Trove = Trove(charge_from=current_interval, debt=new_debt);
    set_trove(trove_id, updated_trove);

    // Get old system debt amount
    let (old_system_debt: wad) = shrine_total_debt.read();

    // Get interest charged
    let diff: wad = WadRay.sub_unsigned(new_debt, trove.debt);  // TODO: should this be unchecked? `new_debt` >= `trove.debt` is guaranteed

    // Get new system debt
    tempvar new_system_debt: wad = old_system_debt + diff;

    shrine_total_debt.write(new_system_debt);

    // Events
    DebtTotalUpdated.emit(new_system_debt);
    TroveUpdated.emit(trove_id, updated_trove);

    return ();
}

// Returns the amount of debt owed by trove after having interest charged over a given time period
// Assumes the trove hasn't minted or paid back any additional debt during the given time period
// Assumes the trove hasn't deposited or withdrawn any additional collateral during the given time period
// Time period includes `end_interval` and does NOT include `start_interval`.

// Compound interest formula: P(t) = P_0 * e^(rt)
// P_0 = principal
// r = nominal interest rate (what the interest rate would be if there was no compounding
// t = time elapsed, in years
func compound{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt, current_debt: wad, start_interval: ufelt, end_interval: ufelt
) -> wad {
    alloc_locals;

    let avg_relative_ltv: ray = get_avg_relative_ltv(
        trove_id, current_debt, start_interval, end_interval
    );

    // Catch troves with zero value
    if (avg_relative_ltv == 0) {
        return current_debt;
    }

    let avg_multiplier: ray = get_avg_multiplier(start_interval, end_interval);

    let base_rate: ray = get_base_rate(avg_relative_ltv);
    let rate: ray = WadRay.rmul(base_rate, avg_multiplier);  // represents `r` in the compound interest formula
    let t: wad = (end_interval - start_interval) * TIME_INTERVAL_DIV_YEAR;  // represents `t` in the compound interest formula

    // Using `rmul` on a ray and a wad yields a wad, which we need since `exp` only takes wads
    let compounded_scalar: wad = exp(WadRay.rmul(rate, t));
    let compounded_debt: wad = WadRay.wmul(current_debt, compounded_scalar);

    return compounded_debt;
}

// base rate function:
//
//  rLTV = relative loan-to-value ratio
//
//
//            { 0.02*rLTV                   if 0 <= rLTV <= 0.5
//            { 0.1*rLTV - 0.04             if 0.5 < rLTV <= 0.75
//  r(rLTV) = { rLTV - 0.715                if 0.75 < rLTV <= 0.9215
//            { 3.101908*rLTV - 2.65190822  if 0.9215 < rLTV < \infinity
//
//

func get_base_rate{range_check_ptr}(ltv: ray) -> ray {
    alloc_locals;

    if (is_le(ltv, RATE_BOUND1) == TRUE) {
        return linear(ltv, RATE_M1, RATE_B1);
    }

    if (is_le(ltv, RATE_BOUND2) == TRUE) {
        return linear(ltv, RATE_M2, RATE_B2);
    }

    if (is_le(ltv, RATE_BOUND3) == TRUE) {
        return linear(ltv, RATE_M3, RATE_B3);
    }

    return linear(ltv, RATE_M4, RATE_B4);
}

// y = m*x + b
func linear{range_check_ptr}(x: ray, m: ray, b: ray) -> ray {
    return WadRay.add(WadRay.rmul(m, x), b);
}

// Returns the price for `yang_id` at `interval` if it is non-zero.
// Otherwise, check `interval` - 1 recursively for the last available price.
func get_recent_price_from{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang_id, interval
) -> (price: wad, cumulative_price: wad, interval: ufelt) {
    alloc_locals;
    let (price_and_cumulative_price: packed) = shrine_yang_price.read(yang_id, interval);

    if (price_and_cumulative_price != 0) {
        let (price: wad, cumulative_price: wad) = unpack_125(price_and_cumulative_price);
        return (price, cumulative_price, interval);
    }

    return get_recent_price_from(yang_id, interval - 1);
}

// Returns the average price for a yang between two intervals, including `end_interval` but NOT including `start_interval`
// - If `start_interval` is the same as `end_interval`, return the price at that interval.
// - If `start_interval` is different from `end_interval`, return the average price.
// Return value is a tuple so that function can be modified as an external view for testing
func get_avg_price{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang_id: ufelt, start_interval: ufelt, end_interval: ufelt
) -> (price: wad) {
    alloc_locals;

    let (
        start_yang_price: wad, start_cumulative_yang_price: wad, available_start_interval: ufelt
    ) = get_recent_price_from(yang_id, start_interval);

    let (
        end_yang_price: wad, end_cumulative_yang_price: wad, available_end_interval
    ) = get_recent_price_from(yang_id, end_interval);

    // If the last available price for both start and end intervals are the same,
    // return that last available price
    // This also catches `start_interval == end_interval`
    if (available_start_interval == available_end_interval) {
        return (start_yang_price,);
    }

    // subtraction operations can be unchecked since the `end_` vars are
    // guaranteed to be greater than or equal to the `start_` variables
    let cumulative_diff: wad = end_cumulative_yang_price - start_cumulative_yang_price;

    // Early termination if `start_interval` and `end_interval` are updated
    if (start_interval == available_start_interval and end_interval == available_end_interval) {
        let (avg_price: wad, _) = unsigned_div_rem(cumulative_diff, end_interval - start_interval);
        return (avg_price,);
    }

    // If the start interval is not updated, adjust the cumulative difference (see `advance`) by deducting
    // (number of intervals missed from `available_start_interval` to `start_interval` * start price).
    if (start_interval == available_start_interval) {
        tempvar intermediate_adjusted_cumulative_diff: wad = cumulative_diff;
    } else {
        let cumulative_offset: wad = (start_interval - available_start_interval) * start_yang_price;
        tempvar intermediate_adjusted_cumulative_diff: wad = cumulative_diff - cumulative_offset;
    }

    // If the end interval is not updated, adjust the cumulative difference by adding
    // (number of intervals missed from `available_end_interval` to `end_interval` * end price).
    if (end_interval == available_end_interval) {
        tempvar final_adjusted_cumulative_diff: wad = intermediate_adjusted_cumulative_diff;
    } else {
        let cumulative_offset: wad = (end_interval - available_end_interval) * end_yang_price;
        tempvar final_adjusted_cumulative_diff: wad = intermediate_adjusted_cumulative_diff + cumulative_offset;
    }

    let (avg_price: wad, _) = unsigned_div_rem(
        final_adjusted_cumulative_diff, end_interval - start_interval
    );
    return (avg_price,);
}

// Returns the multiplier at `interval` if it is non-zero.
// Otherwise, check `interval` - 1 recursively for the last available value.
func get_recent_multiplier_from{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    interval: ufelt
) -> (multiplier: ray, cumulative_multiplier: ray, interval: ufelt) {
    alloc_locals;
    let (mul_and_cumulative_mul: packed) = shrine_multiplier.read(interval);

    if (mul_and_cumulative_mul != 0) {
        let (multiplier: ray, cumulative_multiplier: ray) = unpack_125(mul_and_cumulative_mul);
        return (multiplier, cumulative_multiplier, interval);
    }

    return get_recent_multiplier_from(interval - 1);
}

// Returns the average multiplier over the specified time period, including `end_interval` but NOT including `start_interval`
// - If `start_interval` is the same as `end_interval`, return the multiplier value at that interval.
// - If `start_interval` is different from `end_interval`, return the average.
// Return value is a tuple so that function can be modified as an external view for testing
func get_avg_multiplier{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    start_interval: ufelt, end_interval: ufelt
) -> (multiplier: ray) {
    alloc_locals;

    let (
        start_multiplier: ray, start_cumulative_multiplier: ray, available_start_interval
    ) = get_recent_multiplier_from(start_interval);

    let (
        end_multiplier: ray, end_cumulative_multiplier: ray, available_end_interval
    ) = get_recent_multiplier_from(end_interval);

    // If the last available multiplier for both start and end intervals are the same,
    // return that last available multiplier
    // This also catches `start_interval == end_interval`
    if (available_start_interval == available_end_interval) {
        return (start_multiplier,);
    }

    // subtraction operations can be unchecked since the `end_` vars are
    // guaranteed to be greater than or equal to the `start_` variables
    let cumulative_diff: ray = end_cumulative_multiplier - start_cumulative_multiplier;

    // Early termination if `start_interval` and `end_interval` are updated
    if (start_interval == available_start_interval and end_interval == available_end_interval) {
        let (avg_multiplier: wad, _) = unsigned_div_rem(
            cumulative_diff, end_interval - start_interval
        );
        return (avg_multiplier,);
    }

    // If the start interval is not updated, adjust the cumulative difference (see `advance`) by deducting
    // (number of intervals missed from `available_start_interval` to `start_interval` * start price).
    if (start_interval == available_start_interval) {
        tempvar intermediate_adjusted_cumulative_diff: wad = cumulative_diff;
    } else {
        let neg_cumulative_offset: wad = (start_interval - available_start_interval) * start_multiplier;
        tempvar intermediate_adjusted_cumulative_diff: wad = cumulative_diff - neg_cumulative_offset;
    }

    // If the end interval is not updated, adjust the cumulative difference by adding
    // (number of intervals missed from `available_end_interval` to `end_interval` * end price).
    if (end_interval == available_end_interval) {
        tempvar final_adjusted_cumulative_diff: wad = intermediate_adjusted_cumulative_diff;
    } else {
        let pos_cumulative_offset: wad = (end_interval - available_end_interval) * end_multiplier;
        tempvar final_adjusted_cumulative_diff: wad = intermediate_adjusted_cumulative_diff + pos_cumulative_offset;
    }

    let (avg_multiplier: wad, _) = unsigned_div_rem(
        final_adjusted_cumulative_diff, end_interval - start_interval
    );
    return (avg_multiplier,);
}

// Returns the average relative LTV of a trove over the specified time period
// Assumes debt remains constant over this period
func get_avg_relative_ltv{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt, debt: wad, start_interval: ufelt, end_interval: ufelt
) -> ray {
    let (num_yangs: ufelt) = shrine_yangs_count.read();
    let (avg_threshold: ray, avg_val: wad) = get_trove_threshold_and_value_internal(
        trove_id, start_interval, end_interval, num_yangs, 0, 0
    );

    // Catch troves with zero value
    if (avg_val == 0) {
        return 0;
    }

    let avg_ltv: ray = WadRay.runsigned_div(debt, avg_val);
    let avg_relative_ltv: ray = WadRay.runsigned_div(avg_ltv, avg_threshold);

    return avg_relative_ltv;
}

//
// Trove health internal functions
//

func assert_healthy{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt
) {
    alloc_locals;

    let (healthy: bool) = is_healthy(trove_id);

    with_attr error_message("Shrine: Trove LTV is too high") {
        assert healthy = TRUE;
    }

    return ();
}

// Returns a tuple of the custom threshold (maximum LTV before liquidation) of a trove and the total trove value.
// This function uses historical prices but the currently deposited yang amounts to calculate value.
// The underlying assumption is that the amount of each yang deposited remains the same throughout the recursive call.
func get_trove_threshold_and_value_internal{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    trove_id: ufelt,
    start_interval: ufelt,
    end_interval: ufelt,
    current_yang_id: ufelt,
    cumulative_weighted_threshold: ray,
    cumulative_trove_value: wad,
) -> (threshold: ray, value: wad) {
    alloc_locals;

    if (current_yang_id == 0) {
        if (cumulative_trove_value != 0) {
            // WadRay.wunsigned_div, with the numerator a ray, and the denominator a wad, returns a ray
            let threshold: ray = WadRay.wunsigned_div(
                cumulative_weighted_threshold, cumulative_trove_value
            );
            return (threshold=threshold, value=cumulative_trove_value);
        } else {
            return (threshold=0, value=0);
        }
    }

    let (deposited: wad) = shrine_deposits.read(current_yang_id, trove_id);

    // Gas optimization - skip over the current yang if the user hasn't deposited any
    if (deposited == 0) {
        return get_trove_threshold_and_value_internal(
            trove_id,
            start_interval,
            end_interval,
            current_yang_id - 1,
            cumulative_weighted_threshold,
            cumulative_trove_value,
        );
    }

    let (yang_threshold: ray) = shrine_thresholds.read(current_yang_id);

    let price: wad = get_avg_price(current_yang_id, start_interval, end_interval);
    let deposited_value: wad = WadRay.wmul(price, deposited);

    let weighted_threshold: ray = WadRay.wmul(yang_threshold, deposited_value);

    // WadRay.add_unsigned includes overflow check on result
    let cumulative_trove_value: wad = WadRay.add_unsigned(cumulative_trove_value, deposited_value);
    let cumulative_weighted_threshold: ray = WadRay.add_unsigned(
        cumulative_weighted_threshold, weighted_threshold
    );

    return get_trove_threshold_and_value_internal(
        trove_id,
        start_interval,
        end_interval,
        current_yang_id - 1,
        cumulative_weighted_threshold,
        cumulative_trove_value,
    );
}
