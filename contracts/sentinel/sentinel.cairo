%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import assert_not_zero

from contracts.gate.interface import IGate
from contracts.sentinel.roles import SentinelRoles
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

//
// Events
//

@event
func YangAdded(yang: address, gate: address) {
}

//
// Storage
//

// mapping between a yang address and our deployed Gate
@storage_var
func sentinel_yang_to_gate(yang: address) -> (gate: address) {
}

// length of the sentinel_yang_addresses array
@storage_var
func sentinel_yang_addresses_count() -> (count: ufelt) {
}

// 0-based array of yang addresses added to the Shrine via this Sentinel
@storage_var
func sentinel_yang_addresses(idx: ufelt) -> (yang: address) {
}

// the address of the Shrine associated with this Sentinel
@storage_var
func sentinel_shrine_address() -> (shrine: address) {
}

//
// Constructor
//

@constructor
func constructor{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(admin: address, shrine: address) {
    AccessControl.initializer(admin);
    AccessControl._grant_role(SentinelRoles.ADD_YANG, admin);
    sentinel_shrine_address.write(shrine);
    return ();
}

//
// View functions
//

@view
func get_gate_address{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address
) -> (gate: address) {
    return sentinel_yang_to_gate.read(yang);
}

@view
func get_yang_addresses{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    addresses_len: ufelt, addresses: address*
) {
    alloc_locals;
    let (count: ufelt) = sentinel_yang_addresses_count.read();
    let (addresses: address*) = alloc();
    get_yang_addresses_loop(count, 0, addresses);
    return (count, addresses);
}

@view
func get_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(idx: ufelt) -> (
    yang: address
) {
    return sentinel_yang_addresses.read(idx);
}

@view
func get_yang_addresses_count{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    ) -> (count: ufelt) {
    return sentinel_yang_addresses_count.read();
}

@view
func get_asset_amt_per_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address
) -> (amt: wad) {
    let (gate: address) = get_gate_address(yang);

    with_attr error_message("Sentinel: Yang {yang} is not approved") {
        assert_not_zero(gate);
    }

    let amt: wad = IGate.get_asset_amt_per_yang(gate);
    return (amt,);
}

@view
func preview_enter{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address, asset_amt: ufelt
) -> (preview: wad) {
    let (gate: address) = get_gate_address(yang);

    with_attr error_message("Sentinel: Yang {yang} is not approved") {
        assert_not_zero(gate);
    }

    let yang_amt: wad = IGate.preview_enter(gate, asset_amt);
    return (yang_amt,);
}

@view
func preview_exit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address, yang_amt: wad
) -> (preview: ufelt) {
    let (gate: address) = get_gate_address(yang);

    with_attr error_message("Sentinel: Yang {yang} is not approved") {
        assert_not_zero(gate);
    }

    let asset_amt: ufelt = IGate.preview_exit(gate, yang_amt);
    return (asset_amt,);
}

//
// External functions
//

@external
func add_yang{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, yang_max: wad, yang_threshold: ray, yang_price: wad, gate: address) {
    AccessControl.assert_has_role(SentinelRoles.ADD_YANG);

    with_attr error_message("Sentinel: Address cannot be zero") {
        assert_not_zero(yang);
        assert_not_zero(gate);
    }

    with_attr error_message("Sentinel: Yang already added") {
        let (stored_address: address) = sentinel_yang_to_gate.read(yang);
        assert stored_address = 0;
    }

    with_attr error_message("Sentinel: Yang address does not match Gate's asset") {
        let (asset: address) = IGate.get_asset(gate);
        assert yang = asset;
    }

    let (yang_addresses_count: ufelt) = sentinel_yang_addresses_count.read();
    sentinel_yang_addresses_count.write(yang_addresses_count + 1);
    sentinel_yang_addresses.write(yang_addresses_count, yang);
    sentinel_yang_to_gate.write(yang, gate);

    let (shrine: address) = sentinel_shrine_address.read();
    IShrine.add_yang(shrine, yang, yang_max, yang_threshold, yang_price);

    YangAdded.emit(yang, gate);

    return ();
}

@external
func enter{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, user: address, trove_id: ufelt, asset_amt: ufelt) -> (yang_amt: wad) {
    AccessControl.assert_has_role(SentinelRoles.ENTER);

    let (gate: address) = get_gate_address(yang);

    with_attr error_message("Sentinel: Yang {yang} is not approved") {
        assert_not_zero(gate);
    }

    let yang_amt: wad = IGate.enter(gate, user, trove_id, asset_amt);
    return (yang_amt,);
}

@external
func exit{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, user: address, trove_id: ufelt, yang_amt: wad) -> (asset_amt: ufelt) {
    AccessControl.assert_has_role(SentinelRoles.EXIT);

    let (gate: address) = get_gate_address(yang);

    with_attr error_message("Sentinel: Yang {yang} is not approved") {
        assert_not_zero(gate);
    }

    let asset_amt: ufelt = IGate.exit(gate, user, trove_id, yang_amt);
    return (asset_amt,);
}

//
// Internal functions
//

func get_yang_addresses_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    count: ufelt, idx: ufelt, yangs: address*
) {
    if (count == idx) {
        return ();
    }
    let (yang: address) = sentinel_yang_addresses.read(idx);
    assert [yangs] = yang;
    return get_yang_addresses_loop(count, idx + 1, yangs + 1);
}
