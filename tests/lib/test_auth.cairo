%lang starknet

from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin

from contracts.lib.auth import Auth

@external
func authorize{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(address) {
    Auth.authorize(address);
    return ();
}

@external
func revoke{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(address) {
    Auth.revoke(address);
    return ();
}

@view
func is_authorized{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(address) -> (
    bool: felt
) {
    return Auth.is_authorized(address);
}

@view
func assert_caller_authed{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    bool: felt
) {
    Auth.assert_caller_authed();
    return (TRUE,);
}

@view
func assert_address_authed{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    address
) -> (bool: felt) {
    Auth.assert_address_authed(address);
    return (TRUE,);
}
