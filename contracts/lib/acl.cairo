# SPDX-License-Identifier: MIT
# OpenZeppelin Contracts for Cairo v0.3.1 (access/accesscontrol/library.cairo)

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
func RoleGranted(role, user):
end

@event
func RoleRevoked(role, user):
end

@event
func AdminChanged(previous_admin, new_admin):
end

#
# Storage
#

@storage_var
func AccessControl_admin() -> (admin):
end

@storage_var
func AccessControl_role(account) -> (role):
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

    func get_role{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(user) -> (
        ufelt
    ):
        let (user_role) = AccessControl_role.read(user)
        return (user_role)
    end

    func has_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role, user) -> (bool):
        let (user_role) = AccessControl_role.read(user)
        let (has_role) = bitwise_and(user_role, role)
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
    }(role, user):
        assert_admin()
        _grant_role(role, user)
        return ()
    end

    func revoke_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role, user):
        assert_admin()
        _revoke_role(role, user)
        return ()
    end

    func renounce_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role, user):
        let (caller) = get_caller_address()
        with_attr error_message("AccessControl: can only renounce roles for self"):
            assert user = caller
        end
        _revoke_role(role, user)
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
    }(role, user):
        let (user_role) = AccessControl_role.read(user)
        let (new_user_role) = bitwise_or(user_role, role)
        AccessControl_role.write(user, new_user_role)
        RoleGranted.emit(role, user)
        return ()
    end

    func _revoke_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role, user):
        let (user_role) = AccessControl_role.read(user)
        let (revoked_complement) = bitwise_not(role)
        let (new_user_role) = bitwise_and(user_role, revoked_complement)
        AccessControl_role.write(user, new_user_role)
        RoleRevoked.emit(role, user)
        return ()
    end

    func _set_admin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(new_admin):
        let (previous_admin) = get_admin()
        AccessControl_admin.write(new_admin)
        AdminChanged.emit(previous_admin, new_admin)
        return ()
    end
end
