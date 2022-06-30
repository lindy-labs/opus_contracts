%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero, assert_le, unsigned_div_rem, split_felt
from starkware.cairo.common.math_cmp import is_le
from starkware.starknet.common.syscalls import get_caller_address, get_block_timestamp

from contracts.shared.types import Trove, Gage, pack_felt
from contracts.shared.wad_ray import WadRay

#
# Constants
#

const MAX_THRESHOLD = WadRay.WAD_ONE

const TIME_INTERVAL = 30 * 60  # 30 minutes * 60 seconds per minute
const TIME_INTERVAL_DIV_YEAR = 57077625570776250000000  # 1 / (2 : felt* 24 : felt* 365) = 0.00005707762557077625 (ray)

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
func Authorized(address):
end

@event
func Revoked(address):
end

@event
func GageAdded(gage_address, gage_id, max):
end

@event
func GageTotalUpdated(gage_address, new_total):
end

@event
func GageMaxUpdated(gage_address, new_max):
end

@event
func SyntheticTotalUpdated(new_total):
end

@event
func NumGagesUpdated(num):
end

@event
func MultiplierUpdated(new_multiplier, interval):
end

@event
func ThresholdUpdated(new_threshold):
end

@event
func TroveUpdated(address, trove_id, updated_trove : Trove):
end

@event
func DepositUpdated(address, trove_id, gage_address, new_amount):
end

@event
func SeriesIncremented(gage_address, interval, price):
end

@event
func CeilingUpdated(ceiling):
end

@event
func Killed():
end

#
# Auth
#

@storage_var
func shrine_auth(address) -> (bool):
end

# Similar to onlyOwner
func assert_auth{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    let (c) = get_caller_address()
    let (is_authed) = shrine_auth.read(c)
    assert is_authed = TRUE
    return ()
end

@external
func authorize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
    assert_auth()
    shrine_auth.write(address, TRUE)
    Authorized.emit(address)
    return ()
end

@external
func revoke{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
    assert_auth()
    shrine_auth.write(address, FALSE)
    Revoked.emit(address)
    return ()
end

@view
func get_auth{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address) -> (bool):
    return shrine_auth.read(address)
end

#
# Storage
#

# A trove can forge debt up to its threshold depending on the gages deposited.
# Each user has multiple shrine_troves that they can deposit collateral into and mint synthetic against.
# This mapping maps a trove to a `packed` felt containing its information.
# The first 128 bits contain the amount of debt in the trove.
# The last 123 bits contain the time interval of start of the next interest accumulation period
@storage_var
func shrine_troves(address, trove_id) -> (packed):
end

# Stores information about each gage (see Gage struct)
@storage_var
func shrine_gages(gage_id) -> (gage : Gage):
end

# Number of gages accepted by the system.
# The return value is also the ID of the last added gage.
@storage_var
func shrine_num_gages() -> (ufelt):
end

# Mapping from gage address to gage ID.
# Gage ID starts at 1.
@storage_var
func shrine_gage_id(gage_address) -> (ufelt):
end

# Keeps track of how much of each gage has been deposited into each Trove - wad
@storage_var
func shrine_deposited(address, trove_id, gage_id) -> (wad):
end

# Total amount of synthetic minted
@storage_var
func shrine_synthetic() -> (wad):
end

# Keeps track of the price history of each Gage - wad
# interval: timestamp-divided by TIME_INTERVAL.
# TODO: Maybe this should be a ray?
@storage_var
func shrine_series(gage_id, interval) -> (wad):
end

# Total debt ceiling - wad
@storage_var
func shrine_ceiling() -> (wad):
end

# Global interest rate multiplier - ray
@storage_var
func shrine_multiplier(interval) -> (ray):
end

# Liquidation threshold (or max LTV) - wad
# TODO: Maybe this should be a ray?
@storage_var
func shrine_threshold() -> (wad):
end

@storage_var
func shrine_live() -> (bool):
end

#
# Getters
#

@view
func get_trove{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    address, trove_id
) -> (trove : Trove):
    let (trove_packed) = shrine_troves.read(address, trove_id)
    let (charge_from, debt) = split_felt(trove_packed)
    let trove : Trove = Trove(charge_from=charge_from, debt=debt)
    return (trove)
end

@view
func get_gage{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(gage_address) -> (
    gage : Gage
):
    let (gage_id) = shrine_gage_id.read(gage_address)
    return shrine_gages.read(gage_id)
end

@view
func get_num_gages{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (ufelt):
    return shrine_num_gages.read()
end

@view
func get_deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    address, trove_id, gage_address
) -> (wad):
    let (gage_id) = shrine_gage_id.read(gage_address)
    return shrine_deposited.read(address, trove_id, gage_id)
end

@view
func get_synthetic{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (wad):
    return shrine_synthetic.read()
end

@view
func get_series{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_address, interval
) -> (wad):
    let (gage_id) = shrine_gage_id.read(gage_address)
    return shrine_series.read(gage_id, interval)
end

@view
func get_ceiling{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (wad):
    return shrine_ceiling.read()
end

@view
func get_multiplier{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    interval
) -> (ray):
    return shrine_multiplier.read(interval)
end

@view
func get_threshold{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (wad):
    return shrine_threshold.read()
end

@view
func get_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (bool):
    return shrine_live.read()
end

#
# Setters
#

@external
func add_gage{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(gage_address, max):
    assert_auth()

    let (gage_count) = shrine_num_gages.read()
    shrine_gage_id.write(gage_address, gage_count + 1)
    shrine_gages.write(gage_count + 1, Gage(0, max))
    GageAdded.emit(gage_address, gage_count + 1, max)

    shrine_num_gages.write(gage_count + 1)
    NumGagesUpdated.emit(gage_count + 1)

    return ()
end

@external
func update_gage_max{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_address, new_max
):
    assert_auth()

    let (gage_id) = shrine_gage_id.read(gage_address)
    let (gage : Gage) = shrine_gages.read(gage_id)
    shrine_gages.write(gage_id, Gage(gage.total, new_max))
    GageMaxUpdated.emit(gage_address, new_max)

    return ()
end

@external
func set_ceiling{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(new_ceiling):
    assert_auth()

    shrine_ceiling.write(new_ceiling)
    CeilingUpdated.emit(new_ceiling)
    return ()
end

# Threshold value should be a wad between 0 and 1
# Example: 75% = 75 : felt* 10 : felt** 16
# Example 2: 1% = 1 : felt* 10 : felt** 16
# Example 3: 1.5% = 15 : felt* 10 : felt** 15
@external
func set_threshold{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    new_threshold
):
    assert_auth()

    # Check that threshold value is not greater than max threshold
    with_attr error_message("Shrine: Threshold exceeds 100%"):
        assert_le(new_threshold, MAX_THRESHOLD)
    end

    shrine_threshold.write(new_threshold)
    ThresholdUpdated.emit(new_threshold)
    return ()
end

func set_trove{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, trove : Trove
):
    let (packed_trove) = pack_felt(trove.debt, trove.charge_from)
    shrine_troves.write(user_address, trove_id, packed_trove)
    return ()
end

@external
func kill{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    assert_auth()

    shrine_live.write(FALSE)
    Killed.emit()
    return ()
end

# Constructor
@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(authed):
    shrine_auth.write(authed, TRUE)
    shrine_live.write(TRUE)
    return ()
end

#
# Core functions - External
#

# Appends a new price to the Series of the specified Gage
@external
func advance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_address, price, timestamp
):
    assert_auth()
    let (gage_id) = shrine_gage_id.read(gage_address)
    let (interval, _) = unsigned_div_rem(timestamp, TIME_INTERVAL)
    shrine_series.write(gage_id, interval, price)

    SeriesIncremented.emit(gage_address, interval, price)
    return ()
end

# Appends a new multiplier value
@external
func update_multiplier{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    new_multiplier, timestamp
):
    assert_auth()

    let (interval, _) = unsigned_div_rem(timestamp, TIME_INTERVAL)

    shrine_multiplier.write(interval, new_multiplier)
    MultiplierUpdated.emit(new_multiplier, interval)
    return ()
end

# Move Gage between two Troves
# Checks should be performed beforehand by the module calling this function
@external
func move_gage{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_address, amount, src_address, src_trove_id, dst_address, dst_trove_id
):
    assert_auth()

    let (gage_id) = shrine_gage_id.read(gage_address)

    # Update gage balance of source trove
    let (src_gage_balance) = shrine_deposited.read(src_address, src_trove_id, gage_id)
    let (new_src_balance) = WadRay.sub_unsigned(src_gage_balance, amount)
    shrine_deposited.write(src_address, src_trove_id, gage_id, new_src_balance)

    # Update gage balance of destination trove
    let (dst_gage_balance) = shrine_deposited.read(dst_address, dst_trove_id, gage_id)
    let (new_dst_balance) = WadRay.add_unsigned(dst_gage_balance, amount)
    shrine_deposited.write(dst_address, dst_trove_id, gage_id, new_dst_balance)

    DepositUpdated.emit(src_address, src_trove_id, gage_address, new_src_balance)
    DepositUpdated.emit(dst_address, dst_trove_id, gage_address, new_dst_balance)

    return ()
end

# Deposit a specified amount of a Gage into a Trove
@external
func deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_address, amount, user_address, trove_id
):
    alloc_locals

    assert_auth()

    # Check system is live
    assert_system_live()

    # Charge interest
    charge(user_address, trove_id)

    # Update gage balance of system
    let (gage_id) = shrine_gage_id.read(gage_address)
    let (old_gage_info) = shrine_gages.read(gage_id)
    let (new_total) = WadRay.add(old_gage_info.total, amount)

    # Asserting that the deposit does not cause the total amount of gage deposited to exceed the max.
    assert_le(new_total, old_gage_info.max)

    let new_gage_info = Gage(total=new_total, max=old_gage_info.max)
    shrine_gages.write(gage_id, new_gage_info)

    # Update gage balance of trove
    let (trove_gage_balance) = shrine_deposited.read(user_address, trove_id, gage_id)
    let (new_trove_balance) = WadRay.add(trove_gage_balance, amount)
    shrine_deposited.write(user_address, trove_id, gage_id, new_trove_balance)

    GageTotalUpdated.emit(gage_address, new_total)
    DepositUpdated.emit(user_address, trove_id, gage_address, new_trove_balance)

    return ()
end

# Withdraw a specified amount of a Gage from a Trove
@external
func withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_address, amount, user_address, trove_id
):
    alloc_locals

    assert_auth()

    # Retrieve gage info
    let (gage_id) = shrine_gage_id.read(gage_address)
    let (old_gage_info) = shrine_gages.read(gage_id)

    # Asserting that gage is valid to align with `deposit` and prevent accounting errors.
    assert_not_zero(old_gage_info.max)

    # Charge interest
    charge(user_address, trove_id)

    # Update gage balance of system
    let (new_total) = WadRay.sub(old_gage_info.total, amount)
    let new_gage_info = Gage(total=new_total, max=old_gage_info.max)
    shrine_gages.write(gage_id, new_gage_info)

    # Update gage balance of trove
    let (trove_gage_balance) = shrine_deposited.read(user_address, trove_id, gage_id)
    let (new_trove_balance) = WadRay.sub(trove_gage_balance, amount)
    shrine_deposited.write(user_address, trove_id, gage_id, new_trove_balance)

    # Check if Trove is healthy
    let (healthy) = is_healthy(user_address, trove_id)

    with_attr error_message("Shrine: Trove is at risk after withdrawing gage"):
        assert healthy = TRUE
    end

    GageTotalUpdated.emit(gage_address, new_total)
    DepositUpdated.emit(user_address, trove_id, gage_address, new_trove_balance)
    return ()
end

# Mint a specified amount of synthetic for a Trove
@external
func forge{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, amount
):
    alloc_locals

    assert_auth()

    # Check system is live
    assert_system_live()

    # Get current Trove information
    let (old_trove_info : Trove) = get_trove(user_address, trove_id)

    # Get current interval
    let (current_interval) = now()

    # Get updated debt amount with interest
    let (old_trove_debt_compounded) = estimate_inner(
        user_address, trove_id, old_trove_info, current_interval
    )

    # Get interest charged
    let (diff) = WadRay.sub_unsigned(old_trove_debt_compounded, old_trove_info.debt)

    # Check that debt ceiling has not been reached
    let (current_system_debt) = shrine_synthetic.read()
    let new_system_debt = current_system_debt + diff + amount
    let (debt_ceiling) = shrine_ceiling.read()

    with_attr error_message("Shrine: Debt ceiling reached"):
        assert_le(new_system_debt, debt_ceiling)
    end

    # Update system debt
    shrine_synthetic.write(new_system_debt)

    # Initialise `Trove.charge_from` to current interval if old debt was 0.
    # Otherwise, set `Trove.charge_from` to current interval + 1 because interest has been
    # charged up to current interval.
    if old_trove_info.debt == 0:
        tempvar new_charge_from = current_interval
    else:
        tempvar new_charge_from = current_interval + 1
    end

    # Update trove information
    let (new_debt) = WadRay.add(old_trove_debt_compounded, amount)
    let new_trove_info : Trove = Trove(charge_from=new_charge_from, debt=new_debt)
    set_trove(user_address, trove_id, new_trove_info)

    # Check if Trove is healthy
    let (healthy) = is_healthy(user_address, trove_id)

    with_attr error_message("Shrine: Trove is at risk after forge"):
        assert healthy = TRUE
    end

    # Events

    SyntheticTotalUpdated.emit(new_system_debt)
    TroveUpdated.emit(user_address, trove_id, new_trove_info)

    return ()
end

# Repay a specified amount of synthetic for a Trove
# The module calling this function should check that `amount` does not exceed Trove's debt.
@external
func melt{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, amount
):
    alloc_locals

    assert_auth()

    # Get current Trove information
    let (old_trove_info : Trove) = get_trove(user_address, trove_id)

    # Get current interval
    let (current_interval) = now()

    # Get updated debt amount with interest
    let (old_trove_debt_compounded) = estimate_inner(
        user_address, trove_id, old_trove_info, current_interval
    )

    # Get interest charged
    let (diff) = WadRay.sub_unsigned(old_trove_debt_compounded, old_trove_info.debt)

    # Update system debt
    let (current_system_debt) = shrine_synthetic.read()
    let new_system_debt = current_system_debt + diff - amount
    shrine_synthetic.write(new_system_debt)

    # Update trove information
    let (new_debt) = WadRay.sub(old_trove_debt_compounded, amount)
    let new_trove_info : Trove = Trove(charge_from=current_interval + 1, debt=new_debt)
    set_trove(user_address, trove_id, new_trove_info)

    # Events

    SyntheticTotalUpdated.emit(new_system_debt)
    TroveUpdated.emit(user_address, trove_id, new_trove_info)

    return ()
end

# Seize a Trove for liquidation by transferring the debt and gage to the appropriate module
# Checks should be performed beforehand by the module calling this function
@external
func seize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id
):
    assert_auth()

    # Update Trove information
    let (old_trove_info : Trove) = get_trove(user_address, trove_id)
    let new_trove_info : Trove = Trove(charge_from=old_trove_info.charge_from, debt=0)

    # TODO Transfer outstanding debt (old_trove_info.debt) to the appropriate module

    # TODO Iterate over gages and transfer balance to the appropriate module

    # TODO Events?

    return ()
end

#
# Core Functions - View
#

# Calculate a Trove's current loan-to-value ratio
# returns a ray
@view
func trove_ratio_current{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id
) -> (ray):
    alloc_locals
    let (trove : Trove) = get_trove(user_address, trove_id)
    let (interval) = now()
    return trove_ratio(user_address, trove_id, interval, trove.debt)
end

# Calculate a Trove's health
@view
func is_healthy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id
) -> (bool):
    alloc_locals

    # Get value of the trove's debt
    let (trove : Trove) = get_trove(user_address, trove_id)

    # Early termination if no debt
    if trove.debt == 0:
        return (TRUE)
    end

    # Get threshold
    let (t) = shrine_threshold.read()

    # value : felt* liquidation threshold = amount of debt the trove can have without being at risk of liquidation.
    let (value) = appraise(user_address, trove_id)

    # if the amount of debt the trove has is greater than this, the trove is not healthy.
    let (trove_threshold) = WadRay.wmul(value, t)

    let (healthy) = is_le(trove.debt, trove_threshold)
    return (bool=healthy)
end

# Get the last updated price for a Gage
@view
func gage_last_price{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_address
) -> (wad):
    alloc_locals

    let (gage_id) = shrine_gage_id.read(gage_address)
    let (interval) = now()  # Get current interval
    return get_recent_price_from(gage_id, interval)
end

# Gets last updated multiplier value
@view
func get_multiplier_recent{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    ray
):
    let (interval) = now()
    let (m) = get_recent_multiplier_from(interval)
    return (m)
end

# Returns the debt a trove owes, including any interest that has accumulated since
# `Trove.charge_from` but not accrued to `Trove.debt` yet.
@view
func estimate{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id
) -> (wad):
    alloc_locals

    let (trove : Trove) = get_trove(user_address, trove_id)
    let (current_interval) = now()
    return estimate_inner(user_address, trove_id, trove, current_interval)
end

#
# Internal
#

func assert_system_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    # Check system is live
    let (live) = shrine_live.read()
    with_attr error_message("Shrine: System is not live"):
        assert live = TRUE
    end
    return ()
end

# Wrapper function for the recursive `appraise_inner` function that gets the most recent trove value
func appraise{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id
) -> (wad):
    alloc_locals

    let (gage_count) = shrine_num_gages.read()
    let (interval) = now()
    let (value) = appraise_inner(user_address, trove_id, gage_count, interval, 0)
    return (value)
end

func now{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (ufelt):
    let (time) = get_block_timestamp()
    let (interval, _) = unsigned_div_rem(time, TIME_INTERVAL)
    return (interval)
end

# Adds the accumulated interest as debt to the trove
func charge{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id
):
    alloc_locals

    # Get trove info
    let (trove : Trove) = get_trove(user_address, trove_id)

    # Get current interval
    let (current_interval) = now()

    # Get new debt amount
    let (new_debt) = estimate_inner(user_address, trove_id, trove, current_interval)

    # Update Trove
    let updated_trove : Trove = Trove(charge_from=current_interval + 1, debt=new_debt)
    set_trove(user_address, trove_id, updated_trove)

    # Get old system debt amount
    let (old_system_debt) = shrine_synthetic.read()

    # Get interest charged
    let (diff) = WadRay.sub_unsigned(new_debt, trove.debt)

    # Get new system debt
    let new_system_debt = old_system_debt + diff
    shrine_synthetic.write(new_system_debt)

    SyntheticTotalUpdated.emit(new_system_debt)
    TroveUpdated.emit(user_address, trove_id, updated_trove)

    return ()
end

# Wrapper function to make a call to `compound` for estimating accumulated interest.
func estimate_inner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, trove : Trove, current
) -> (wad):
    alloc_locals

    # Early termination if no debt
    if trove.debt == 0:
        return (trove.debt)
    end

    # Early termination if `start` is next interval of `current`,
    # meaning interest has been charged up to current interval.
    let (is_updated) = is_le(current + 1, trove.charge_from)
    if is_updated == TRUE:
        return (trove.debt)
    end

    # Get new debt amount
    return compound(user_address, trove_id, trove.charge_from, current + 1, trove.debt)
end

# Inner function for calculating accumulated interest.
# Recursively iterates over time intervals from `current_interval` to `final_interval` and compounds the interest owed over all of them
func compound{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, current_interval, final_interval, debt
) -> (wad):
    alloc_locals

    # Terminate if final_interval <= current_interval
    let (finished) = is_le(final_interval, current_interval)
    if finished == TRUE:
        return (debt)
    end

    # Get LTV for Trove at the given time ID
    let (ratio) = trove_ratio(user_address, trove_id, current_interval, debt)

    # Get base rate using LTV
    let (rate) = base_rate(ratio)

    # Get multiplier at the given time ID
    let (m) = get_recent_multiplier_from(current_interval)

    # Derive the interest rate
    let (real_rate) = WadRay.rmul_unchecked(rate, m)

    # Derive the real interest rate to be charged
    let (percent_owed) = WadRay.rmul_unchecked(real_rate, TIME_INTERVAL_DIV_YEAR)

    # Compound the debt
    let (amount_owed) = WadRay.rmul(debt, percent_owed)  # Returns a wad
    let (new_debt) = WadRay.add(debt, amount_owed)

    # Recursive call
    return compound(user_address, trove_id, current_interval + 1, final_interval, new_debt)
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

# Calculates the trove's LTV at the given interval.
# See comments above `appraise_inner` for the underlying assumption on which the correctness of the result depends.
# Another assumption here is that if trove debt is non-zero, then there is collateral in the trove
# Returns a ray.
func trove_ratio{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, interval, debt
) -> (ray):
    # Early termination if no debt
    if debt == 0:
        return (0)
    end

    let (gage_count) = shrine_num_gages.read()
    let (value) = appraise_inner(user_address, trove_id, gage_count, interval, 0)

    let (ratio) = WadRay.wunsigned_div(debt, value)
    let (ratio_ray) = WadRay.wad_to_ray_unchecked(ratio)  # Can be unchecked since `ratio` should always be between 0 and 1 (scaled by 10**18)
    return (ratio_ray)
end

# Gets the value of a trove at the gage prices at the given interval.
# For any series that returns 0 for the given interval, it uses the most recent available price before that interval.
# This function uses historical prices but the currently deposited gage amounts to calculate value.
# The underlying assumption is that the amount of each gage deposited remains the same throughout the recursive call.
func appraise_inner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, gage_id, interval, cumulative
) -> (wad):
    alloc_locals

    # Terminate when Gage ID reaches 0
    if gage_id == 0:
        return (cumulative)
    end

    # Calculate current gage value
    let (balance) = shrine_deposited.read(user_address, trove_id, gage_id)
    let (price) = get_recent_price_from(gage_id, interval)
    assert_not_zero(price)  # Reverts if price is zero
    let (value) = WadRay.wmul_unchecked(balance, price)

    # Update cumulative value
    let (updated_cumulative) = WadRay.add_unsigned(cumulative, value)

    # Recursive call
    return appraise_inner(
        user_address=user_address,
        trove_id=trove_id,
        gage_id=gage_id - 1,
        interval=interval,
        cumulative=updated_cumulative,
    )
end

# Returns the price for `gage_id` at `interval` if it is non-zero.
# Otherwise, check `interval` - 1 recursively for the last available price.
func get_recent_price_from{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id, interval
) -> (wad):
    let (price) = shrine_series.read(gage_id, interval)

    if price != 0:
        return (price)
    end

    return get_recent_price_from(gage_id, interval - 1)
end

# Returns the multiplier at `interval` if it is non-zero.
# Otherwise, check `interval` - 1 recursively for the last available value.
func get_recent_multiplier_from{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    interval
) -> (ray):
    let (m) = shrine_multiplier.read(interval)

    if m != 0:
        return (ray=m)
    end

    return get_recent_multiplier_from(interval - 1)
end
