%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import assert_not_zero

from contracts.harmonizer.roles import AllocatorRoles

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
// Events
//

@event
func AllocationUpdated(
    recipients_len: ufelt, recipients: address*, percentages_len: ufelt, percentages: ray*
) {
}

//
// Storage
//

@storage_var
func allocator_recipients_count() -> (count: ufelt) {
}

@storage_var
func allocator_recipients(idx: ufelt) -> (address: address) {
}

@storage_var
func allocator_recipient_percentage(recipient: address) -> (percentage: ray) {
}

//
// Constructor
//

@constructor
func constructor{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(
    admin: address,
    recipients_len: ufelt,
    recipients: address*,
    percentages_len: ufelt,
    percentages: ray*,
) {
    AccessControl.initializer(admin);
    AccessControl._grant_role(AllocatorRoles.SET_ALLOCATION, admin);

    set_allocation_internal(recipients_len, recipients, percentages_len, percentages);

    return ();
}

//
// Getters
//

@view
func get_recipients_count{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    count: ufelt
) {
    let (count: ufelt) = allocator_recipients_count.read();
    return (count,);
}

//
// View
//

@view
func get_allocation{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    recipients_len: ufelt, recipients: address*, percentages_len: ufelt, percentages: ray*
) {
    alloc_locals;

    let recipients_count: ufelt = allocator_recipients_count.read();

    let (recipients: address*) = alloc();
    let (percentages: ray*) = alloc();

    get_allocation_loop(recipients_count, 0, recipients, percentages);

    return (recipients_count, recipients, recipients_count, percentages);
}

//
// Setters
//

@external
func set_allocation{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(recipients_len: ufelt, recipients: address*, percentages_len: ufelt, percentages: ray*) {
    AccessControl.assert_has_role(AllocatorRoles.SET_ALLOCATION);

    set_allocation_internal(recipients_len, recipients, percentages_len, percentages);

    return ();
}

//
// Internal
//

// Fetch the allocation
func get_allocation_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    count: ufelt, idx: ufelt, recipients: address*, percentages: ray*
) {
    if (count == idx) {
        return ();
    }

    let (recipient: address) = allocator_recipients.read(idx);
    assert [recipients] = recipient;

    let (percentage: ray) = allocator_recipient_percentage.read(recipient);
    assert [percentages] = percentage;

    return get_allocation_loop(count, idx + 1, recipients + 1, percentages + 1);
}

func set_allocation_internal{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(recipients_len: ufelt, recipients: address*, percentages_len: ufelt, percentages: ray*) {
    alloc_locals;

    with_attr error_message(
            "Allocator: Input arguments mismatch: {recipients_len} != {percentages_len}") {
        assert recipients_len = percentages_len;
    }

    with_attr error_message("Allocator: No recipients provided") {
        assert_not_zero(recipients_len);
    }

    allocator_recipients_count.write(recipients_len);
    set_allocation_internal_loop(recipients_len, 0, 0, recipients, percentages);

    AllocationUpdated.emit(recipients_len, recipients, percentages_len, percentages);

    return ();
}

// Store the list of recipient addresses and their percentages.
// Asserts that the total percentage is equal to one ray scale
func set_allocation_internal_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    count: ufelt, idx: ufelt, percentages_total: ray, recipients: address*, percentages: ray*
) {
    if (count == idx) {
        with_attr error_message("Allocator: Percentages do not sum up to a ray") {
            assert percentages_total = WadRay.RAY_ONE;
        }
        return ();
    }

    let recipient: address = [recipients];
    let percentage: ray = [percentages];
    allocator_recipients.write(idx, recipient);
    allocator_recipient_percentage.write(recipient, percentage);

    let updated_percentages_total: ray = percentages_total + percentage;

    return set_allocation_internal_loop(
        count, idx + 1, updated_percentages_total, recipients + 1, percentages + 1
    );
}
