%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import assert_le

from contracts.harmonizer.interface import IBeneficiaryRegistrar
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
// Events
//

@event
func Restore(
    beneficiaries_len: ufelt,
    beneficiaries: address*,
    percentages_len: ufelt,
    percentages: ray*,
    amount: wad,
) {
}

//
// Storage
//

@storage_var
func harmonizer_beneficiary_registrar() -> (registrar: address) {
}

@storage_var
func harmonizer_shrine() -> (shrine: address) {
}

//
// Constructor
//

@constructor
func constructor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    admin: address, shrine: address, registrar: address
) {
    AccessControl.initializer(admin);
    harmonizer_shrine.write(shrine);
    harmonizer_beneficiary_registrar.write(registrar);
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
    let registrar: address = harmonizer_beneficiary_registrar.read();
    let (
        beneficiaries_len: ufelt, beneficiaries: address*, percentages_len: ufelt, percentages: ray*
    ) = IBeneficiaryRegistrar.get_beneficiaries(registrar);

    // Loop over and forge yin to beneficiaries
    restore_loop(surplus, beneficiaries_len, 0, beneficiaries, percentages);

    // Assert total debt is less than yin
    // It may not be equal due to rounding errors
    let (updated_total_yin: wad) = IShrine.get_total_yin(shrine);
    with_attr error_message("Harmonizer: Total yin is not equal to total debt") {
        // We can use `assert_le` here because both values have been checked in Shrine
        assert_le(updated_total_yin, total_debt);
    }

    Restore.emit(beneficiaries_len, beneficiaries, percentages_len, percentages, surplus);

    return ();
}

//
// Internal
//

func restore_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    surplus: wad, count: ufelt, idx: ufelt, beneficiaries: address*, percentages: ray*
) {
    alloc_locals;

    if (count == idx) {
        return ();
    }

    // `rmul` of a wad and a ray returns a wad
    let amount: wad = WadRay.rmul([percentages], surplus);

    let shrine: address = harmonizer_shrine.read();
    IShrine.forge_without_trove(shrine, amount, [beneficiaries]);

    return restore_loop(surplus, count, idx + 1, beneficiaries + 1, percentages + 1);
}
