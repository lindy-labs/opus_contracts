%lang starknet

from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin

from contracts.lib.acl import AccessControl
from contracts.lib.acl_external import (
    get_role,
    has_role,
    get_admin,
    grant_role,
    revoke_role,
    renounce_role,
    change_admin,
)
from tests.lib.acl.roles import AclRoles

#
# Access Control - Constructor
#

@constructor
func constructor{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(admin):
    AccessControl._set_admin(admin)
    return ()
end

#
# Access Control - Modifiers
#

@view
func assert_has_role{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(role):
    AccessControl.assert_has_role(role)
    return ()
end

@view
func assert_admin{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}():
    AccessControl.assert_admin()
    return ()
end

#
# Access Control - Getters
#

@view
func can_execute{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(user) -> (bool):
    let (authorized) = AccessControl.has_role(AclRoles.EXECUTE, user)
    return (authorized)
end

@view
func can_write{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(user) -> (bool):
    let (authorized) = AccessControl.has_role(AclRoles.WRITE, user)
    return (authorized)
end

@view
func can_read{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(user) -> (bool):
    let (authorized) = AccessControl.has_role(AclRoles.READ, user)
    return (authorized)
end
