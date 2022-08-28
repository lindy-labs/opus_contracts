# Adapted from OpenZeppelin Contracts for Cairo v0.3.1 (access/accesscontrol/library.cairo)

%lang starknet

from starkware.starknet.common.syscalls import get_caller_address
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.bitwise import bitwise_and, bitwise_not, bitwise_or
from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.math_cmp import is_not_zero

#
# Events
#

@event
func RoleGranted(role, account):
end

@event
func RoleRevoked(role, account):
end

@event
func AdminChanged(prev_admin, new_admin):
end

#
# Storage
#

@storage_var
func accesscontrol_admin_storage() -> (address):
end

@storage_var
func accesscontrol_role_storage(account) -> (ufelt):
end

namespace AccessControl:
    #
    # Initializer
    #

    func initializer{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(admin):
        _set_admin(admin)
        return ()
    end

    #
    # Modifier
    #

    func assert_has_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role):
        alloc_locals
        let (caller_address) = get_caller_address()
        let (authorized) = has_role(role, caller_address)
        with_attr error_message("AccessControl: caller is missing role {role}"):
            assert authorized = TRUE
        end
        return ()
    end

    func assert_admin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
        alloc_locals
        let (caller_address) = get_caller_address()
        let (admin_address) = get_admin()
        with_attr error_message("AccessControl: caller is not admin"):
            assert caller_address = admin_address
        end
        return ()
    end

    #
    # Getters
    #

    func get_role{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(account) -> (
        ufelt
    ):
        let (role) = accesscontrol_role_storage.read(account)
        return (role)
    end

    func has_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role, account) -> (bool):
        let (account_role) = accesscontrol_role_storage.read(account)
        let (has_role) = bitwise_and(account_role, role)
        let (authorized) = is_not_zero(has_role)
        return (authorized)
    end

    func get_admin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        address
    ):
        let (admin_address) = accesscontrol_admin_storage.read()
        return (admin_address)
    end

    #
    # Externals
    #

    func grant_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role, account):
        assert_admin()
        _grant_role(role, account)
        return ()
    end

    func revoke_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role, account):
        assert_admin()
        _revoke_role(role, account)
        return ()
    end

    func renounce_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role, account):
        let (caller_address) = get_caller_address()
        with_attr error_message("AccessControl: can only renounce roles for self"):
            assert account = caller_address
        end
        _revoke_role(role, account)
        return ()
    end

    func change_admin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
        assert_admin()
        _set_admin(address)
        return ()
    end

    #
    # Unprotected
    #

    func _grant_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role, account):
        let (role_value) = accesscontrol_role_storage.read(account)
        let (updated_role_value) = bitwise_or(role_value, role)
        accesscontrol_role_storage.write(account, updated_role_value)
        RoleGranted.emit(role, account)
        return ()
    end

    func _revoke_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role, account):
        let (role_value) = accesscontrol_role_storage.read(account)
        let (revoked_complement) = bitwise_not(role)
        let (updated_role_value) = bitwise_and(role_value, revoked_complement)
        accesscontrol_role_storage.write(account, updated_role_value)
        RoleRevoked.emit(role, account)
        return ()
    end

    func _set_admin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
        let (prev_admin_address) = get_admin()
        accesscontrol_admin_storage.write(address)
        AdminChanged.emit(prev_admin_address, address)
        return ()
    end
end
