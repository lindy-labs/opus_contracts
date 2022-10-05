%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import assert_not_zero
from starkware.starknet.common.syscalls import get_caller_address

from contracts.abbot.roles import AbbotRoles
from contracts.gate.interface import IGate
from contracts.shrine.interface import IShrine

// these imported public functions are part of the contract's interface
from contracts.lib.accesscontrol.accesscontrol_external import (
    get_roles,
    has_role,
    get_admin,
    grant_role,
    revoke_role,
    renounce_role,
    change_admin,
)
from contracts.lib.accesscontrol.library import AccessControl
from contracts.lib.aliases import wad, ray, bool, address, ufelt
from contracts.lib.openzeppelin.security.reentrancyguard.library import ReentrancyGuard
from contracts.lib.types import Trove, Yang

//
// Events
//

@event
func TroveOpened(user: address, trove_id: ufelt) {
}

@event
func YangAdded(yang: address, gate: address) {
}

//
// Storage
//

// mapping between a yang address and our deployed Gate
@storage_var
func abbot_yang_to_gate(yang: address) -> (gate: address) {
}

// length of the abbot_yang_addresses array
@storage_var
func abbot_yang_addresses_count() -> (count: ufelt) {
}

// 0-based array of yang addresses added to the Shrine via this Abbot
@storage_var
func abbot_yang_addresses(idx) -> (address: felt) {
}

// the address of the Shrine associated with this Abbot
@storage_var
func abbot_shrine_address() -> (shrine: address) {
}

// total number of troves in Shrine; monotonically increasing
// also used to calculate the next ID (count+1) when opening a new trove
// in essence, it serves as an index / primary key in a SQL table
@storage_var
func abbot_troves_count() -> (count: ufelt) {
}

// the length of each individual user_address to trove mapping
// as stored in abbot_user_troves
//
// in python pseudocode:
//
// user_address = get_caller_address()
// user_troves_count = abbot_user_troves_count[user_address]
// for idx in range(user_troves_count):
//     user_trove_id = abbot_user_troves[user_address][idx]
@storage_var
func abbot_user_troves_count(user: address) -> (count: ufelt) {
}

// a mapping between a user address and an array of their trove IDs
// value at each key (user_address) is a 0-based append-only array
// of trove IDs belonging to the user
@storage_var
func abbot_user_troves(user: address, index: ufelt) -> (trove_id: ufelt) {
}

// a mapping between a trove ID and the address that owns it
@storage_var
func abbot_trove_owner(trove_id: ufelt) -> (owner: address) {
}

//
// Constructor
//

@constructor
func constructor{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(admin: address, shrine: address) {
    AccessControl.initializer(admin);
    AccessControl._grant_role(AbbotRoles.ADD_YANG, admin);
    abbot_shrine_address.write(shrine);
    return ();
}

//
// Getters
//

@view
func get_trove_owner{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt
) -> (owner: address) {
    return abbot_trove_owner.read(trove_id);
}

@view
func get_user_trove_ids{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    user: address
) -> (trove_ids_len: ufelt, trove_ids: ufelt*) {
    alloc_locals;
    let (count: ufelt) = abbot_user_troves_count.read(user);
    let (ids: ufelt*) = alloc();
    get_user_trove_ids_loop(user, count, 0, ids);
    return (count, ids);
}

@view
func get_gate_address{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address
) -> (gate: address) {
    return abbot_yang_to_gate.read(yang);
}

@view
func get_yang_addresses{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    addresses_len: ufelt, addresses: address*
) {
    alloc_locals;
    let (count: ufelt) = abbot_yang_addresses_count.read();
    let (addresses: address*) = alloc();
    get_yang_addresses_loop(count, 0, addresses);
    return (count, addresses);
}

@view
func get_troves_count{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    count: ufelt
) {
    return abbot_troves_count.read();
}

// TODO: getters for all(?) @storage_vars

//
// External
//

// create a new trove
@external
func open_trove{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    forge_amount: wad, yangs_len: ufelt, yangs: address*, amounts_len: ufelt, amounts: wad*
) {
    alloc_locals;

    with_attr error_message("Abbot: input arguments mismatch: {yangs_len} != {amounts_len}") {
        assert yangs_len = amounts_len;
    }

    with_attr error_message("Abbot: no yangs selected") {
        assert_not_zero(yangs_len);
    }

    assert_valid_yangs(yangs_len, yangs);

    let (troves_count: ufelt) = abbot_troves_count.read();
    abbot_troves_count.write(troves_count + 1);

    let (user: address) = get_caller_address();
    let (user_troves_count: ufelt) = abbot_user_troves_count.read(user);
    abbot_user_troves_count.write(user, user_troves_count + 1);

    let new_trove_id: ufelt = troves_count + 1;
    abbot_user_troves.write(user, user_troves_count, new_trove_id);
    abbot_trove_owner.write(new_trove_id, user);

    let (shrine: address) = abbot_shrine_address.read();
    do_deposits(user, new_trove_id, yangs_len, yangs, amounts);
    IShrine.forge(shrine, user, new_trove_id, forge_amount);

    TroveOpened.emit(user, new_trove_id);

    return ();
}

// closes a trove, repaying its debt in full and withdrawing all the Yangs
@external
func close_trove{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(trove_id) {
    alloc_locals;

    // don't allow manipulation of foreign troves
    let (user: address) = get_caller_address();
    assert_trove_owner(user, trove_id);

    let (shrine: address) = abbot_shrine_address.read();
    let (outstanding_debt: wad) = IShrine.estimate(shrine, trove_id);

    IShrine.melt(shrine, user, trove_id, outstanding_debt);
    let (yang_addresses_count: ufelt) = abbot_yang_addresses_count.read();
    do_withdrawals_full(shrine, user, trove_id, 0, yang_addresses_count);

    // deliberately not emitting an event

    return ();
}

@external
func deposit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address, trove_id: ufelt, amount: wad
) {
    alloc_locals;

    with_attr error_message("Abbot: yang address cannot be zero") {
        assert_not_zero(yang);
    }

    assert_valid_yang(yang);

    // don't allow depositing to foreign troves
    let (user: address) = get_caller_address();
    assert_trove_owner(user, trove_id);

    do_deposit(user, trove_id, yang, amount);

    return ();
}

@external
func withdraw{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address, trove_id: ufelt, amount: ufelt
) {
    alloc_locals;

    with_attr error_message("Abbot: yang address cannot be zero") {
        assert_not_zero(yang);
    }

    assert_valid_yang(yang);

    // don't allow withdrawing from foreign troves
    let (user: address) = get_caller_address();
    assert_trove_owner(user, trove_id);

    let (shrine: address) = abbot_shrine_address.read();
    let (gate: address) = abbot_yang_to_gate.read(yang);

    ReentrancyGuard._start();
    IGate.withdraw(gate, user, trove_id, amount);
    IShrine.withdraw(shrine, yang, trove_id, amount);
    ReentrancyGuard._end();

    return ();
}

@external
func forge{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt, amount: wad
) {
    alloc_locals;

    let (user: address) = get_caller_address();
    assert_trove_owner(user, trove_id);

    let (shrine: address) = abbot_shrine_address.read();
    IShrine.forge(shrine, user, trove_id, amount);

    return ();
}

@external
func melt{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt, amount: wad
) {
    alloc_locals;

    let (user: address) = get_caller_address();
    assert_trove_owner(user, trove_id);

    let (shrine: address) = abbot_shrine_address.read();
    IShrine.melt(shrine, user, trove_id, amount);

    return ();
}

@external
func add_yang{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, yang_max: wad, yang_threshold: ray, yang_price: wad, gate: address) {
    AccessControl.assert_has_role(AbbotRoles.ADD_YANG);

    with_attr error_message("Abbot: address cannot be zero") {
        assert_not_zero(yang);
        assert_not_zero(gate);
    }

    with_attr error_message("Abbot: yang already added") {
        let (stored_address: address) = abbot_yang_to_gate.read(yang);
        assert stored_address = 0;
    }

    with_attr error_message("Abbot: yang address does not match Gate's asset") {
        let (asset: address) = IGate.get_asset(gate);
        assert yang = asset;
    }

    let (yang_addresses_count: ufelt) = abbot_yang_addresses_count.read();
    abbot_yang_addresses_count.write(yang_addresses_count + 1);
    abbot_yang_addresses.write(yang_addresses_count, yang);
    abbot_yang_to_gate.write(yang, gate);

    let (shrine: address) = abbot_shrine_address.read();
    IShrine.add_yang(shrine, yang, yang_max, yang_threshold, yang_price);

    YangAdded.emit(yang, gate);

    return ();
}

//
// Internal
//

func assert_trove_owner{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    user: address, trove_id: ufelt
) {
    let (real_owner: address) = abbot_trove_owner.read(trove_id);
    with_attr error_message("Abbot: address {user} does not own trove ID {trove_id}") {
        assert user = real_owner;
    }
    return ();
}

func assert_valid_yangs{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yangs_len: ufelt, yangs: address*
) {
    if (yangs_len == 0) {
        return ();
    }
    assert_valid_yang([yangs]);
    return assert_valid_yangs(yangs_len - 1, yangs + 1);
}

func assert_valid_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address
) {
    with_attr error_message("Abbot: yang {yang} is not approved") {
        let (gate: address) = abbot_yang_to_gate.read(yang);
        assert_not_zero(gate);
    }
    return ();
}

func get_yang_addresses_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    count: ufelt, idx: ufelt, yangs: address*
) {
    if (count == idx) {
        return ();
    }
    let (yang: address) = abbot_yang_addresses.read(idx);
    assert [yangs] = yang;
    return get_yang_addresses_loop(count, idx + 1, yangs + 1);
}

// loop through all the yangs and their respective amounts that need to be deposited
// and call the appropriate Gate's `deposit` function
func do_deposits{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    user: address, trove_id: ufelt, deposits_count: ufelt, yangs: address*, amounts: wad*
) {
    if (deposits_count == 0) {
        return ();
    }
    do_deposit(user, trove_id, [yangs], [amounts]);
    return do_deposits(user, trove_id, deposits_count - 1, yangs + 1, amounts + 1);
}

func do_deposit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    user: address, trove_id: ufelt, yang: address, amount: wad
) {
    alloc_locals;

    let (gate: address) = abbot_yang_to_gate.read(yang);

    let (shrine: address) = abbot_shrine_address.read();

    ReentrancyGuard._start();
    let yang_amount: wad = IGate.deposit(gate, user, trove_id, amount);
    IShrine.deposit(shrine, yang, trove_id, yang_amount);
    ReentrancyGuard._end();

    return ();
}

// loop through all the yangs of a trove and withdraw full yang amount
// deposited into the trove
func do_withdrawals_full{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine: address, user: address, trove_id: ufelt, yang_idx: ufelt, yang_count: ufelt
) {
    alloc_locals;

    if (yang_idx == yang_count) {
        return ();
    }

    let (yang: address) = abbot_yang_addresses.read(yang_idx);
    let (yang_amount: wad) = IShrine.get_deposit(shrine, yang, trove_id);

    if (yang_amount == 0) {
        return do_withdrawals_full(shrine, user, trove_id, yang_idx + 1, yang_count);
    } else {
        let (gate: address) = abbot_yang_to_gate.read(yang);
        let (shrine: address) = abbot_shrine_address.read();

        ReentrancyGuard._start();
        IGate.withdraw(gate, user, trove_id, yang_amount);
        IShrine.withdraw(shrine, yang, trove_id, yang_amount);
        ReentrancyGuard._end();

        return do_withdrawals_full(shrine, user, trove_id, yang_idx + 1, yang_count);
    }
}

func get_user_trove_ids_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    user: address, count: ufelt, idx: ufelt, ids: ufelt*
) {
    if (count == idx) {
        return ();
    }
    let (trove_id: ufelt) = abbot_user_troves.read(user, idx);
    assert [ids] = trove_id;
    return get_user_trove_ids_loop(user, count, idx + 1, ids + 1);
}
