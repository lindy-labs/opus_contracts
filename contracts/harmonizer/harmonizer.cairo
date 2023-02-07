%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import assert_le

from contracts.harmonizer.interface import IAllocator
from contracts.harmonizer.roles import HarmonizerRoles
from contracts.shrine.interface import IShrine

// these imported public functions are part of the contract's interface
from contracts.lib.accesscontrol.accesscontrol_external import (
    change_admin,
    get_admin,
    get_roles,
    grant_role,
    has_role,
    renounce_role,
    revoke_role,
)
from contracts.lib.accesscontrol.library import AccessControl
from contracts.lib.aliases import address, ray, ufelt, wad
from contracts.lib.wad_ray import WadRay

//
// Storage
//

@storage_var
func harmonizer_allocator() -> (registrar: address) {
}

@storage_var
func harmonizer_shrine() -> (shrine: address) {
}

//
// Events
//

@event
func AllocatorUpdated(old_address: address, new_address: address) {
}

@event
func Restore(
    recipients_len: ufelt,
    recipients: address*,
    percentages_len: ufelt,
    percentages: ray*,
    amount: wad,
) {
}

//
// Constructor
//

@constructor
func constructor{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(admin: address, shrine: address, registrar: address) {
    AccessControl.initializer(admin);
    AccessControl._grant_role(HarmonizerRoles.SET_ALLOCATOR, admin);

    harmonizer_shrine.write(shrine);
    harmonizer_allocator.write(registrar);
    return ();
}

//
// View
//

@view
func get_allocator{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    allocator: address
) {
    let allocator: address = harmonizer_allocator.read();
    return (allocator,);
}

//
// Setters
//

@external
func set_allocator{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(allocator: address) {
    AccessControl.assert_has_role(HarmonizerRoles.SET_ALLOCATOR);

    let old_address: address = harmonizer_allocator.read();
    harmonizer_allocator.write(allocator);

    AllocatorUpdated.emit(old_address, allocator);

    return ();
}

//
// External
//

@external
func restore{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    alloc_locals;

    // Check total debt vs total yin
    let shrine: address = harmonizer_shrine.read();
    let (total_debt: wad) = IShrine.get_total_debt(shrine);
    let (total_yin: wad) = IShrine.get_total_yin(shrine);

    let surplus: wad = WadRay.unsigned_sub(total_debt, total_yin);
    if (surplus == 0) {
        return ();
    }

    // Get array of addresses and percentages
    let registrar: address = harmonizer_allocator.read();
    let (
        recipients_len: ufelt, recipients: address*, percentages_len: ufelt, percentages: ray*
    ) = IAllocator.get_allocation(registrar);

    // Loop over and forge yin to recipients
    restore_loop(surplus, recipients_len, 0, recipients, percentages);

    // Assert total debt is less than yin
    // It may not be equal due to rounding errors
    let (updated_total_yin: wad) = IShrine.get_total_yin(shrine);
    with_attr error_message("Harmonizer: Total yin exceeds total debt") {
        // We can use `assert_le` here because both values have been checked in Shrine
        assert_le(updated_total_yin, total_debt);
    }

    Restore.emit(recipients_len, recipients, percentages_len, percentages, surplus);

    return ();
}

//
// Internal
//

func restore_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    surplus: wad, count: ufelt, idx: ufelt, recipients: address*, percentages: ray*
) {
    if (count == idx) {
        return ();
    }

    // `rmul` of a wad and a ray returns a wad
    let amount: wad = WadRay.rmul([percentages], surplus);

    let shrine: address = harmonizer_shrine.read();
    IShrine.forge_without_trove(shrine, [recipients], amount);

    return restore_loop(surplus, count, idx + 1, recipients + 1, percentages + 1);
}
