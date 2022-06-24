%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero
from starkware.cairo.common.uint256 import Uint256, uint256_le, uint256_sub
from starkware.starknet.common.syscalls import get_caller_address, get_contract_address

from contracts.shared.interfaces import IERC20, IShrine
from contracts.shared.convert import uint_to_felt_unchecked
from contracts.shared.wad_ray import WadRay

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
func Killed():
end

@event
func Pledged(user_address, trove_id, amt):
end

@event
func Recouped(user_address, trove_id, amt):
end

#
# Storage
#

@storage_var
func gate_auth(address) -> (authorized):
end

@storage_var
func gate_live() -> (live):
end

# Address of Shrine instance for given synthetic
@storage_var
func gate_shrine_address() -> (address):
end

# Address of gage
@storage_var
func gate_gage_address() -> (address):
end

# Exchange rate of Gate share to underlying (wad)
@storage_var
func gate_exchange_rate() -> (rate):
end

# Total number of gage tokens held by contract (wad)
@storage_var
func gate_gage_total() -> (total):
end

@storage_var
func gate_gage_pledged(user_address, trove_id) -> (amount):
end

# Timestamp of the last update of yield from underlying gage
@storage_var
func gate_gage_last_updated() -> (timestamp):
end

#
# Constructor
#

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    authed, shrine_address, gage_address
):
    gate_auth.write(authed, TRUE)
    gate_live.write(TRUE)
    gate_shrine_address.write(shrine_address)
    gate_gage_address.write(gage_address)
    return ()
end

#
# External
#

@external
func authorize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
    assert_auth()
    gate_auth.write(address, TRUE)
    Authorized.emit(address)
    return ()
end

@external
func revoke{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
    assert_auth()
    gate_auth.write(address, FALSE)
    Revoked.emit(address)
    return ()
end

@external
func kill{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    assert_auth()

    gate_live.write(FALSE)
    Killed.emit()
    return ()
end

@external
func pledge{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, amt : Uint256
):
    alloc_locals

    # Assert live
    let (live) = gate_live.read()
    with_attr error_message("Gate: Gate is not live"):
        assert live = TRUE
    end

    # Check balance
    let (gage_address) = gate_gage_address.read()
    let before : Uint256 = IERC20.balanceOf(contract_address=gage_address, account=user_address)
    let (sufficient) = uint256_le(amt, before)
    with_attr error_message("Gate: Insufficient balance"):
        assert sufficient = TRUE
    end

    # Check allowance
    let (dst) = get_contract_address()
    let allowed : Uint256 = IERC20.allowance(
        contract_address=gage_address, owner=user_address, spender=dst
    )
    let (approved) = uint256_le(amt, allowed)
    with_attr error_message("Gate: Insufficient allowance"):
        assert approved = TRUE
    end

    # Transfer ERC20
    IERC20.transferFrom(
        contract_address=gage_address, sender=user_address, recipient=dst, amount=amt
    )

    # Assert successful transfer
    let after : Uint256 = IERC20.balanceOf(contract_address=gage_address, account=user_address)
    let (expected) = uint256_sub(before, amt)
    with_attr error_message("Gate: Unsuccessful transfer"):
        assert after = expected
    end

    # Convert amount from Uint256 to felt
    let (amt_felt) = uint_to_felt_unchecked(amt)

    # Add to Gate's system total
    let (current_total) = gate_gage_total.read()
    let new_total = current_total + amt_felt
    gate_gage_total.write(new_total)

    # Calculate amount of shares to mint
    let (exchange_rate) = gate_exchange_rate.read()
    let (shares) = WadRay.wunsigned_div(amt_felt, exchange_rate)
    let (existing_shares) = gate_gage_pledged.read(user_address, trove_id)
    let (new_shares) = WadRay.add_unsigned(shares, existing_shares)
    gate_gage_pledged.write(user_address, trove_id, new_shares)

    # Read `shrine` address
    let (shrine) = gate_shrine_address.read()

    # Get gage ID
    let (gage_id) = IShrine.get_gage_id(contract_address=shrine, gage_address=gage_address)
    assert_not_zero(gage_id)

    # Call `shrine.deposit`
    IShrine.deposit(
        contract_address=shrine,
        gage_id=gage_id,
        amount=amt_felt,
        user_address=user_address,
        trove_id=trove_id,
    )

    Pledged.emit(user_address, trove_id, amt_felt)

    return ()
end

@external
func recoup{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(gage_address, amt):
    # Call `shrine.withdraw`

    # Get underlying amount

    # Update total

    # Decrement shares

    # Transfer ERC20

    return ()
end

# Update exchange rate of shares to underlying
@external
func sync{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    return ()
end

#
# Internal
#

# Similar to onlyOwner
func assert_auth{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    let (c) = get_caller_address()
    let (is_authed) = gate_auth.read(c)
    assert is_authed = TRUE
    return ()
end
