%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero, assert_le, unsigned_div_rem
from starkware.cairo.common.math_cmp import is_le
from starkware.starknet.common.syscalls import get_caller_address, get_block_timestamp

from contracts.shared.types import Trove, Gage, Point
from contracts.shared.wad_ray import WadRay

#
# Constants
#

const MAX_THRESHOLD = WadRay.WAD_ONE

const SECONDS_PER_MINUTE = 60

const TIME_ID_INTERVAL = 30 * SECONDS_PER_MINUTE

#
# Events
#

@event
func Authorized(address : felt):
end

@event
func Revoked(address : felt):
end

@event
func GageTotalUpdated(gage_id : felt, new_total : felt):
end

@event
func GageMaxUpdated(gage_id : felt, new_max : felt):
end

@event
func GageSafetyUpdated(gage_id : felt, new_safety : felt):
end

@event
func SyntheticTotalUpdated(new_total : felt):
end

@event
func NumGagesUpdated(num : felt):
end

@event
func MultiplierUpdated(new_multiplier : felt, time_id : felt):
end

@event
func ThresholdUpdated(new_threshold : felt):
end

@event
func TaxUpdated(new_tax : felt):
end

@event
func TroveUpdated(address : felt, trove_id : felt, updated_trove : Trove):
end

@event
func DepositUpdated(address : felt, trove_id : felt, gage_id : felt, new_amount : felt):
end

@event
func SeriesIncremented(gage_id : felt, time_id : felt, price : felt):
end

@event
func CeilingUpdated(ceiling : felt):
end

@event
func Killed():
end

#
# Auth
#

@storage_var
func auth(address : felt) -> (authorized : felt):
end

# Similar to onlyOwner
func assert_auth{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    let (c) = get_caller_address()
    let (is_authed) = auth.read(c)
    assert is_authed = TRUE
    return ()
end

@external
func authorize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address : felt):
    assert_auth()
    auth.write(address, TRUE)
    Authorized.emit(address)
    return ()
end

@external
func revoke{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address : felt):
    assert_auth()
    auth.write(address, FALSE)
    Revoked.emit(address)
    return ()
end

@view
func get_auth{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    address : felt
) -> (is_auth : felt):
    return auth.read(address)
end

#
# Storage
#

# Also known as CDPs, sub-accounts, etc. Each user has multiple troves that they can deposit collateral into and mint synthetic against.
@storage_var
func troves(address : felt, trove_id : felt) -> (trove : Trove):
end

# Stores information about each gage (see Gage struct)
@storage_var
func gages(gage_id : felt) -> (gage : Gage):
end

@storage_var
func num_gages() -> (num : felt):
end

# Keeps track of how much of each gage has been deposited into each Trove - wad
@storage_var
func deposited(address : felt, trove_id : felt, gage_id : felt) -> (amount : felt):
end

# Total amount of synthetic minted
@storage_var
func synthetic() -> (total : felt):
end

# Keeps track of the price history of each Gage - wad
# time_id: timestamp of the price integer-divided by TIME_ID_INTERVAL. 
@storage_var
func series(gage_id : felt, time_id : felt) -> (price : felt):
end

@storage_var
func series_last_time_id(gage_id : felt) -> (time_id : felt):
end

# Total debt ceiling - wad
@storage_var
func ceiling() -> (ceiling : felt):
end

# Global interest rate multiplier - ray
@storage_var
func multiplier(time_id : felt) -> (rate : felt):
end

@storage_var 
func multiplier_last_time_id() -> (time_id : felt):
end

# Liquidation threshold (or max LTV) - wad
@storage_var
func threshold() -> (threshold : felt):
end

# Fee on yield - ray
@storage_var
func tax() -> (admin_fee : felt):
end

@storage_var
func is_live() -> (is_live : felt):
end

#
# Getters
#

@view
func get_troves{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    address : felt, trove_id : felt
) -> (trove : Trove):
    return troves.read(address, trove_id)
end

@view
func get_gages{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id : felt
) -> (gage : Gage):
    return gages.read(gage_id)
end

@view
func get_num_gages{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    num : felt
):
    return num_gages.read()
end

@view
func get_deposits{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    address : felt, trove_id : felt, gage_id : felt
) -> (amount : felt):
    return deposited.read(address, trove_id, gage_id)
end

@view
func get_synthetic{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    amount : felt
):
    return synthetic.read()
end

@view
func get_series{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id : felt, time_id : felt
) -> (price : felt):
    return series.read(gage_id, time_id)
end

@view
func get_series_last_time_id{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id : felt
) -> (time_id : felt):
    return series_last_time_id.read(gage_id)
end

@view
func get_ceiling{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    ceiling : felt
):
    return ceiling.read()
end

@view
func get_multiplier{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(time_id : felt) -> (multiplier : felt):
    return multiplier.read(time_id)
end

@view
func get_multiplier_last_time_id{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (time_id : felt):
    return multiplier_last_time_id.read()
end

@view
func get_threshold{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    threshold : felt
):
    return threshold.read()
end

@view
func get_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (tax : felt):
    return tax.read()
end

@view
func get_is_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    is_live : felt
):
    return is_live.read()
end

#
# Setters
#

@external
func add_gage{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(max : felt):
    assert_auth()

    let (gage_count : felt) = num_gages.read()
    gages.write(gage_count, Gage(0, max))
    num_gages.write(gage_count + 1)
    return ()
end

@external
func update_gage_max{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id : felt, new_max : felt
):
    assert_auth()

    let (gage : Gage) = gages.read(gage_id)
    gages.write(gage_id, Gage(gage.total, new_max))
    return ()
end

@external
func set_ceiling{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    new_ceiling : felt
):
    assert_auth()

    ceiling.write(new_ceiling)
    CeilingUpdated.emit(new_ceiling)
    return ()
end

@external
func update_multiplier{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    new_multiplier : felt
):
    assert_auth()

    let (time_id) = get_block_time_id()

    multiplier.write(time_id, new_multiplier)
    multiplier_last_time_id.write(time_id)
    MultiplierUpdated.emit(new_multiplier, time_id)
    return ()
end

# Threshold value should be a wad between 0 and 1
# Example: 75% = 75 * 10 ** 16
# Example 2: 1% = 1 * 10 ** 16
# Example 3: 1.5% = 15 * 10 ** 15
@external
func set_threshold{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    new_threshold : felt
):
    assert_auth()

    # Check that threshold value is not greater than max threshold
    with_attr error_message("Trove: Threshold exceeds 100%"):
        assert_le(new_threshold, MAX_THRESHOLD)
    end

    threshold.write(new_threshold)
    ThresholdUpdated.emit(new_threshold)
    return ()
end

@external
func set_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(new_tax : felt):
    assert_auth()

    tax.write(new_tax)
    TaxUpdated.emit(new_tax)
    return ()
end

@external
func kill{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    assert_auth()

    is_live.write(FALSE)
    Killed.emit()
    return ()
end

# Constructor
@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(authed : felt):
    auth.write(authed, TRUE)
    is_live.write(TRUE)
    return ()
end

#
# Core functions
#

# Appends a new point to the Series of the specified Gage
@external
func advance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id : felt, price : felt
):
    assert_auth()

    let (time_id) = get_block_time_id()
    series.write(gage_id, time_id, price)

    # TO DO: check if gas-optimization can be made here by checking if the current time_id is the same as the last one before writing.
    series_last_time_id.write(gage_id, time_id)

    SeriesIncremented.emit(gage_id, time_id, price)
    return ()
end

# Move Gage between two Troves
# Checks should be performed beforehand by the module calling this function
@external
func move_gage{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id : felt,
    amount : felt,
    src_address : felt,
    src_trove_id : felt,
    dst_address : felt,
    dst_trove_id : felt,
):
    assert_auth()

    # Update gage balance of source trove
    let (src_gage_balance) = deposited.read(src_address, src_trove_id, gage_id)
    let (new_src_balance) = WadRay.sub_unsigned(src_gage_balance, amount)
    deposited.write(src_address, src_trove_id, gage_id, new_src_balance)

    # Update gage balance of destination trove
    let (dst_gage_balance) = deposited.read(dst_address, dst_trove_id, gage_id)
    let (new_dst_balance) = WadRay.add_unsigned(dst_gage_balance, amount)
    deposited.write(dst_address, dst_trove_id, gage_id, new_dst_balance)

    DepositUpdated.emit(src_address, src_trove_id, gage_id, new_src_balance)
    DepositUpdated.emit(dst_address, dst_trove_id, gage_id, new_dst_balance)

    return ()
end

# Deposit a specified amount of a Gage into a Trove
@external
func deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id : felt, amount : felt, user_address : felt, trove_id : felt
):
    assert_auth()

    # Check system is live
    assert_system_live()

    # Update gage balance of system
    let (old_gage_info) = get_gages(gage_id)
    let (new_total) = WadRay.add(old_gage_info.total, amount)
    let new_gage_info = Gage(total=new_total, max=old_gage_info.max)
    gages.write(gage_id, new_gage_info)

    # Update gage balance of trove
    let (trove_gage_balance) = deposited.read(user_address, trove_id, gage_id)
    let (new_trove_balance) = WadRay.add(trove_gage_balance, amount)
    deposited.write(user_address, trove_id, gage_id, new_trove_balance)

    GageTotalUpdated.emit(gage_id, new_total)
    DepositUpdated.emit(user_address, trove_id, gage_id, new_trove_balance)

    return ()
end

# Withdraw a specified amount of a Gage from a Trove
@external
func withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id : felt, amount : felt, user_address : felt, trove_id : felt
):
    alloc_locals

    assert_auth()

    # Update gage balance of system
    let (old_gage_info) = get_gages(gage_id)
    let (new_total) = WadRay.sub(old_gage_info.total, amount)
    let new_gage_info = Gage(total=new_total, max=old_gage_info.max)
    gages.write(gage_id, new_gage_info)

    # Update gage balance of trove
    let (trove_gage_balance) = deposited.read(user_address, trove_id, gage_id)
    let (new_trove_balance) = WadRay.sub(trove_gage_balance, amount)
    deposited.write(user_address, trove_id, gage_id, new_trove_balance)

    # Check if Trove is healthy
    let (healthy) = is_healthy(user_address, trove_id)

    with_attr error_message("Trove: Trove is at risk after gage withdrawal"):
        assert healthy = TRUE
    end

    GageTotalUpdated.emit(gage_id, new_total)
    DepositUpdated.emit(user_address, trove_id, gage_id, new_trove_balance)
    return ()
end

# Mint a specified amount of synthetic for a Trove
@external
func forge{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address : felt, trove_id : felt, amount : felt
):
    alloc_locals

    assert_auth()

    # Check system is live
    assert_system_live()

    # Check that debt ceiling has not been reached
    let (current_system_debt) = synthetic.read()
    let new_system_debt = current_system_debt + amount
    let (debt_ceiling) = ceiling.read()

    with_attr error_message("Trove: Debt ceiling reached"):
        assert_le(new_system_debt, debt_ceiling)
    end

    # Update system debt
    synthetic.write(new_system_debt)

    # Get current Trove information
    let (old_trove_info) = get_troves(user_address, trove_id)
    let (new_debt) = WadRay.add(old_trove_info.debt, amount)
    let new_trove_info = Trove(last=old_trove_info.last, debt=new_debt)
    troves.write(user_address, trove_id, new_trove_info)

    # Check if Trove is healthy
    let (healthy) = is_healthy(user_address, trove_id)

    with_attr error_message("Trove: Trove is at risk after gage withdrawal"):
        assert healthy = TRUE
    end

    # TODO Transfer the synthetic to the user address

    # Events

    SyntheticTotalUpdated.emit(new_system_debt)
    TroveUpdated.emit(user_address, trove_id, new_trove_info)

    return ()
end

# Repay a specified amount of synthetic for a Trove
# The module calling this function should check that `amount` does not exceed Trove's debt.
@external
func melt{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address : felt, trove_id : felt, amount : felt
):
    assert_auth()

    # Update system debt
    let (current_system_debt) = synthetic.read()
    let new_system_debt = current_system_debt - amount
    synthetic.write(new_system_debt)

    # Update trove information
    let (old_trove_info) = get_troves(user_address, trove_id)
    let (new_debt) = WadRay.sub(old_trove_info.debt, amount)
    let new_trove_info = Trove(last=old_trove_info.last, debt=new_debt)
    troves.write(user_address, trove_id, new_trove_info)

    # TODO Transfer the synthetic from the user address

    # Events

    SyntheticTotalUpdated.emit(new_system_debt)
    TroveUpdated.emit(user_address, trove_id, new_trove_info)

    return ()
end

# Seize a Trove for liquidation by transferring the debt and gage to the appropriate module
# Checks should be performed beforehand by the module calling this function
@external
func seize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address : felt, trove_id : felt
):
    assert_auth()

    # Update Trove information
    let (old_trove_info) = get_troves(user_address, trove_id)
    let new_trove_info = Trove(last=old_trove_info.last, debt=0)

    # TODO Transfer outstanding debt (old_trove_info.debt) to the appropriate module

    # TODO Iterate over gages and transfer balance to the appropriate module

    # TODO Events?

    return ()
end

#
# Internal
#

func assert_system_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    # Check system is live
    let (live) = is_live.read()
    with_attr error_message("Trove: System is not live"):
        assert live = TRUE
    end
    return ()
end

# Get the last updated price for a Gage
@view
func gage_last_price{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id : felt
) -> (price : felt):
    let (time_id) = series_last_time_id.read(gage_id)
    let (p) = series.read(gage_id, time_id)
    return (p)
end

# Gets last updated multiplier value
@view
func get_multiplier_recent{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    multiplier : felt
):
    let (time_id) = multiplier_last_time_id.read()
    return multiplier.read(time_id)
end

# Calculate a Trove's loan-to-value ratio, scaled by one wad (10 ** 18).
@view
func trove_ratio{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address : felt, trove_id : felt
) -> (ratio : felt):
    alloc_locals

    # Get value of the trove's debt
    let (trove) = troves.read(user_address, trove_id)
    let debt = trove.debt

    # Early termination if no debt
    if debt == 0:
        return (0)
    end

    # Get scaled total value of trove's gages
    let (trove_val) = appraise(user_address, trove_id)
    let (trove_val_scaled) = WadRay.wmul(trove_val, WadRay.WAD_SCALE)

    # Get scaled value of trove's debt
    let (debt_scaled) = WadRay.wmul(debt, WadRay.WAD_SCALE)

    # Calculate loan-to-value ratio
    let (ratio) = WadRay.unsigned_div(debt_scaled, trove_val_scaled)

    # Return ratio scaled by wad (10 ** 18)
    return (ratio)
end

# Calculate a Trove's health
@view
func is_healthy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address : felt, trove_id : felt
) -> (healthy : felt):
    alloc_locals

    # Get value of the trove's debt
    let (trove) = troves.read(user_address, trove_id)
    let debt = trove.debt

    # Early termination if no debt
    if debt == 0:
        return (TRUE)
    end

    # Get threshold
    let (t) = threshold.read()

    # value * liquidation threshold = amount of debt the trove can have without being at risk of liquidation.
    let (value) = appraise(user_address, trove_id)

    # if the amount of debt the trove has is greater than this, the trove is not healthy.
    let (trove_threshold) = WadRay.wmul(value, t)

    let (healthy) = is_le(debt, trove_threshold)
    return (healthy)
end

# Wrapper function for the recursive `appraise_inner` function
func appraise{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address : felt, trove_id : felt
) -> (value : felt):
    let (gage_count) = num_gages.read()
    return appraise_inner(user_address, trove_id, gage_count - 1, 0)
end

# Calculate a trove's gage value based on the sum of (Gage balance * Gage safety price) for all Gages
# in descending order of Gage ID starting from `num_gages - 1`
func appraise_inner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address : felt, trove_id : felt, gage_id : felt, cumulative : felt
) -> (new_cumulative : felt):
    # Calculate current gage value
    let (balance) = deposited.read(user_address, trove_id, gage_id)

    # Getting the most recent price in the gage's series
    let (price) = gage_last_price(gage_id)

    let (value) = WadRay.wmul_unchecked(balance, price)

    # Update cumulative value
    let (updated_cumulative) = WadRay.add_unsigned(cumulative, value)

    # Terminate when Gage ID reaches 0
    if gage_id == 0:
        return (updated_cumulative)
    else:
        # Recursive call
        return appraise_inner(
            user_address=user_address,
            trove_id=trove_id,
            gage_id=gage_id - 1,
            cumulative=updated_cumulative,
        )
    end
end

func get_block_time_id{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (time_id : felt):
    let (time) = get_block_timestamp()
    let (time_id, _) = unsigned_div_rem(time, TIME_ID_INTERVAL)
    return (time_id)
end


# Calculate a trove's accumulated interest since the last time its accumulated interest was calculated
# Additional check should be done by calling contract to ensure the starting `price_history_index` is correct
#func calc_accumulated_interest_inner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
#    user_address : felt, 
#    trove_id : felt, 
#    price_history_index : felt, 
#    cumulative : felt, 
#) -> (new_cumulative : felt):
#
#
#end
