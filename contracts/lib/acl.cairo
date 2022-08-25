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
func AccessControl_admin() -> (address):
end

@storage_var
func AccessControl_role(account) -> (ufelt):
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
        let (caller) = get_caller_address()
        let (authorized) = has_role(role, caller)
        with_attr error_message("AccessControl: caller is missing role {role}"):
            assert authorized = TRUE
        end
        return ()
    end

    func assert_admin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
        alloc_locals
        let (caller) = get_caller_address()
        let (admin) = get_admin()
        with_attr error_message("AccessControl: caller is not admin"):
            assert caller = admin
        end
        return ()
    end

    #
    # Getters
    #

    func get_role{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(account) -> (
        ufelt
    ):
        let (role) = AccessControl_role.read(account)
        return (role)
    end

    func has_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role, account) -> (bool):
        let (account_role) = AccessControl_role.read(account)
        let (has_role) = bitwise_and(account_role, role)
        let (authorized) = is_not_zero(has_role)
        return (authorized)
    end

    func get_admin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        address
    ):
        let (admin) = AccessControl_admin.read()
        return (admin)
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
        let (caller) = get_caller_address()
        with_attr error_message("AccessControl: can only renounce roles for self"):
            assert account = caller
        end
        _revoke_role(role, account)
        return ()
    end

    func change_admin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
        assert_admin()
        _set_admin(address)
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
        let (role_value) = AccessControl_role.read(account)
        let (updated_role_value) = bitwise_or(role_value, role)
        AccessControl_role.write(account, updated_role_value)
        RoleGranted.emit(role, account)
        return ()
    end

    func _revoke_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role, account):
        let (role_value) = AccessControl_role.read(account)
        let (revoked_complement) = bitwise_not(role)
        let (updated_role_value) = bitwise_and(role_value, revoked_complement)
        AccessControl_role.write(account, updated_role_value)
        RoleRevoked.emit(role, account)
        return ()
    end

    func _set_admin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(new_admin):
        let (prev_admin) = get_admin()
        AccessControl_admin.write(new_admin)
        AdminChanged.emit(prev_admin, new_admin)
        return ()
    end
end
