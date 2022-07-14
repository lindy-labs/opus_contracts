%lang starknet

from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin

from contracts.lib.auth import Auth

@external
func authorize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
    Auth.authorize(address)
    return ()
end

@external
func revoke{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
    Auth.revoke(address)
    return ()
end

@view
func is_authorized{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address) -> (
    bool
):
    return Auth.is_authorized(address)
end

@view
func assert_caller_authed{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    bool
):
    Auth.assert_caller_authed()
    return (TRUE)
end

@view
func assert_address_authed{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    address
) -> (bool):
    Auth.assert_address_authed(address)
    return (TRUE)
end
