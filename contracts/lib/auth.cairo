%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.starknet.common.syscalls import get_caller_address

@event
func Authorized(address):
end

@event
func Revoked(address):
end

# a simple mapping between an address and a flag (true / false)
# representing if the address is authorized in the system
@storage_var
func auth_authorization_storage(address) -> (bool):
end

namespace Auth:
    # asserts whether the caller is authorized, fails if they are not
    func assert_caller{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
        let (c) = get_caller_address()
        let (is_authed) = auth_authorization_storage.read(c)
        with_attr error_message("Auth: caller not authorized"):
            assert is_authed = TRUE
        end
        return ()
    end

    # asserts whether an address is authorized, fails if they are not
    func assert_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
        let (is_authed) = auth_authorization_storage.read(address)
        with_attr error_message("Auth: address {address} not authorized"):
            assert is_authed = TRUE
        end
        return ()
    end

    # marks an address as authorized
    func authorize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
        auth_authorization_storage.write(address, TRUE)
        Authorized.emit(address)
        return ()
    end

    # marks an address as NOT authorized
    func revoke{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
        auth_authorization_storage.write(address, FALSE)
        Revoked.emit(address)
        return ()
    end

    # returns the authorization status of an address
    func get_authorization{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        address
    ) -> (bool):
        return auth_authorization_storage.read(address)
    end
end
