%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import assert_not_zero
from starkware.starknet.common.syscalls import get_caller_address

from contracts.gate.interface import IGate
from contracts.sentinel.interface import ISentinel
from contracts.shrine.interface import IShrine

from contracts.lib.aliases import address, ufelt, wad
from contracts.lib.openzeppelin.security.reentrancyguard.library import ReentrancyGuard
from contracts.lib.types import Trove, Yang

//
// Events
//

@event
func TroveOpened(user: address, trove_id: ufelt) {
}

//
// Storage
//

// the address of the Shrine associated with this Abbot
@storage_var
func abbot_shrine_address() -> (shrine: address) {
}

@storage_var
func abbot_sentinel_address() -> (sentinel: address) {
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
}(shrine: address, sentinel: address) {
    abbot_shrine_address.write(shrine);
    abbot_sentinel_address.write(sentinel);
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
    forge_amount: wad, yangs_len: ufelt, yangs: address*, amounts_len: ufelt, amounts: ufelt*
) {
    alloc_locals;

    with_attr error_message("Abbot: Input arguments mismatch: {yangs_len} != {amounts_len}") {
        assert yangs_len = amounts_len;
    }

    with_attr error_message("Abbot: No yangs selected") {
        assert_not_zero(yangs_len);
    }

    let (sentinel: address) = abbot_sentinel_address.read();
    assert_valid_yangs(sentinel, yangs_len, yangs);

    let (troves_count: ufelt) = abbot_troves_count.read();
    abbot_troves_count.write(troves_count + 1);

    let (user: address) = get_caller_address();
    let (user_troves_count: ufelt) = abbot_user_troves_count.read(user);
    abbot_user_troves_count.write(user, user_troves_count + 1);

    let new_trove_id: ufelt = troves_count + 1;
    abbot_user_troves.write(user, user_troves_count, new_trove_id);
    abbot_trove_owner.write(new_trove_id, user);

    let (shrine: address) = abbot_shrine_address.read();
    do_deposits(shrine, sentinel, user, new_trove_id, yangs_len, yangs, amounts);
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
    let (_, _, _, outstanding_debt: wad) = IShrine.get_trove_info(shrine, trove_id);
    IShrine.melt(shrine, user, trove_id, outstanding_debt);

    let (sentinel: address) = abbot_sentinel_address.read();
    let (yang_addresses_count: ufelt) = ISentinel.get_yang_addresses_count(sentinel);
    do_withdrawals_full(shrine, sentinel, user, trove_id, 0, yang_addresses_count);

    // deliberately not emitting an event

    return ();
}

// Caller does not need to be trove owner
@external
func deposit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address, trove_id: ufelt, amount: ufelt
) {
    alloc_locals;

    with_attr error_message("Abbot: Yang address cannot be zero") {
        assert_not_zero(yang);
    }

    let (sentinel: address) = abbot_sentinel_address.read();
    let (shrine: address) = abbot_shrine_address.read();

    assert_valid_yang(sentinel, yang);

    let (user: address) = get_caller_address();

    do_deposit(shrine, sentinel, user, trove_id, yang, amount);

    return ();
}

@external
func withdraw{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address, trove_id: ufelt, amount: wad
) {
    alloc_locals;

    with_attr error_message("Abbot: Yang address cannot be zero") {
        assert_not_zero(yang);
    }

    let (sentinel: address) = abbot_sentinel_address.read();
    assert_valid_yang(sentinel, yang);

    // don't allow withdrawing from foreign troves
    let (user: address) = get_caller_address();
    assert_trove_owner(user, trove_id);

    let (shrine: address) = abbot_shrine_address.read();

    let (gate: address) = ISentinel.get_gate_address(sentinel, yang);

    ReentrancyGuard._start();
    IGate.exit(gate, user, trove_id, amount);
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

// Caller does not need to be trove owner
@external
func melt{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt, amount: wad
) {
    alloc_locals;

    let (user: address) = get_caller_address();
    let (shrine: address) = abbot_shrine_address.read();
    IShrine.melt(shrine, user, trove_id, amount);

    return ();
}

//
// Internal
//

func assert_trove_owner{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    user: address, trove_id: ufelt
) {
    let (real_owner: address) = abbot_trove_owner.read(trove_id);
    with_attr error_message("Abbot: Address {user} does not own trove ID {trove_id}") {
        assert user = real_owner;
    }
    return ();
}

func assert_valid_yangs{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    sentinel: address, yangs_len: ufelt, yangs: address*
) {
    if (yangs_len == 0) {
        return ();
    }
    assert_valid_yang(sentinel, [yangs]);
    return assert_valid_yangs(sentinel, yangs_len - 1, yangs + 1);
}

func assert_valid_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    sentinel: address, yang: address
) {
    with_attr error_message("Abbot: Yang {yang} is not approved") {
        let (gate: address) = ISentinel.get_gate_address(sentinel, yang);
        assert_not_zero(gate);
    }
    return ();
}

// loop through all the yangs and their respective amounts that need to be deposited
// and call the appropriate Gate's `deposit` function
func do_deposits{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine: address,
    sentinel: address,
    user: address,
    trove_id: ufelt,
    deposits_count: ufelt,
    yangs: address*,
    amounts: ufelt*,
) {
    if (deposits_count == 0) {
        return ();
    }
    do_deposit(shrine, sentinel, user, trove_id, [yangs], [amounts]);
    return do_deposits(
        shrine, sentinel, user, trove_id, deposits_count - 1, yangs + 1, amounts + 1
    );
}

func do_deposit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine: address, sentinel: address, user: address, trove_id: ufelt, yang: address, amount: ufelt
) {
    alloc_locals;

    let (gate: address) = ISentinel.get_gate_address(sentinel, yang);

    ReentrancyGuard._start();
    let yang_amount: wad = IGate.enter(gate, user, trove_id, amount);
    IShrine.deposit(shrine, yang, trove_id, yang_amount);
    ReentrancyGuard._end();

    return ();
}

// loop through all the yangs of a trove and withdraw full yang amount
// deposited into the trove
func do_withdrawals_full{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine: address,
    sentinel: address,
    user: address,
    trove_id: ufelt,
    yang_idx: ufelt,
    yang_count: ufelt,
) {
    alloc_locals;

    if (yang_idx == yang_count) {
        return ();
    }

    let (yang: address) = ISentinel.get_yang(sentinel, yang_idx);

    let (yang_amount: wad) = IShrine.get_deposit(shrine, yang, trove_id);

    if (yang_amount == 0) {
        return do_withdrawals_full(shrine, sentinel, user, trove_id, yang_idx + 1, yang_count);
    } else {
        let (gate: address) = ISentinel.get_gate_address(sentinel, yang);
        let (shrine: address) = abbot_shrine_address.read();

        ReentrancyGuard._start();
        IGate.exit(gate, user, trove_id, yang_amount);
        IShrine.withdraw(shrine, yang, trove_id, yang_amount);
        ReentrancyGuard._end();

        return do_withdrawals_full(shrine, sentinel, user, trove_id, yang_idx + 1, yang_count);
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
