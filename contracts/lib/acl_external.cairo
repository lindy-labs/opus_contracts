%lang starknet

from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin

from contracts.lib.acl import AccessControl

#
# Getters
#

@view
func get_role{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(user) -> (ufelt):
    let (role) = AccessControl.get_role(user)
    return (role)
end

@view
func has_role{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(role, user) -> (bool):
    let (has_role) = AccessControl.has_role(role, user)
    return (has_role)
end

@view
func get_admin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (address):
    let (admin) = AccessControl.get_admin()
    return (admin)
end

#
# External
#

@external
func grant_role{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(role, address):
    AccessControl.grant_role(role, address)
    return ()
end

@external
func revoke_role{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(role, address):
    AccessControl.revoke_role(role, address)
    return ()
end

@external
func renounce_role{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(role, address):
    AccessControl.renounce_role(role, address)
    return ()
end

@external
func change_admin{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(new_admin):
    AccessControl.assert_admin()
    AccessControl._set_admin(new_admin)
    return ()
end
