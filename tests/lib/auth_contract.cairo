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
func get_authorization{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    address
) -> (bool):
    return Auth.get_authorization(address)
end

@view
func assert_caller{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (bool):
    Auth.assert_caller()
    return (TRUE)
end

@view
func assert_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address) -> (
    bool
):
    Auth.assert_address(address)
    return (TRUE)
end
