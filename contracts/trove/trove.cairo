%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero, assert_le
from starkware.starknet.common.syscalls import get_caller_address

from contracts.shared.types import Trove, Gage, Point
from contracts.shared.wad_ray import WadRay

#
# Constants
#

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
func GageSafetyUpdated(gage_id : felt, new_safety : felt):
end

@event
func SyntheticTotalUpdated(new_total : felt):
end

@event
func NumGagesUpdated(num : felt):
end

@event
func MultiplierUpdated(new_multiplier : felt):
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
func SeriesIncremented(gage_id : felt, new_len : felt, new_point : Point):
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

func authorize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address : felt):
    assert_auth()
    auth.write(address, TRUE)
    Authorized.emit(address)
    return ()
end

func revoke{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address : felt):
    assert_auth()
    auth.write(address, FALSE)
    Revoked.emit(address)
    return ()
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

# Keeps track of the price history of each Gage - ray
@storage_var
func series(gage_id : felt, index : felt) -> (point : Point):
end

@storage_var
func series_len(gage_id : felt) -> (len : felt):
end

# Total debt ceiling - wad
@storage_var
func ceiling() -> (ceiling : felt):
end

# Global interest rate multiplier - ray
@storage_var
func multiplier() -> (rate : felt):
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

func get_troves{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    address : felt, trove_id : felt
) -> (trove : Trove):
    return troves.read(address, trove_id)
end

func get_gages{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id : felt
) -> (gage : Gage):
    return gages.read(gage_id)
end

func get_num_gages{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    num : felt
):
    return num_gages.read()
end

func get_deposits{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    address : felt, trove_id : felt, gage_id : felt
) -> (amount : felt):
    return deposited.read(address, trove_id, gage_id)
end

func get_synthetic{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    amount : felt
):
    return synthetic.read()
end

func get_series{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id, index
) -> (point : Point):
    return series.read(gage_id, index)
end

func get_series_len{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id : felt
) -> (len : felt):
    return series_len.read(gage_id)
end

func get_ceiling{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    ceiling : felt
):
    return ceiling.read()
end

func get_multiplier{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    multiplier : felt
):
    return multiplier.read()
end

func get_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (tax : felt):
    return tax.read()
end

func get_is_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    is_live : felt
):
    return is_live.read()
end

#
# Setters - Basic setters with no additional logic besides an auth-check and event emission
#

func set_gages{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id : felt, gage : Gage
):
    assert_auth()

    gages.write(gage_id, gage)
    return ()
end

func set_num_gages{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(num : felt):
    assert_auth()

    num_gages.write(num)
    NumGagesUpdated.emit(num)
    return ()
end

func set_ceiling{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    new_ceiling : felt
):
    assert_auth()

    ceiling.write(new_ceiling)
    CeilingUpdated.emit(new_ceiling)
    return ()
end

func set_multiplier{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    new_multiplier : felt
):
    assert_auth()

    multiplier.write(new_multiplier)
    MultiplierUpdated.emit(new_multiplier)
    return ()
end

func set_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(new_tax : felt):
    assert_auth()

    tax.write(new_tax)
    TaxUpdated.emit(new_tax)
    return ()
end

func kill{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    assert_auth()

    is_live.write(FALSE)
    Killed.emit()
    return ()
end

# Constructor
@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    let (c) = get_caller_address()

    auth.write(c, TRUE)
    is_live.write(TRUE)
    return ()
end

#
# Core functions
#

# Appends a new point to the Series of the specified Gage
func advance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id : felt, point : Point
):
    assert_auth()

    let (current_len) = series_len.read(gage_id)
    series.write(gage_id, current_len, point)
    series_len.write(gage_id, current_len + 1)

    SeriesIncremented.emit(gage_id, current_len + 1, point)
    return ()
end

# Move Gage between two Troves
# Checks should be performed beforehand by the module calling this function
func move_gage{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id : felt,
    gage_amount : felt,
    src_address : felt,
    src_trove_id : felt,
    dst_address : felt,
    dst_trove_id : felt,
):
    assert_auth()

    # Update gage balance of source trove
    let (src_gage_balance) = deposited.read(src_address, src_trove_id, gage_id)
    let (new_src_balance) = WadRay.sub_unsigned(src_gage_balance, gage_amount)
    deposited.write(src_address, src_trove_id, gage_id, new_src_balance)

    # Update gage balance of destination trove
    let (dst_gage_balance) = deposited.read(dst_address, dst_trove_id, gage_id)
    let (new_dst_balance) = WadRay.add_unsigned(dst_gage_balance, gage_amount)
    deposited.write(dst_address, dst_trove_id, gage_id, new_dst_balance)

    DepositUpdated.emit(src_address, src_trove_id, gage_id, new_src_balance)
    DepositUpdated.emit(dst_address, dst_trove_id, gage_id, new_dst_balance)

    return ()
end

# Deposit a specified amount of a Gage into a Trove
func deposit_gage{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id : felt, gage_amount : felt, user_address : felt, trove_id : felt
):
    assert_auth()

    # Check system is live
    let (live) = is_live.read()
    with_attr error_message("Trove: System is not live"):
        assert live = TRUE
    end

    # Update gage balance of system
    let (old_gage_info) = get_gages(gage_id)
    let (new_total) = WadRay.add(old_gage_info.total, gage_amount)
    let new_gage_info = Gage(total=new_total, safety=old_gage_info.safety)
    gages.write(gage_id, new_gage_info)

    # Update gage balance of trove
    let (trove_gage_balance) = deposited.read(user_address, trove_id, gage_id)
    let (new_trove_balance) = WadRay.add(trove_gage_balance, gage_amount)
    deposited.write(user_address, trove_id, gage_id, new_trove_balance)

    GageTotalUpdated.emit(gage_id, new_total)
    DepositUpdated.emit(user_address, trove_id, gage_id, new_trove_balance)

    return ()
end

# Withdraw a specified amount of a Gage from a Trove
func withdraw_gage{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    gage_id : felt, gage_amount : felt, user_address : felt, trove_id : felt
):
    assert_auth()

    # Check system is live
    let (live) = is_live.read()
    with_attr error_message("Trove: System is not live"):
        assert live = TRUE
    end

    # TODO Check for safety of Trove
    # Calculate the updated sum of (Gage balance * Gage safety price) for all Gages
    # Assert that debt is lower than this sum

    # Update gage balance of system
    let (old_gage_info) = get_gages(gage_id)
    let (new_total) = WadRay.sub(old_gage_info.total, gage_amount)
    let new_gage_info = Gage(total=new_total, safety=old_gage_info.safety)
    gages.write(gage_id, new_gage_info)

    # Update gage balance of trove
    let (trove_gage_balance) = deposited.read(user_address, trove_id, gage_id)
    let (new_trove_balance) = WadRay.sub(trove_gage_balance, gage_amount)
    deposited.write(user_address, trove_id, gage_id, new_trove_balance)

    GageTotalUpdated.emit(gage_id, new_total)
    DepositUpdated.emit(user_address, trove_id, gage_id, new_trove_balance)
    return ()
end

# Mint a specified amount of synthetic for a Trove
func mint_synthetic{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address : felt, trove_id : felt, mint_amount : felt
):
    assert_auth()

    # Check system is live
    let (live) = is_live.read()
    with_attr error_message("Trove: System is not live"):
        assert live = TRUE
    end

    # Check that debt ceiling has not been reached
    let (current_system_debt) = synthetic.read()
    let new_system_debt = current_system_debt + mint_amount
    let (debt_ceiling) = ceiling.read()

    with_attr error_message("Trove: Debt ceiling reached"):
        assert_le(new_system_debt, debt_ceiling)
    end

    # Update system debt
    synthetic.write(new_system_debt)

    # TODO Check for safety of Trove
    # Calculate the sum of (Gage balance * Gage safety price) for all Gages
    # Assert that new debt is lower than this sum

    # Get current Trove information
    let (old_trove_info) = get_troves(user_address, trove_id)
    let (new_debt) = WadRay.add(old_trove_info.debt, mint_amount)
    let new_trove_info = Trove(last=old_trove_info.last, debt=new_debt)
    troves.write(user_address, trove_id, new_trove_info)

    # TODO Transfer the synthetic to the user address

    # Events

    SyntheticTotalUpdated.emit(new_system_debt)
    TroveUpdated.emit(user_address, trove_id, new_trove_info)

    return ()
end

# Repay a specified amount of synthetic for a Trove
# The module calling this function should check that `repay_amount` does not exceed Trove's debt.
func repay_synthetic{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address : felt, trove_id : felt, repay_amount : felt
):
    assert_auth()

    # Check system is live
    let (live) = is_live.read()
    with_attr error_message("Trove: System is not live"):
        assert live = TRUE
    end

    # Update system debt
    let (current_system_debt) = synthetic.read()
    let new_system_debt = current_system_debt - repay_amount
    synthetic.write(new_system_debt)

    # Update trove information
    let (old_trove_info) = get_troves(user_address, trove_id)
    let (new_debt) = WadRay.sub(old_trove_info.debt, repay_amount)
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
func seize_trove{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address : felt, trove_id : felt
):
    assert_auth()

    # Update Trove information
    let (old_trove_info) = get_troves(user_address, trove_id)
    let new_trove_info = Trove(last=old_trove_info.last, debt=0)

    # TODO Transfer outstanding debt (old_trove_info.debt) to the appropriate module

    # TODO Iterate over gages and transfer balance to the appropriate module

    return ()
end
