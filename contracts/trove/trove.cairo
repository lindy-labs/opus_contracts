%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.starknet.common.syscalls import get_caller_address

from contracts.shared.types import (
    Trove, 
    Gage, 
    Point
)
#
# Constants
#

#
# Events
# 

@event 
func Authorized( address : felt ):
end 

@event 
func Revoked( address : felt ):
end

@event 
func GageUpdated( gage_id : felt, updated_gage : Gage ):
end

@event 
func NumGagesUpdated( new : felt ):
end

@event 
func TroveUpdated( address : felt, trove_id : felt, updated_trove : Trove ):
end 

@event
func DepositUpdated( address : felt, trove_id : felt, new_amount : felt ):
end

@event 
func SeriesIncremented( gage_id : felt, new_len : felt, new_point : Point ):
end

@event 
func CeilingUpdated( new : felt ):
end 

@event 
func TaxUpdated( new : felt ):
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
end

func authorize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address : felt):
	assert_auth()
	auth.write(address, TRUE)
    Authorized.emit(address)
end

func revoke(address : felt):
	assert_auth()
	auth.write(address, FALSE)
    Revoked.emit(address)
end

@event
func Authorized(address : felt):
end

@event
func Revoked(address : felt):
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

# Keeps track of how much of each gage has been deposited into each Trove
@storage_var
func deposits(address : felt, trove_id : felt, gage_id : felt) -> (amount : felt):
end

# Keeps track of the price history of each Gage
@storage_var 
func series(gage_id : felt, index : felt) -> (point : Point):
end

@storage_var
func series_len(gage_id : felt) -> (len : felt):
end

# Total debt ceiling
@storage_var
func ceiling () -> (ceiling : felt):
end

# Fee on yield
@storage_var
func tax () -> (admin_fee : felt):
end

@storage_var
func is_live() -> (is_live : felt):
end


#
# Getters
#

func get_troves{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address: felt, trove_id : felt) -> (trove : Trove):
	return troves.read(address, trove_id)
end

func get_gages{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(gage_id : felt) -> (gage : Gage):
	return gages.read(gage_id)
end

func get_num_gages{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (num : felt):
	return num_gages.read()
end

func get_deposits{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address : felt, trove_id : felt, gage_id : felt) -> (amount : felt):
    return deposited.read(address, trove_id, gage_id)
end



func get_series{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(gage_id, index) -> (point : Point):
	return series.read(gage_id, index)
end

func get_series_len{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(gage_id : felt) -> (len : felt):
	return series_len.read(gage_id)
end

func get_ceiling{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (ceiling : felt):
	return ceiling.read()
end

func get_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (tax : felt):
	return tax.read()
end

func get_is_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (is_live : felt):
	return is_live.read()
end

#
# Setters - Basic setters with no additional logic besides an auth-check and event emission
#

func set_gages{syscall : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(gage_id : felt, gage : Gage):
    assert_auth()

    gages.write(gage_id, gage)
end

func set_num_gages{syscall : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(num : felt):
    assert_auth()

    num_gages.write(num)
    NumGagesUpdated.emit(num)
end

func set_ceiling{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(new_ceiling : felt):
	assert_auth()

	ceiling.write(new_ceiling)
    CeilingUpdated.emit(new_ceiling)
end

func set_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(new_tax : felt):
	assert_auth()

	tax.write(new_tax)
    TaxUpdated.emit(new_tax)
end

func kill{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    assert_auth()

    is_live.write(FALSE)
    Killed.emit()
end




# Constructor
@constructor 
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():

    let (c) = get_caller_address()

    auth.write(c, TRUE)
    is_live.write(TRUE)
end


#
# Core functions
#


# Appends a new point to the Series of the specified Gage
func advance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(gage_id : felt, point : Point):
    assert_auth()

    let (current_len) = series_len.read(gage_id)
    series.write(gage_id, current_len, point)
    series_len.write(current_len + 1)
end