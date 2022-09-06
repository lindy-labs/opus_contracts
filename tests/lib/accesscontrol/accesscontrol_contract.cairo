%lang starknet

from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin

from contracts.lib.accesscontrol.library import AccessControl
// these imported public functions are part of the contract's interface
from contracts.lib.accesscontrol.accesscontrol_external import (
    get_role,
    has_role,
    get_admin,
    grant_role,
    revoke_role,
    renounce_role,
    change_admin,
)
from tests.lib.accesscontrol.roles import AccRoles

//
// Access Control - Constructor
//

@constructor
func constructor{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(admin) {
    AccessControl.initializer(admin);
    return ();
}

//
// Access Control - Modifiers
//

@view
func assert_has_role{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(role) {
    AccessControl.assert_has_role(role);
    return ();
}

@view
func assert_admin{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}() {
    AccessControl.assert_admin();
    return ();
}

//
// Access Control - Getters
//

@view
func can_execute{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(user) -> (bool: felt) {
    let (authorized) = AccessControl.has_role(AccRoles.EXECUTE, user);
    return (authorized,);
}

@view
func can_write{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(user) -> (bool: felt) {
    let (authorized) = AccessControl.has_role(AccRoles.WRITE, user);
    return (authorized,);
}

@view
func can_read{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(user) -> (bool: felt) {
    let (authorized) = AccessControl.has_role(AccRoles.READ, user);
    return (authorized,);
}
