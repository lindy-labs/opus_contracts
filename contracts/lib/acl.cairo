# SPDX-License-Identifier: MIT
# OpenZeppelin Contracts for Cairo v0.3.1 (access/accesscontrol/library.cairo)

%lang starknet

from starkware.starknet.common.syscalls import get_caller_address
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.bitwise import bitwise_and, bitwise_or, bitwise_xor
from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.math_cmp import is_not_zero

from openzeppelin.introspection.erc165.library import ERC165
from openzeppelin.utils.constants.library import IACCESSCONTROL_ID

#
# Events
#

@event
func RoleGranted(role : felt, account : felt, sender : felt):
end

@event
func RoleRevoked(role : felt, account : felt, sender : felt):
end

@event
func AdminChanged(previousAdminRole : felt, newAdminRole : felt):
end

#
# Storage
#

@storage_var
func AccessControl_admin() -> (admin : felt):
end

@storage_var
func AccessControl_role(account : felt) -> (role : felt):
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
    }(role : felt):
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

    func has_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role : felt, user : felt) -> (has_role : felt):
        let (user_role : felt) = AccessControl_role.read(user)
        let (has_role) = bitwise_and(user_role, role)
        let (authorized) = is_not_zero(has_role)
        return (authorized)
    end

    func get_admin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        address
    ):
        let (admin : felt) = AccessControl_admin.read()
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
    }(role : felt, user : felt):
        assert_admin()
        _grant_role(role, user)
        return ()
    end

    func revoke_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role : felt, user : felt):
        assert_admin()
        _revoke_role(role, user)
        return ()
    end

    func renounce_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role : felt, user : felt):
        let (caller : felt) = get_caller_address()
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
    }(role : felt, user : felt):
        let (user_role : felt) = AccessControl_role.read(user)
        let (new_user_role) = bitwise_or(user_role, role)
        AccessControl_role.write(user, new_user_role)
        return ()
    end

    func _revoke_role{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr,
        bitwise_ptr : BitwiseBuiltin*,
    }(role : felt, user : felt):
        let (user_role : felt) = AccessControl_role.read(user)
        let (new_user_role) = bitwise_xor(user_role, role)
        AccessControl_role.write(user, new_user_role)
        return ()
    end

    func _set_admin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        new_admin : felt
    ):
        let (previous_admin : felt) = get_admin()
        AccessControl_admin.write(new_admin)
        AdminChanged.emit(previous_admin, new_admin)
        return ()
    end
end
