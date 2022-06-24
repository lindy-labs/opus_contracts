%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero
from starkware.cairo.common.uint256 import Uint256, uint256_lt, uint256_sub
from starkware.starknet.common.syscalls import get_contract_address

from contracts.shared.interfaces import IERC20, IShrine
from contracts.shared.convert import uint_to_felt_unchecked

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

@storage_var
func gate_shrine() -> (address):
end

#
# Constructor
#

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(authed, gate):
    gate_auth.write(authed, TRUE)
    gate_live.write(TRUE)
    gate_shrine.write(gate)
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
    gage_address, user_address, trove_id, amt : Uint256
):
    # Assert live
    let (live) = shrine_live.read()
    with_attr error_message("Gate: Gate is not live"):
        assert live = TRUE
    end

    # Check balance
    let before = IERC20.balanceOf(user_address)
    let sufficient = uint256_le(amt, before)
    with_attr error_message("Gate: Insufficient balance"):
        assert sufficient = TRUE
    end

    # Check allowance
    let dst = get_contract_address()
    let allowed = IERC20.allowance(user_address, contract_address)
    let approved = uint256_le(amt, allowed)
    with_attr error_message("Gate: Insufficient allowance"):
        assert approved = TRUE
    end

    # Transfer ERC20
    IERC20.transferFrom(
        contract_address=gage_address, owner=user_address, recipient=dst, amount=amt
    )

    # Assert successful transfer
    let after = IERC20.balanceOf(user_address)
    let expected = uint256_sub(before, amt)
    with_attr error_message("Gate: Unsuccessful transfer"):
        assert after = expected
    end

    # Convert amount from Uint256 to felt
    let amt_felt = uint_to_felt_unchecked(amt)

    # Read `shrine` address
    let shrine = gate_shrine.read()

    # Get gage ID
    let gage_id = IShrine.get_gage_id(contract_address=shrine, gage_address=gage_address)
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
end

@external
func recoup{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(gage_address, amt):
    # Call `shrine.withdraw`

    # Transfer ERC20
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
