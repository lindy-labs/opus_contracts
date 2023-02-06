%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import assert_not_zero

from contracts.harmonizer.roles import BeneficiaryRegistrarRoles

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
func BeneficiariesUpdated(
    beneficiaries_len: ufelt, beneficiaries: address*, percentages_len: ufelt, percentages: ray*
) {
}

//
// Storage
//

@storage_var
func registrar_beneficiaries_count() -> (count: ufelt) {
}

@storage_var
func registrar_beneficiaries(idx: ufelt) -> (address: address) {
}

@storage_var
func registrar_beneficiaries_percentage(idx: ufelt) -> (percentage: ray) {
}

//
// Constructor
//

@constructor
func constructor{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(
    admin: address,
    beneficiaries_len: ufelt,
    beneficiaries: address*,
    percentages_len: ufelt,
    percentages: ray*,
) {
    AccessControl.initializer(admin);
    AccessControl._grant_role(BeneficiaryRegistrarRoles.SET_BENEFICIARIES, admin);

    set_beneficiaries_internal(beneficiaries_len, beneficiaries, percentages_len, percentages);

    return ();
}

//
// Getters
//

@view
func get_beneficiaries_count{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    count: ufelt
) {
    let (count: ufelt) = registrar_beneficiaries_count.read();
    return (count,);
}

//
// View
//

@view
func get_beneficiaries{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    beneficiaries_len: ufelt, beneficiaries: address*, percentages_len: ufelt, percentages: ray*
) {
    alloc_locals;

    let beneficiaries_count: ufelt = registrar_beneficiaries_count.read();

    let (beneficiaries: address*) = alloc();
    let (percentages: ray*) = alloc();

    get_beneficiaries_loop(beneficiaries_count, 0, beneficiaries, percentages);

    return (beneficiaries_count, beneficiaries, beneficiaries_count, percentages);
}

//
// Setters
//

@external
func set_beneficiaries{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(beneficiaries_len: ufelt, beneficiaries: address*, percentages_len: ufelt, percentages: ray*) {
    alloc_locals;

    AccessControl.assert_has_role(BeneficiaryRegistrarRoles.SET_BENEFICIARIES);

    set_beneficiaries_internal(beneficiaries_len, beneficiaries, percentages_len, percentages);

    return ();
}

//
// Internal
//

// Fetch the list of beneficiary addresses and their percentages.
func get_beneficiaries_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    count: ufelt, idx: ufelt, beneficiaries: address*, percentages: ray*
) {
    if (count == idx) {
        return ();
    }

    let (beneficiary: address) = registrar_beneficiaries.read(idx);
    assert [beneficiaries] = beneficiary;

    let (percentage: ray) = registrar_beneficiaries_percentage.read(idx);
    assert [percentages] = percentage;

    return get_beneficiaries_loop(count, idx + 1, beneficiaries + 1, percentages + 1);
}

// Asserts that percentages sum up to one ray scale
@external
func set_beneficiaries_internal{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(beneficiaries_len: ufelt, beneficiaries: address*, percentages_len: ufelt, percentages: ray*) {
    alloc_locals;

    with_attr error_message(
            "Beneficiary Registrar: Input arguments mismatch: {beneficiaries_len} != {percentages_len}") {
        assert beneficiaries_len = percentages_len;
    }

    with_attr error_message("Beneficiary Registrar: No beneficiaries provided") {
        assert_not_zero(beneficiaries_len);
    }

    registrar_beneficiaries_count.write(beneficiaries_len);
    set_beneficiaries_internal_loop(beneficiaries_len, 0, 0, beneficiaries, percentages);

    BeneficiariesUpdated.emit(beneficiaries_len, beneficiaries, percentages_len, percentages);

    return ();
}

// Store the list of beneficiary addresses and their percentages.
// Asserts that the total percentage is equal to one ray scale
func set_beneficiaries_internal_loop{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(count: ufelt, idx: ufelt, percentages_total: ray, beneficiaries: address*, percentages: ray*) {
    alloc_locals;

    if (count == idx) {
        with_attr error_message("Beneficiary Registrar: Percentages do not sum up to a ray") {
            assert percentages_total = WadRay.RAY_ONE;
        }
        return ();
    }

    let (beneficiary: address) = registrar_beneficiaries.read(idx);
    let percentage: ray = [percentages];
    registrar_beneficiaries.write(idx, [beneficiaries]);
    registrar_beneficiaries_percentage.write(idx, percentage);

    let updated_percentages_total: ray = percentages_total + percentage;

    return set_beneficiaries_internal_loop(
        count, idx + 1, updated_percentages_total, beneficiaries + 1, percentages + 1
    );
}
