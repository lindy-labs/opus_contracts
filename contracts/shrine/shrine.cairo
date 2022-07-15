%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero, assert_le, unsigned_div_rem, split_felt
from starkware.cairo.common.math_cmp import is_le
from starkware.starknet.common.syscalls import get_caller_address, get_block_timestamp

from contracts.shared.convert import pack_felt
from contracts.shared.types import Trove, Yang
from contracts.shared.wad_ray import WadRay

from contracts.lib.auth import Auth

#
# Constants
#

# Initial multiplier value to ensure `get_recent_multiplier_from` terminates
const INITIAL_MULTIPLIER = WadRay.RAY_ONE

const MAX_THRESHOLD = WadRay.RAY_ONE
# This is the value of limit divided by threshold
# If LIMIT_RATIO = 95% and a trove's threshold LTV is 80%, then that trove's limit is (threshold LTV) * LIMIT_RATIO = 76%
const LIMIT_RATIO = 95 * 10 ** 16  # 95%

const TIME_INTERVAL = 24 * 60 * 60  # 24 hours * 60 minutes per hour * 60 seconds per minute
const TIME_INTERVAL_DIV_YEAR = 2739726020000000000000000  # 1 day / 365 days = 0.00273972602 (ray)
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
func MultiplierUpdated(multiplier, interval):
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
func YangPriceUpdated(yang_address, price, interval):
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

# Keeps track of the price history of each Yang - wad
# interval: timestamp-divided by TIME_INTERVAL.
@storage_var
func shrine_yang_price_storage(yang_id, interval) -> (wad):
end

# Total debt ceiling - wad
@storage_var
func shrine_ceiling_storage() -> (wad):
end

# Global interest rate multiplier - ray
@storage_var
func shrine_multiplier_storage(interval) -> (ray):
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
func get_auth{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address) -> (bool):
    return Auth.is_authorized(address)
end

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
func get_shrine_debt{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (wad):
    return shrine_debt_storage.read()
end

@view
func get_yang_price{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_address, interval
) -> (wad):
    let (yang_id) = shrine_yang_id_storage.read(yang_address)
    return shrine_yang_price_storage.read(yang_id, interval)
end

@view
func get_ceiling{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (wad):
    return shrine_ceiling_storage.read()
end

@view
func get_multiplier{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    interval
) -> (ray):
    return shrine_multiplier_storage.read(interval)
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

    Auth.assert_caller_authed()

    # Assert that yang is not already added
    let (yang_id) = shrine_yang_id_storage.read(yang_address)
    with_attr error_message("Shrine: Yang already exists"):
        assert yang_id = 0
    end

    # Assign ID to yang and add yang struct
    let (yang_count) = shrine_yangs_count_storage.read()
    shrine_yang_id_storage.write(yang_address, yang_count + 1)
    shrine_yangs_storage.write(yang_count + 1, Yang(0, max))

    # Update yangs count
    shrine_yangs_count_storage.write(yang_count + 1)

    # Set threshold
    set_threshold(yang_address, threshold)

    # Seed initial price to ensure `get_recent_price_from` terminates
    advance(yang_address, price)

    # Events
    YangAdded.emit(yang_address, yang_count + 1, max, price)
    YangsCountUpdated.emit(yang_count + 1)

    return ()
end

@external
func update_yang_max{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_address, new_max
):
    Auth.assert_caller_authed()

    let (yang_id) = get_valid_yang_id(yang_address)
    let (old_yang_info : Yang) = shrine_yangs_storage.read(yang_id)
    let new_yang_info : Yang = Yang(old_yang_info.total, new_max)
    shrine_yangs_storage.write(yang_id, new_yang_info)

    YangUpdated.emit(yang_address, new_yang_info)

    return ()
end

@external
func set_ceiling{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(new_ceiling):
    Auth.assert_caller_authed()

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
    Auth.assert_caller_authed()

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
    Auth.assert_caller_authed()

    shrine_live_storage.write(FALSE)

    Killed.emit()

    return ()
end

#
# Constructor
#

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(authed):
    Auth.authorize(authed)
    shrine_live_storage.write(TRUE)

    # Set initial multiplier value
    let (interval) = now()
    shrine_multiplier_storage.write(interval, INITIAL_MULTIPLIER)

    # Events
    MultiplierUpdated.emit(INITIAL_MULTIPLIER, interval)

    return ()
end

#
# Core functions - External
#

@external
func authorize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
    Auth.assert_caller_authed()
    Auth.authorize(address)
    return ()
end

@external
func revoke{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
    Auth.assert_caller_authed()
    Auth.revoke(address)
    return ()
end

# Set the price of the specified Yang for a given interval
@external
func advance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_address, price
):
    alloc_locals

    Auth.assert_caller_authed()

    let (interval) = now()
    let (yang_id) = get_valid_yang_id(yang_address)
    shrine_yang_price_storage.write(yang_id, interval, price)

    YangPriceUpdated.emit(yang_address, price, interval)

    return ()
end

# Appends a new multiplier value
@external
func update_multiplier{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    new_multiplier
):
    Auth.assert_caller_authed()

    let (interval) = now()
    shrine_multiplier_storage.write(interval, new_multiplier)

    MultiplierUpdated.emit(new_multiplier, interval)

    return ()
end

# Move Yang between two Troves
# Checks should be performed beforehand by the module calling this function
@external
func move_yang{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_address, amount, src_trove_id, dst_trove_id
):
    alloc_locals

    Auth.assert_caller_authed()

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

    Auth.assert_caller_authed()

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

    Auth.assert_caller_authed()

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

    Auth.assert_caller_authed()

    # Check system is live
    assert_live()

    # Charge interest
    charge(trove_id)

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

    Auth.assert_caller_authed()

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
    let new_trove_info : Trove = Trove(charge_from=current_interval + 1, debt=new_debt)
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
    Auth.assert_caller_authed()

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
# Also returns the total trove value
# `threshold` and `value` are both wads
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
) -> (wad):
    alloc_locals

    let (yang_id) = shrine_yang_id_storage.read(yang_address)
    let (interval) = now()  # Get current interval
    return get_recent_price_from(yang_id, interval)
end

# Gets last updated multiplier value
@view
func get_current_multiplier{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    ) -> (ray):
    let (interval) = now()
    let (m) = get_recent_multiplier_from(interval)
    return (m)
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

    return compound(trove_id, trove.charge_from, current_interval + 1, trove.debt)
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
    let (limit) = WadRay.wmul(LIMIT_RATIO, threshold)  # limit = limit_ratio * threshold
    let (max_debt) = WadRay.rmul(limit, value)
    let (bool) = is_le(trove.debt, max_debt)

    return (bool)
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

    # Get new debt amount
    let (new_debt) = compound(trove_id, trove.charge_from, current_interval + 1, trove.debt)

    # Update Trove
    let updated_trove : Trove = Trove(charge_from=current_interval + 1, debt=new_debt)
    set_trove(trove_id, updated_trove)

    # Get old system debt amount
    let (old_system_debt) = shrine_debt_storage.read()

    # Get interest charged
    let (diff) = WadRay.sub_unsigned(new_debt, trove.debt)

    # Get new system debt
    let new_system_debt = old_system_debt + diff

    # Overflow check
    with_attr error_message("Shrine: System debt overflow"):
        WadRay.assert_result_valid(new_system_debt)
    end

    shrine_debt_storage.write(new_system_debt)

    # Events
    DebtTotalUpdated.emit(new_system_debt)
    TroveUpdated.emit(trove_id, updated_trove)

    return ()
end

# Inner function for calculating accumulated interest.
# Recursively iterates over time intervals from `current_interval` to `final_interval` and compounds the interest owed over all of them
func compound{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    trove_id, current_interval, final_interval, debt
) -> (wad):
    alloc_locals

    # Terminate if final_interval <= current_interval
    let (finished) = is_le(final_interval, current_interval)
    if finished == TRUE:
        return (debt)
    end

    # Get LTV for Trove at the given time ID
    let (ratio) = trove_ratio(trove_id, current_interval, debt)

    # Get base rate using LTV
    let (rate) = base_rate(ratio)

    # Get multiplier at the given time ID
    let (m) = get_recent_multiplier_from(current_interval)

    # Derive the interest rate
    let (real_rate) = WadRay.rmul(rate, m)

    # Derive the real interest rate to be charged
    let (percent_owed) = WadRay.rmul(real_rate, TIME_INTERVAL_DIV_YEAR)

    # Compound the debt
    let (amount_owed) = WadRay.rmul(debt, percent_owed)  # Returns a wad
    let (new_debt) = WadRay.add(debt, amount_owed)

    # Recursive call
    return compound(trove_id, current_interval + 1, final_interval, new_debt)
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

# `ratio` is expected to be a felt
func base_rate{range_check_ptr}(ratio) -> (ray):
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

func set_trove{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    trove_id, trove : Trove
):
    let (packed_trove) = pack_felt(trove.debt, trove.charge_from)
    shrine_troves_storage.write(trove_id, packed_trove)
    return ()
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

    let (price) = get_recent_price_from(yang_id, interval)

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
) -> (wad):
    let (price) = shrine_yang_price_storage.read(yang_id, interval)

    if price != 0:
        return (price)
    end

    return get_recent_price_from(yang_id, interval - 1)
end

# Returns the multiplier at `interval` if it is non-zero.
# Otherwise, check `interval` - 1 recursively for the last available value.
func get_recent_multiplier_from{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    interval
) -> (ray):
    let (m) = shrine_multiplier_storage.read(interval)

    if m != 0:
        return (ray=m)
    end

    return get_recent_multiplier_from(interval - 1)
end

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

    let (yang_price) = get_recent_price_from(current_yang_id, current_time_id)

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
