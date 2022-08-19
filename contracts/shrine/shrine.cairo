%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero, assert_le, unsigned_div_rem, split_felt
from starkware.cairo.common.math_cmp import is_le
from starkware.starknet.common.syscalls import get_caller_address, get_block_timestamp

from contracts.shared.convert import pack_felt, pack_125, unpack_125
from contracts.shared.types import Trove, Yang
from contracts.shared.wad_ray import WadRay
from contracts.shared.exp import exp

from contracts.lib.openzeppelin.access.accesscontrol.library import AccessControl
# these imported public functions are part of the contract's interface
from contracts.lib.acl_external import (
    has_role,
    get_role_admin,
    grant_role,
    revoke_role,
    renounce_role,
)

#
# Constants
#

# Initial multiplier value to ensure `get_recent_multiplier_from` terminates
const INITIAL_MULTIPLIER = WadRay.RAY_ONE

const MAX_THRESHOLD = WadRay.RAY_ONE
# This is the value of limit divided by threshold
# If LIMIT_RATIO = 95% and a trove's threshold LTV is 80%, then that trove's limit is (threshold LTV) * LIMIT_RATIO = 76%
const LIMIT_RATIO = 95 * WadRay.RAY_PERCENT  # 95%

const TIME_INTERVAL = 30 * 60  # 30 minutes * 60 seconds per minute
const TIME_INTERVAL_DIV_YEAR = 57077625570776  # 1 / (48 30-minute segments per day) / (365 days per year) = 0.000057077625 (wad)
# Interest rate piece-wise function parameters - all rays
const RATE_M1 = 2 * 10 ** 25  # 0.02
const RATE_B1 = 0
const RATE_M2 = 1 * 10 ** 26  # 0.1
const RATE_B2 = (-4) * 10 ** 25  # -0.04
const RATE_M3 = 10 ** 27  # 1
const RATE_B3 = (-715) * 10 ** 23  # -0.715
const RATE_M4 = 3101908 * 10 ** 21  # 3.101908
const RATE_B4 = (-2651908222) * 10 ** 18  # -2.651908222

# Interest rate piece-wise range bounds (Bound 0 is implicitly zero) - all rays
const RATE_BOUND1 = 5 * 10 ** 26  # 0.5
const RATE_BOUND2 = 75 * 10 ** 25  # 0.75
const RATE_BOUND3 = 9215 * 10 ** 23  # 0.9215

# Constants for function-level access control
# eg. const SET_CEILING = keccak256("set_ceiling")[:31]
const ADD_YANG = 'add_yang'
const UPDATE_YANG_MAX = 'update_yang_max'
const SET_CEILING = 'set_ceiling'
const SET_THRESHOLD = 'set_threshold'
const KILL = 'kill'
const ADVANCE = 'advance'
const UPDATE_MULTIPLIER = 'update_multiplier'
const MOVE_YANG = 'move_yang'
const DEPOSIT = 'deposit'
const WITHDRAW = 'withdraw'
const FORGE = 'forge'
const MELT = 'melt'
const SEIZE = 'seize'

#
# Events
#

@event
func YangAdded(yang_address, yang_id, max, start_price):
end

@event
func YangUpdated(yang_address, yang : Yang):
end

@event
func DebtTotalUpdated(total):
end

@event
func YangsCountUpdated(count):
end

@event
func MultiplierUpdated(multiplier, cumulative_multiplier, interval):
end

@event
func ThresholdUpdated(yang_address, threshold):
end

@event
func TroveUpdated(trove_id, trove : Trove):
end

@event
func DepositUpdated(trove_id, yang_address, amount):
end

@event
func YangPriceUpdated(yang_address, price, cumulative_price, interval):
end

@event
func CeilingUpdated(ceiling):
end

@event
func Killed():
end

#
# Storage
#

# A trove can forge debt up to its threshold depending on the yangs deposited.
# This mapping maps a trove to a `packed` felt containing its information.
# The first 128 bits stores the amount of debt in the trove.
# The last 123 bits stores the start time interval of the next interest accumulation period.
@storage_var
func shrine_troves_storage(trove_id) -> (packed):
end

# Stores information about each collateral (see Yang struct)
@storage_var
func shrine_yangs_storage(yang_id) -> (yang : Yang):
end

# Number of collateral accepted by the system.
# The return value is also the ID of the last added collateral.
@storage_var
func shrine_yangs_count_storage() -> (ufelt):
end

# Mapping from yang address to yang ID.
# Yang ID starts at 1.
@storage_var
func shrine_yang_id_storage(yang_address) -> (ufelt):
end

# Keeps track of how much of each yang has been deposited into each Trove - wad
@storage_var
func shrine_deposits_storage(trove_id, yang_id) -> (wad):
end

# Total amount of synthetic minted
@storage_var
func shrine_debt_storage() -> (wad):
end

# Keeps track of the price history of each Yang - packed
# interval: timestamp divided by TIME_INTERVAL.
# packed contains both the actual price (high 123 bits) and the cumulative price (low 128 bits) of
# the yang at each time interval, both as wads
@storage_var
func shrine_yang_price_storage(yang_id, interval) -> (packed):
end

# Total debt ceiling - wad
@storage_var
func shrine_ceiling_storage() -> (wad):
end

# Global interest rate multiplier - packed
# packed contains both the actual multiplier (high 123 bits), and the cumulative multiplier (low 128 bits) of
# the yang at each time interval, both as rays
@storage_var
func shrine_multiplier_storage(interval) -> (packed):
end

# Liquidation threshold per yang (as LTV) - ray
@storage_var
func shrine_thresholds_storage(yang_id) -> (ray):
end

@storage_var
func shrine_live_storage() -> (bool):
end

#
# Getters
#

@view
func get_trove{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(trove_id) -> (
    trove : Trove
):
    let (trove_packed) = shrine_troves_storage.read(trove_id)
    let (charge_from, debt) = split_felt(trove_packed)
    let trove : Trove = Trove(charge_from=charge_from, debt=debt)
    return (trove)
end

@view
func get_yang{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(yang_address) -> (
    yang : Yang
):
    let (yang_id) = shrine_yang_id_storage.read(yang_address)
    return shrine_yangs_storage.read(yang_id)
end

@view
func get_yangs_count{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    ufelt
):
    return shrine_yangs_count_storage.read()
end

@view
func get_deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    trove_id, yang_address
) -> (wad):
    let (yang_id) = shrine_yang_id_storage.read(yang_address)
    return shrine_deposits_storage.read(trove_id, yang_id)
end

@view
func get_debt{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (wad):
    return shrine_debt_storage.read()
end

@view
func get_yang_price{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_address, interval
) -> (price_wad, cumulative_price_wad):
    alloc_locals
    let (yang_id) = shrine_yang_id_storage.read(yang_address)
    let (packed) = shrine_yang_price_storage.read(yang_id, interval)
    let (price, cumulative_price) = unpack_125(packed)
    return (price, cumulative_price)
end

@view
func get_ceiling{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (wad):
    return shrine_ceiling_storage.read()
end

@view
func get_multiplier{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    interval
) -> (multiplier_ray, cumulative_multiplier_ray):
    alloc_locals
    let (packed) = shrine_multiplier_storage.read(interval)
    let (multiplier, cumulative_multiplier) = unpack_125(packed)
    return (multiplier, cumulative_multiplier)
end

@view
func get_threshold{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_address
) -> (ray):
    let (yang_id) = get_valid_yang_id(yang_address)
    return shrine_thresholds_storage.read(yang_id)
end

@view
func get_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (bool):
    return shrine_live_storage.read()
end

#
# Setters
#

@external
func add_yang{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_address, max, threshold, price
):
    alloc_locals

    AccessControl.assert_only_role(ADD_YANG)

    # Assert that yang is not already added
    let (potential_yang_id) = shrine_yang_id_storage.read(yang_address)
    with_attr error_message("Shrine: Yang already exists"):
        assert potential_yang_id = 0
    end

    # Assign ID to yang and add yang struct
    let (yang_count) = shrine_yangs_count_storage.read()
    let yang_id = yang_count + 1

    shrine_yang_id_storage.write(yang_address, yang_id)
    shrine_yangs_storage.write(yang_id, Yang(0, max))

    # Update yangs count
    shrine_yangs_count_storage.write(yang_id)

    # Set threshold
    set_threshold(yang_address, threshold)

    # Seed initial price to ensure `get_recent_price_from` terminates
    let (current_time_interval) = now()

    # Since `price` is the first price in the price history, the cumulative price is also set to `price`
    # `advance` cannot be called here since it relies on `get_recent_price_from` which needs an initial price or else it runs forever
    let (packed) = pack_125(price, price)
    shrine_yang_price_storage.write(yang_id, current_time_interval, packed)

    # Events
    YangAdded.emit(yang_address, yang_id, max, price)
    YangsCountUpdated.emit(yang_id)

    return ()
end

@external
func update_yang_max{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_address, new_max
):
    AccessControl.assert_only_role(UPDATE_YANG_MAX)

    let (yang_id) = get_valid_yang_id(yang_address)
    let (old_yang_info : Yang) = shrine_yangs_storage.read(yang_id)
    let new_yang_info : Yang = Yang(old_yang_info.total, new_max)
    shrine_yangs_storage.write(yang_id, new_yang_info)

    YangUpdated.emit(yang_address, new_yang_info)

    return ()
end

@external
func set_ceiling{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(new_ceiling):
    AccessControl.assert_only_role(SET_CEILING)

    shrine_ceiling_storage.write(new_ceiling)

    CeilingUpdated.emit(new_ceiling)

    return ()
end

# Threshold value should be a ray between 0 and 1
# Example: 75% = 75 * 10 ** 25
# Example 2: 1% = 1 * 10 ** 25
# Example 3: 1.5% = 15 * 10 ** 24
@external
func set_threshold{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_address, new_threshold
):
    AccessControl.assert_only_role(SET_THRESHOLD)

    # Check that threshold value is not greater than max threshold
    with_attr error_message("Shrine: Threshold exceeds 100%"):
        assert_le(new_threshold, MAX_THRESHOLD)
    end

    let (yang_id) = shrine_yang_id_storage.read(yang_address)
    shrine_thresholds_storage.write(yang_id, new_threshold)

    ThresholdUpdated.emit(yang_address, new_threshold)

    return ()
end

@external
func kill{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    AccessControl.assert_only_role(KILL)

    shrine_live_storage.write(FALSE)

    Killed.emit()

    return ()
end

#
# Constructor
#

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(authed):
    # Grant both roles and admin for Shrine parameters and `kill`
    AccessControl.initializer()
    AccessControl._grant_role(ADD_YANG, authed)
    AccessControl._set_role_admin(ADD_YANG, authed)

    AccessControl._grant_role(UPDATE_YANG_MAX, authed)
    AccessControl._set_role_admin(UPDATE_YANG_MAX, authed)

    AccessControl._grant_role(SET_CEILING, authed)
    AccessControl._set_role_admin(SET_CEILING, authed)

    AccessControl._grant_role(SET_THRESHOLD, authed)
    AccessControl._set_role_admin(SET_THRESHOLD, authed)

    AccessControl._grant_role(KILL, authed)
    AccessControl._set_role_admin(KILL, authed)

    # Grant admin only for Shrine actions
    AccessControl._set_role_admin(ADVANCE, authed)
    AccessControl._set_role_admin(UPDATE_MULTIPLIER, authed)
    AccessControl._set_role_admin(MOVE_YANG, authed)
    AccessControl._set_role_admin(DEPOSIT, authed)
    AccessControl._set_role_admin(WITHDRAW, authed)
    AccessControl._set_role_admin(FORGE, authed)
    AccessControl._set_role_admin(MELT, authed)
    AccessControl._set_role_admin(SEIZE, authed)

    shrine_live_storage.write(TRUE)

    # Set initial multiplier value
    let (interval) = now()
    # The initial cumulative multiplier is set to `INITIAL_MULTIPLIER`
    let (packed) = pack_125(INITIAL_MULTIPLIER, INITIAL_MULTIPLIER)
    shrine_multiplier_storage.write(interval, packed)

    # Events
    MultiplierUpdated.emit(INITIAL_MULTIPLIER, INITIAL_MULTIPLIER, interval)
    return ()
end

#
# Core functions - External
#

# Set the price of the specified Yang for a given interval
@external
func advance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_address, price
):
    alloc_locals

    AccessControl.assert_only_role(ADVANCE)

    let (interval) = now()
    let (yang_id) = get_valid_yang_id(yang_address)

    # Calculating the new cumulative price
    # To do this, we get the interval of the last price update, find the number of
    # intervals BETWEEN the current interval and the last_interval (non-inclusive), multiply that by
    # the last price, and add it to the last cumulative price. Then we add the new price, `price`.
    let (last_price, last_cumulative_price, last_interval) = get_recent_price_from(
        yang_id, interval - 1
    )
    # TODO: should there be an overflow check here?
    let new_cumulative = last_cumulative_price + (interval - last_interval - 1) * last_price + price

    let (packed) = pack_125(price, new_cumulative)
    shrine_yang_price_storage.write(yang_id, interval, packed)

    YangPriceUpdated.emit(yang_address, price, new_cumulative, interval)

    return ()
end

# Appends a new multiplier value
@external
func update_multiplier{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    new_multiplier
):
    alloc_locals
    AccessControl.assert_only_role(UPDATE_MULTIPLIER)

    let (interval) = now()

    let (last_multiplier, last_cumulative_multiplier, last_interval) = get_recent_multiplier_from(
        interval - 1
    )
    let new_cumulative_multiplier = last_cumulative_multiplier + (interval - last_interval - 1) * last_multiplier + new_multiplier

    let (packed) = pack_125(new_multiplier, new_cumulative_multiplier)
    shrine_multiplier_storage.write(interval, packed)

    MultiplierUpdated.emit(new_multiplier, new_cumulative_multiplier, interval)

    return ()
end

# Move Yang between two Troves
# Checks should be performed beforehand by the module calling this function
@external
func move_yang{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_address, amount, src_trove_id, dst_trove_id
):
    alloc_locals

    AccessControl.assert_only_role(MOVE_YANG)

    let (yang_id) = get_valid_yang_id(yang_address)

    # Charge interest for source trove to ensure it remains safe
    charge(src_trove_id)

    # Charge interest for destination trove since its collateral balance will be changed,
    # affecting its personalized interest rate due to the underlying assumption in `appraise_internal`
    # TODO: maybe move this under `assert_within_limits` call so failed `move_yang` calls are cheaper?
    # It depends on starknet handles fees for failed transactions
    charge(dst_trove_id)

    let (src_yang_balance) = shrine_deposits_storage.read(src_trove_id, yang_id)

    # Ensure source trove has sufficient yang
    with_attr error_message("Shrine: Insufficient yang"):
        # WadRay.sub_unsigned asserts (src_yang_balance - amount) >= 0
        let (new_src_balance) = WadRay.sub_unsigned(src_yang_balance, amount)
    end

    # Update yang balance of source trove
    shrine_deposits_storage.write(src_trove_id, yang_id, new_src_balance)

    # Assert source trove is within limits
    assert_within_limits(src_trove_id)

    # Update yang balance of destination trove
    let (dst_yang_balance) = shrine_deposits_storage.read(dst_trove_id, yang_id)
    let (new_dst_balance) = WadRay.add_unsigned(dst_yang_balance, amount)
    shrine_deposits_storage.write(dst_trove_id, yang_id, new_dst_balance)

    # Events
    DepositUpdated.emit(src_trove_id, yang_address, new_src_balance)
    DepositUpdated.emit(dst_trove_id, yang_address, new_dst_balance)

    return ()
end

# Deposit a specified amount of a Yang into a Trove
@external
func deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_address, amount, trove_id
):
    alloc_locals

    AccessControl.assert_only_role(DEPOSIT)

    # Check system is live
    assert_live()

    # Charge interest
    charge(trove_id)

    # Update yang balance of system
    let (yang_id) = get_valid_yang_id(yang_address)
    let (old_yang_info : Yang) = shrine_yangs_storage.read(yang_id)
    let (new_total) = WadRay.add(old_yang_info.total, amount)

    # Asserting that the deposit does not cause the total amount of yang deposited to exceed the max.
    with_attr error_message("Shrine: Exceeds maximum amount of Yang allowed for system"):
        assert_le(new_total, old_yang_info.max)
    end

    let new_yang_info : Yang = Yang(total=new_total, max=old_yang_info.max)
    shrine_yangs_storage.write(yang_id, new_yang_info)

    # Update yang balance of trove
    let (trove_yang_balance) = shrine_deposits_storage.read(trove_id, yang_id)
    let (new_trove_balance) = WadRay.add(trove_yang_balance, amount)
    shrine_deposits_storage.write(trove_id, yang_id, new_trove_balance)

    # Events
    YangUpdated.emit(yang_address, new_yang_info)
    DepositUpdated.emit(trove_id, yang_address, new_trove_balance)

    return ()
end

# Withdraw a specified amount of a Yang from a Trove
@external
func withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_address, amount, trove_id
):
    alloc_locals

    AccessControl.assert_only_role(WITHDRAW)

    # Retrieve yang info
    let (yang_id) = get_valid_yang_id(yang_address)
    let (old_yang_info : Yang) = shrine_yangs_storage.read(yang_id)

    # Ensure trove has sufficient yang
    let (trove_yang_balance) = shrine_deposits_storage.read(trove_id, yang_id)

    with_attr error_message("Shrine: Insufficient yang"):
        # WadRay.sub_unsigned asserts (trove_yang_balance - amount) >= 0
        let (new_trove_balance) = WadRay.sub_unsigned(trove_yang_balance, amount)
    end

    # Charge interest
    charge(trove_id)

    # Update yang balance of system
    let (new_total) = WadRay.sub_unsigned(old_yang_info.total, amount)
    let new_yang_info : Yang = Yang(total=new_total, max=old_yang_info.max)
    shrine_yangs_storage.write(yang_id, new_yang_info)

    # Update yang balance of trove
    shrine_deposits_storage.write(trove_id, yang_id, new_trove_balance)

    # Check if Trove is within limits
    assert_within_limits(trove_id)

    # Events
    YangUpdated.emit(yang_address, new_yang_info)
    DepositUpdated.emit(trove_id, yang_address, new_trove_balance)

    return ()
end

# Mint a specified amount of synthetic for a Trove
@external
func forge{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(amount, trove_id):
    alloc_locals

    AccessControl.assert_only_role(FORGE)

    # Check system is live
    assert_live()

    # Charge interest
    charge(trove_id)  # TODO: Maybe move this under the debt ceiling check to save gas in case of failed tx

    # Get current Trove information
    let (old_trove_info : Trove) = get_trove(trove_id)

    # Get current interval
    let (current_interval) = now()

    # Check that debt ceiling has not been reached
    let (current_system_debt) = shrine_debt_storage.read()

    with_attr error_message("Shrine: system debt overflow"):
        let (new_system_debt) = WadRay.add(current_system_debt, amount)  # WadRay.add checks for overflow
    end

    let (debt_ceiling) = shrine_ceiling_storage.read()

    # Debt ceiling check
    with_attr error_message("Shrine: Debt ceiling reached"):
        assert_le(new_system_debt, debt_ceiling)
    end

    # Update system debt
    shrine_debt_storage.write(new_system_debt)

    # Initialise `Trove.charge_from` to current interval if old debt was 0.
    # Otherwise, set `Trove.charge_from` to current interval + 1 because interest has been
    # charged up to current interval.
    if old_trove_info.debt == 0:
        tempvar new_charge_from = current_interval
    else:
        tempvar new_charge_from = old_trove_info.charge_from
    end

    # Update trove information
    let (new_debt) = WadRay.add(old_trove_info.debt, amount)
    let new_trove_info : Trove = Trove(charge_from=new_charge_from, debt=new_debt)
    set_trove(trove_id, new_trove_info)

    # Check if Trove is within limits
    assert_within_limits(trove_id)

    # Events
    DebtTotalUpdated.emit(new_system_debt)
    TroveUpdated.emit(trove_id, new_trove_info)

    return ()
end

# Repay a specified amount of synthetic for a Trove
# The module calling this function should check that `amount` does not exceed Trove's debt.
@external
func melt{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(amount, trove_id):
    alloc_locals

    AccessControl.assert_only_role(MELT)

    # Charge interest
    charge(trove_id)

    # Get current Trove information
    let (old_trove_info : Trove) = get_trove(trove_id)

    # Get current interval
    let (current_interval) = now()

    # Update system debt
    let (current_system_debt) = shrine_debt_storage.read()

    with_attr error_message("Shrine: System debt underflow"):
        let (new_system_debt) = WadRay.sub_unsigned(current_system_debt, amount)  # WadRay.sub_unsigned contains an underflow check
    end

    shrine_debt_storage.write(new_system_debt)

    # Update trove information
    let (new_debt) = WadRay.sub(old_trove_info.debt, amount)
    let new_trove_info : Trove = Trove(charge_from=current_interval, debt=new_debt)
    set_trove(trove_id, new_trove_info)

    # Events
    DebtTotalUpdated.emit(new_system_debt)
    TroveUpdated.emit(trove_id, new_trove_info)

    return ()
end

# Seize a Trove for liquidation by transferring the debt and yang to the appropriate module
# Checks should be performed beforehand by the module calling this function
@external
func seize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(trove_id):
    AccessControl.assert_only_role(SEIZE)

    # Update Trove information
    let (old_trove_info : Trove) = get_trove(trove_id)
    let new_trove_info : Trove = Trove(charge_from=old_trove_info.charge_from, debt=0)

    # TODO Transfer outstanding debt (old_trove_info.debt) to the appropriate module

    # TODO Iterate over yangs and transfer balance to the appropriate module

    # TODO Events?

    return ()
end

#
# Core Functions - View
#

# Gets the custom threshold (maximum LTV before liquidation) of a trove
# Also returns the total trove value.
# This is because it needs to calculate the trove value anyway, and `is_healthy` needs the trove value, so it
# saves some gas to just return it rather than having to calculate it again with `appraise`.
@view
func get_trove_threshold{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    trove_id
) -> (threshold_ray, value_wad):
    alloc_locals

    let (yang_count) = shrine_yangs_count_storage.read()
    let (current_time_id) = now()
    return get_trove_threshold_internal(trove_id, current_time_id, yang_count, 0, 0)
end

# Calculate a Trove's current loan-to-value ratio
# returns a ray
@view
func get_current_trove_ratio{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    trove_id
) -> (ray):
    alloc_locals

    let (trove : Trove) = get_trove(trove_id)
    let (interval) = now()
    return trove_ratio(trove_id, interval, trove.debt)
end

# Get the last updated price for a yang
@view
func get_current_yang_price{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_address
) -> (price_wad, cumulative_price_wad):
    alloc_locals

    let (yang_id) = shrine_yang_id_storage.read(yang_address)
    let (interval) = now()  # Get current interval
    let (price_wad, cumulative_price_wad, _) = get_recent_price_from(yang_id, interval)
    return (price_wad, cumulative_price_wad)
end

# Gets last updated multiplier value
@view
func get_current_multiplier{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    ) -> (multiplier_ray, cumulative_multiplier_ray, interval_ufelt):
    let (interval) = now()
    return get_recent_multiplier_from(interval)
end

# Returns the debt a trove owes, including any interest that has accumulated since
# `Trove.charge_from` but not accrued to `Trove.debt` yet.
@view
func estimate{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(trove_id) -> (wad):
    alloc_locals

    let (trove : Trove) = get_trove(trove_id)

    # Early termination if no debt
    if trove.debt == 0:
        return (trove.debt)
    end

    let (current_interval) = now()

    return compound(trove_id, trove.debt, trove.charge_from, current_interval)
end

# Returns a bool indicating whether the given trove is healthy or not
@view
func is_healthy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(trove_id) -> (
    bool
):
    alloc_locals

    let (trove : Trove) = get_trove(trove_id)

    # Early termination if trove has no debt
    if trove.debt == 0:
        return (TRUE)
    end

    let (threshold, value) = get_trove_threshold(trove_id)  # Getting the trove's custom threshold and total collateral value
    let (max_debt) = WadRay.rmul(threshold, value)  # Calculating the maximum amount of debt the trove can have
    let (bool) = is_le(trove.debt, max_debt)

    return (bool)
end

@view
func is_within_limits{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    trove_id
) -> (bool):
    alloc_locals

    let (trove : Trove) = get_trove(trove_id)

    # Early terminating if trove has no debt
    if trove.debt == 0:
        return (TRUE)
    end

    let (threshold, value) = get_trove_threshold(trove_id)
    let (limit) = WadRay.rmul(LIMIT_RATIO, threshold)  # limit = limit_ratio * threshold
    let (max_debt) = WadRay.rmul(limit, value)
    let (bool) = is_le(trove.debt, max_debt)

    return (bool)
end

@view
func get_max_forge{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(trove_id) -> (
    wad
):
    alloc_locals

    let (trove : Trove) = get_trove(trove_id)

    let (can_forge) = is_within_limits(trove_id)

    # Early termination if trove is not within limits
    if can_forge == FALSE:
        return (0)
    end

    let (threshold, value) = get_trove_threshold(trove_id)
    let (limit) = WadRay.rmul(LIMIT_RATIO, threshold)  # limit = limit_ratio * threshold
    let (max_debt) = WadRay.rmul(limit, value)

    # Get updated debt with interest
    let (current_debt) = estimate(trove_id)
    let max_forge_amt = max_debt - current_debt

    return (max_forge_amt)
end

#
# Internal
#

func assert_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    # Check system is live
    let (live) = shrine_live_storage.read()

    with_attr error_message("Shrine: System is not live"):
        assert live = TRUE
    end

    return ()
end

# Helper function to get the yang ID given a yang address, and throw an error if
# yang address has not been added (i.e. yang ID = 0)
func get_valid_yang_id{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_address
) -> (ufelt):
    let (yang_id) = shrine_yang_id_storage.read(yang_address)

    with_attr error_message("Shrine: Yang does not exist"):
        assert_not_zero(yang_id)
    end

    return (yang_id)
end

func set_trove{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    trove_id, trove : Trove
):
    let (packed_trove) = pack_felt(trove.charge_from, trove.debt)
    shrine_troves_storage.write(trove_id, packed_trove)
    return ()
end

# Wrapper function for the recursive `appraise_internal` function that gets the most recent trove value
func appraise{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(trove_id) -> (wad):
    alloc_locals

    let (yang_count) = shrine_yangs_count_storage.read()
    let (interval) = now()
    let (value) = appraise_internal(trove_id, yang_count, interval, 0)
    return (value)
end

func now{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (ufelt):
    let (time) = get_block_timestamp()
    let (interval, _) = unsigned_div_rem(time, TIME_INTERVAL)
    return (interval)
end

# Adds the accumulated interest as debt to the trove
func charge{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(trove_id):
    alloc_locals
    # Get trove info
    let (trove : Trove) = get_trove(trove_id)

    # Early termination if no debt
    if trove.debt == 0:
        return ()
    end

    # Get current interval
    let (current_interval) = now()

    # Early termination if trove has just been charged (that is, if

    # Get new debt amount
    let (new_debt) = compound(trove_id, trove.debt, trove.charge_from, current_interval)

    # Update trove
    let updated_trove : Trove = Trove(charge_from=current_interval, debt=new_debt)
    set_trove(trove_id, updated_trove)

    # Get old system debt amount
    let (old_system_debt) = shrine_debt_storage.read()

    # Get interest charged
    let (diff) = WadRay.sub_unsigned(new_debt, trove.debt)  # TODO: should this be unchecked? `new_debt` >= `trove.debt` is guaranteed

    # Get new system debt
    tempvar new_system_debt = old_system_debt + diff

    shrine_debt_storage.write(new_system_debt)

    # Events
    DebtTotalUpdated.emit(new_system_debt)
    TroveUpdated.emit(trove_id, updated_trove)

    return ()
end

# Returns the amount of debt owed by trove after having interest charged over a given time period
# Assumes the trove hasn't minted or paid back any additional debt during the given time period
# Assumes the trove hasn't deposited or withdrawn any additional collateral during the given time period
# Time period includes `end_interval` and does NOT include `start_interval`.

# Compound interest formula: P(t) = P_0 * e^(rt)
# P_0 = principal
# r = nominal interest rate (what the interest rate would be if there was no compounding
# t = time elapsed, in years
func compound{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    trove_id, current_debt, start_interval, end_interval
) -> (wad):
    alloc_locals

    let (avg_ratio) = get_avg_ratio(trove_id, current_debt, start_interval, end_interval)
    let (avg_multiplier) = get_avg_multiplier(start_interval, end_interval)

    let (base_rate) = get_base_rate(avg_ratio)
    let (true_rate) = WadRay.rmul(base_rate, avg_multiplier)  # represents `r` in the compound interest formula

    let t = (end_interval - start_interval) * TIME_INTERVAL_DIV_YEAR  # wad, represents `t` in the compound interest formula

    # Using `rmul` on a ray and a wad yields a wad, which we need since `exp` only takes wads
    let (rt) = WadRay.rmul(true_rate, t)
    let (e_pow_rt) = exp(rt)

    let (new_debt) = WadRay.wmul(current_debt, e_pow_rt)
    return (new_debt)
end

# base rate function:
#
#
#           { 0.02*LTV                   if 0 <= LTV <= 0.5
#           { 0.1*LTV - 0.04             if 0.5 < LTV <= 0.75
#  r(LTV) = { LTV - 0.715                if 0.75 < LTV <= 0.9215
#           { 3.101908*LTV - 2.65190822  if 0.9215 < LTV < \infinity
#
#

# `ratio` is expected to be a ray
func get_base_rate{range_check_ptr}(ratio) -> (ray):
    alloc_locals

    let (is_in_first_range) = is_le(ratio, RATE_BOUND1)
    if is_in_first_range == TRUE:
        let (rate) = linear(ratio, RATE_M1, RATE_B1)
        return (rate)
    end

    let (is_in_second_range) = is_le(ratio, RATE_BOUND2)
    if is_in_second_range == TRUE:
        let (rate) = linear(ratio, RATE_M2, RATE_B2)
        return (rate)
    end

    let (is_in_third_range) = is_le(ratio, RATE_BOUND3)
    if is_in_third_range == TRUE:
        let (rate) = linear(ratio, RATE_M3, RATE_B3)
        return (rate)
    end

    let (rate) = linear(ratio, RATE_M4, RATE_B4)
    return (rate)
end

# y = m*x + b
# m, x, b, and y are all rays
func linear{range_check_ptr}(x, m, b) -> (ray):
    let (m_x) = WadRay.rmul(m, x)
    let (y) = WadRay.add(m_x, b)
    return (y)
end

# Calculates the trove's LTV at the given interval.
# See comments above `appraise_internal` for the underlying assumption on which the correctness of the result depends.
# Another assumption here is that if trove debt is non-zero, then there is collateral in the trove
# Returns a ray.
func trove_ratio{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    trove_id, interval, debt
) -> (ray):
    # Early termination if no debt
    if debt == 0:
        return (0)
    end

    let (yang_count) = shrine_yangs_count_storage.read()
    let (value) = appraise_internal(trove_id, yang_count, interval, 0)

    let (ratio) = WadRay.runsigned_div(debt, value)  # Using WadRay.runsigned_div on two wads returns a ray
    return (ratio)
end

# Gets the value of a trove at the yang prices at the given interval.
# For any yang that returns a price of 0 for the given interval, it uses the most recent available price before that interval.
# This function uses historical prices but the currently deposited yang amounts to calculate value.
# The underlying assumption is that the amount of each yang deposited remains the same throughout the recursive call.
func appraise_internal{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    trove_id, yang_id, interval, cumulative
) -> (wad):
    alloc_locals

    # Terminate when yang ID reaches 0
    if yang_id == 0:
        return (cumulative)
    end

    # Calculate current yang value
    let (balance) = shrine_deposits_storage.read(trove_id, yang_id)

    # Skip over the rest of the logic if the user hasn't deposited any
    if balance == 0:
        return appraise_internal(trove_id, yang_id - 1, interval, cumulative)
    end

    let (price, _, _) = get_recent_price_from(yang_id, interval)

    # Reverts if price is zero
    with_attr error_message("Shrine: Yang price can never be zero"):
        assert_not_zero(price)
    end

    let (value) = WadRay.wmul(balance, price)

    # Update cumulative value
    let (updated_cumulative) = WadRay.add_unsigned(cumulative, value)

    # Recursive call
    return appraise_internal(trove_id, yang_id - 1, interval, updated_cumulative)
end

# Returns the price for `yang_id` at `interval` if it is non-zero.
# Otherwise, check `interval` - 1 recursively for the last available price.
func get_recent_price_from{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_id, interval
) -> (price_wad, cumulative_price_wad, interval_ufelt):
    alloc_locals
    let (packed) = shrine_yang_price_storage.read(yang_id, interval)

    if packed != 0:
        let (price, cumulative_price) = unpack_125(packed)
        return (price, cumulative_price, interval)
    end

    return get_recent_price_from(yang_id, interval - 1)
end

# Returns the multiplier at `interval` if it is non-zero.
# Otherwise, check `interval` - 1 recursively for the last available value.
func get_recent_multiplier_from{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    interval
) -> (multiplier_ray, cumulative_multiplier_ray, interval_ufelt):
    alloc_locals
    let (packed) = shrine_multiplier_storage.read(interval)

    if packed != 0:
        let (multiplier, cumulative_multiplier) = unpack_125(packed)
        return (multiplier, cumulative_multiplier, interval)
    end

    return get_recent_multiplier_from(interval - 1)
end

# Returns the average multiplier over the specified time period, including `end_interval` but NOT including `start_interval`
func get_avg_multiplier{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    start_interval, end_interval
) -> (ray):
    alloc_locals

    let (end_multiplier, end_cumulative_multiplier, _) = get_recent_multiplier_from(end_interval)

    # If `start_interval` == `end_interval`, then the "average" multiplier is simply
    # the multiplier at `end_interval` (or equally, the multiplier at `start_interval`
    if start_interval == end_interval:
        return (end_multiplier)
    end

    let (_, start_cumulative_multiplier, _) = get_recent_multiplier_from(start_interval)

    let (avg_multiplier, _) = unsigned_div_rem(
        end_cumulative_multiplier - start_cumulative_multiplier, end_interval - start_interval
    )

    return (avg_multiplier)
end

# Returns the average LTV of a trove over the specified time period
func get_avg_ratio{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    trove_id, debt, start_interval, end_interval
) -> (ray):
    # Getting average value of the trove
    let (num_yangs) = shrine_yangs_count_storage.read()

    let (avg_val) = get_avg_val_internal(trove_id, start_interval, end_interval, num_yangs, 0)

    let (avg_ratio) = WadRay.runsigned_div(debt, avg_val)  # Dividing two wads with `runsigned_div` yields a ray
    return (avg_ratio)
end

# Returns the average value of a trove over the specified period of time
# Includes the values at `end_interval` but NOT `start_interval` in the average
func get_avg_val_internal{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    trove_id, start_interval, end_interval, current_yang_id, cumulative_val
) -> (wad):
    alloc_locals

    # Terminate if all yangs have been iterated over already
    if current_yang_id == 0:
        return (cumulative_val)
    end

    let (balance) = shrine_deposits_storage.read(trove_id, current_yang_id)

    # Skipping over the rest of the logic if the user hasn't deposited anything for this yang
    if balance == 0:
        return get_avg_val_internal(
            trove_id, start_interval, end_interval, current_yang_id - 1, cumulative_val
        )
    end

    # If start_interval == end_interval, then the average price is simply the price at
    # `start_interval` (or equally, the price at `end_interval`)
    if start_interval == end_interval:
        let (price, _, _) = get_recent_price_from(current_yang_id, start_interval)
        let (balance_val) = WadRay.wmul(balance, price)
        WadRay.assert_result_valid(cumulative_val + balance_val)  # Overflow check

        return get_avg_val_internal(
            trove_id,
            start_interval,
            end_interval,
            current_yang_id - 1,
            cumulative_val + balance_val,
        )
    end

    let (_, end_cumulative_price, _) = get_recent_price_from(current_yang_id, end_interval)
    let (_, start_cumulative_price, _) = get_recent_price_from(current_yang_id, start_interval)

    let (avg_price, _) = unsigned_div_rem(
        end_cumulative_price - start_cumulative_price, end_interval - start_interval
    )

    let (balance_val) = WadRay.wmul(balance, avg_price)
    WadRay.assert_result_valid(cumulative_val + balance_val)  # Overflow check

    return get_avg_val_internal(
        trove_id, start_interval, end_interval, current_yang_id - 1, cumulative_val + balance_val
    )
end

#
# Trove health internal functions
#

func assert_unhealthy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(trove_id):
    alloc_locals

    let (healthy) = is_healthy(trove_id)

    with_attr error_message("Shrine: Trove is not liquidatable"):
        assert healthy = FALSE
    end

    return ()
end

func assert_within_limits{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    trove_id
):
    alloc_locals

    let (within_limits) = is_within_limits(trove_id)

    with_attr error_message("Shrine: Trove LTV is too high"):
        assert within_limits = TRUE
    end

    return ()
end

func get_trove_threshold_internal{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
}(
    trove_id,
    current_time_id,
    current_yang_id,
    cumulative_weighted_threshold,
    cumulative_trove_value,
) -> (threshold_ray, value_wad):
    alloc_locals

    if current_yang_id == 0:
        if cumulative_trove_value != 0:
            # WadRay.wunsigneddiv, with the numerator a ray, and the denominator a wad, returns a ray
            let (threshold) = WadRay.wunsigned_div(
                cumulative_weighted_threshold, cumulative_trove_value
            )
            return (threshold_ray=threshold, value_wad=cumulative_trove_value)
        else:
            return (threshold_ray=0, value_wad=0)
        end
    end

    let (deposited) = shrine_deposits_storage.read(trove_id, current_yang_id)

    # Gas optimization - skip over the current yang if the user hasn't deposited any
    if deposited == 0:
        return get_trove_threshold_internal(
            trove_id,
            current_time_id,
            current_yang_id - 1,
            cumulative_weighted_threshold,
            cumulative_trove_value,
        )
    end

    let (yang_threshold) = shrine_thresholds_storage.read(current_yang_id)

    let (yang_price, _, _) = get_recent_price_from(current_yang_id, current_time_id)

    let (deposited_value) = WadRay.wmul(yang_price, deposited)
    # Since we're using wmul on the product of a wad and a ray, the result is a ray
    let (weighted_threshold) = WadRay.wmul(yang_threshold, deposited_value)

    let (cumulative_weighted_threshold) = WadRay.add(
        cumulative_weighted_threshold, weighted_threshold
    )
    let (cumulative_trove_value) = WadRay.add(cumulative_trove_value, deposited_value)

    return get_trove_threshold_internal(
        trove_id,
        current_time_id,
        current_yang_id - 1,
        cumulative_weighted_threshold,
        cumulative_trove_value,
    )
end
