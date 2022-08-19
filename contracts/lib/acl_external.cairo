%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin

from openzeppelin.access.accesscontrol.library import AccessControl

#
# Getters
#

@view
func has_role{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(role, user) -> (
    bool
):
    let (has_role) = AccessControl.has_role(role, user)
    return (has_role)
end

@view
func get_role_admin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(role) -> (
    address
):
    let (admin) = AccessControl.get_role_admin(role)
    return (admin)
end

#
# External
#

@external
func grant_role{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(role, address):
    AccessControl.grant_role(role, address)
    return ()
end

@external
func revoke_role{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(role, address):
    AccessControl.revoke_role(role, address)
    return ()
end

@external
func renounce_role{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    role, address
):
    AccessControl.renounce_role(role, address)
    return ()
end
