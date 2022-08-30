%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin

from contracts.lib.auth import Auth

@view
func get_auth{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(address) -> (
    bool: felt
) {
    return Auth.is_authorized(address);
}

@external
func authorize{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(address) {
    Auth.assert_caller_authed();
    Auth.authorize(address);
    return ();
}

@external
func revoke{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(address) {
    Auth.assert_caller_authed();
    Auth.revoke(address);
    return ();
}
