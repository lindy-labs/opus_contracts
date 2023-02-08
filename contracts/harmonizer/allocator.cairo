%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero

from contracts.lib.aliases import address, ray, ufelt, wad
from contracts.lib.wad_ray import WadRay

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
func constructor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    recipients_len: ufelt, recipients: address*, percentages_len: ufelt, percentages: ray*
) {
    with_attr error_message(
            "Allocator: Input arguments mismatch: {recipients_len} != {percentages_len}") {
        assert recipients_len = percentages_len;
    }

    with_attr error_message("Allocator: No recipients provided") {
        assert_not_zero(recipients_len);
    }

    allocator_recipients_count.write(recipients_len);
    set_allocation_loop(recipients_len, 0, 0, recipients, percentages);

    return ();
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

// Loop over recipients, and write their addresses and percentages to storage.
// Asserts that the total percentage is equal to one ray scale.
func set_allocation_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
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

    let updated_percentages_total: ray = WadRay.unsigned_add(percentages_total, percentage);

    return set_allocation_loop(
        count, idx + 1, updated_percentages_total, recipients + 1, percentages + 1
    );
}
