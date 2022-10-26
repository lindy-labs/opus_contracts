%lang starknet

from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.starknet.common.syscalls import get_caller_address

@event
func Authorized(address) {
}

@event
func Revoked(address) {
}

// a simple mapping between an address and a flag (true / false)
// representing if the address is authorized in the system
@storage_var
func auth_authorization_storage(address) -> (bool: felt) {
}

namespace Auth {
    // asserts whether the caller is authorized, fails if they are not
    func assert_caller_authed{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
        let (c) = get_caller_address();
        let (is_authed) = auth_authorization_storage.read(c);
        with_attr error_message("Auth: Caller not authorized") {
            assert is_authed = TRUE;
        }
        return ();
    }

    // asserts whether an address is authorized, fails if they are not
    func assert_address_authed{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        address
    ) {
        let (is_authed) = auth_authorization_storage.read(address);
        with_attr error_message("Auth: Address {address} not authorized") {
            assert is_authed = TRUE;
        }
        return ();
    }

    // marks an address as authorized
    func authorize{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(address) {
        auth_authorization_storage.write(address, TRUE);
        Authorized.emit(address);
        return ();
    }

    // marks an address as NOT authorized
    func revoke{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(address) {
        auth_authorization_storage.write(address, FALSE);
        Revoked.emit(address);
        return ();
    }

    // returns the authorization status of an address
    func is_authorized{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        address
    ) -> (bool: felt) {
        return auth_authorization_storage.read(address);
    }
}
