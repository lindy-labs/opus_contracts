%lang starknet

from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin

from contracts.lib.accesscontrol.library import AccessControl

#
# Getters
#

@view
func get_role{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(account) -> (ufelt):
    let (role) = AccessControl.get_role(account)
    return (role)
end

@view
func has_role{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(role, account) -> (bool):
    let (has_role) = AccessControl.has_role(role, account)
    return (has_role)
end

@view
func get_admin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (address):
    let (admin_address) = AccessControl.get_admin()
    return (admin_address)
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
func change_admin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
    AccessControl.change_admin(address)
    return ()
end
