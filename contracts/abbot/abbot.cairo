%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero
from starkware.cairo.lang.compiler.lib.registers import get_fp_and_pc
from starkware.starknet.common.syscalls import get_caller_address

from contracts.interfaces import IGate, IShrine
from contracts.lib.auth import Auth
from contracts.shared.types import Trove, Yang

# these imported public functions are part of the contract's interface
from contracts.lib.auth_external import authorize, revoke, get_auth

#
# Constants
#

#
# Events
#

@event
func TroveOpened(user_address, trove_id):
end

@event
func YangAdded(yang_address, gate_address):
end

#
# Storage
#

# mapping between a yang address and our deployed Gate
@storage_var
func abbot_yang_to_gate_storage(yang_address) -> (address):
end

# length of the abbot_yang_addresses_storage array
@storage_var
func abbot_yang_addresses_count_storage() -> (ufelt):
end

# 0-based array of yang addresses added to the Shrine via this Abbot
@storage_var
func abbot_yang_addresses_storage(idx) -> (address):
end

# the address of the Shrine associated with this Abbot
@storage_var
func abbot_shrine_address_storage() -> (address):
end

# total number of troves in Shrine; monotonically increasing
# also used to calculate the next ID (count+1) when opening a new trove
# in essence, it serves as an index / primary key in a SQL table
@storage_var
func abbot_troves_count_storage() -> (ufelt):
end

# the length of each individual user_address to trove mapping
# as stored in abbot_user_troves_storage
#
# in python pseudocode:
#
# user_address = get_caller_address()
# user_troves_count = abbot_user_troves_count_storage[user_address]
# for idx in range(user_troves_count):
#     user_trove_id = abbot_user_troves_storage[user_address][idx]
@storage_var
func abbot_user_troves_count_storage(user_address) -> (ufelt):
end

# a mapping between a user address and an array of their trove IDs
# value at each key (user_address) is a 0-based append-only array
# of trove IDs belonging to the user
@storage_var
func abbot_user_troves_storage(user_address, index) -> (ufelt):
end

#
# Constructor
#

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shrine_address, authed
):
    Auth.authorize(authed)
    abbot_shrine_address_storage.write(shrine_address)
    return ()
end

#
# Getters
#

@view
func get_user_trove_ids{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address
) -> (trove_ids_len, trove_ids : felt*):
    alloc_locals
    let (count) = abbot_user_troves_count_storage.read(user_address)
    let (ids : felt*) = alloc()
    get_user_trove_ids_loop(user_address, count, 0, ids)
    return (count, ids)
end

@view
func get_yang_addresses{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    addresses_len, addresses : felt*
):
    alloc_locals
    let (count) = abbot_yang_addresses_count_storage.read()
    let (addresses : felt*) = alloc()
    get_yang_addresses_loop(count, 0, addresses)
    return (count, addresses)
end

@view
func get_troves_count{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    ufelt
):
    return abbot_troves_count_storage.read()
end

# TODO: getters for all(?) @storage_vars

#
# External
#

# create a new trove
@external
func open_trove{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    forge_amount, yang_addrs_len, yang_addrs : felt*, amounts_len, amounts : felt*
):
    alloc_locals

    with_attr error_message("Abbot: input arguments mismatch: {yang_addrs_len} != {amounts_len}"):
        assert yang_addrs_len = amounts_len
    end

    with_attr error_message("Abbot: no yangs selected"):
        assert_not_zero(yang_addrs_len)
    end

    assert_valid_yangs(yang_addrs_len, yang_addrs)

    let (troves_count) = abbot_troves_count_storage.read()
    abbot_troves_count_storage.write(troves_count + 1)

    let (user_address) = get_caller_address()
    let (user_troves_count) = abbot_user_troves_count_storage.read(user_address)
    abbot_user_troves_count_storage.write(user_address, user_troves_count + 1)

    let new_trove_id = troves_count + 1
    abbot_user_troves_storage.write(user_address, user_troves_count, new_trove_id)

    let (shrine_address) = abbot_shrine_address_storage.read()
    do_deposits(user_address, new_trove_id, yang_addrs_len, yang_addrs, amounts)
    IShrine.forge(shrine_address, forge_amount, new_trove_id)

    TroveOpened.emit(user_address, new_trove_id)

    return ()
end

# closes a trove, repaying its debt in full and withdrawing all the Yangs
@external
func close_trove{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(trove_id):
    alloc_locals

    # don't allow manipulation of foreign troves
    let (user_address) = get_caller_address()
    with_attr error_message("Abbot: caller does not own trove ID {trove_id}"):
        assert_trove_owner(user_address, trove_id, 0)
    end

    let (shrine_address) = abbot_shrine_address_storage.read()
    let (outstanding_debt) = IShrine.estimate(shrine_address, trove_id)

    IShrine.melt(shrine_address, outstanding_debt, trove_id)
    let (yang_addresses_count) = abbot_yang_addresses_count_storage.read()
    do_withdrawals_full(shrine_address, user_address, trove_id, 0, yang_addresses_count)

    # deliberately not emitting an event

    return ()
end

@external
func deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    trove_id, yang_address, amount
):
    alloc_locals
    let (__fp__, _) = get_fp_and_pc()

    with_attr error_message("Abbot: yang address cannot be zero"):
        assert_not_zero(yang_address)
    end

    assert_valid_yangs(1, &yang_address)

    # don't allow depositing to foreign troves
    let (user_address) = get_caller_address()
    with_attr error_message("Abbot: caller does not own trove ID {trove_id}"):
        assert_trove_owner(user_address, trove_id, 0)
    end

    do_deposits(user_address, trove_id, 1, &yang_address, &amount)

    return ()
end

@external
func withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    trove_id, yang_address, amount
):
    alloc_locals
    let (__fp__, _) = get_fp_and_pc()

    with_attr error_message("Abbot: yang address cannot be zero"):
        assert_not_zero(yang_address)
    end

    assert_valid_yangs(1, &yang_address)

    # don't allow withdrawing from foreign troves
    let (user_address) = get_caller_address()
    with_attr error_message("Abbot: caller does not own trove ID {trove_id}"):
        assert_trove_owner(user_address, trove_id, 0)
    end

    let (gate_address) = abbot_yang_to_gate_storage.read(yang_address)
    IGate.withdraw(gate_address, user_address, trove_id, amount)

    return ()
end

# TODO:
#   docs
#   funcs to support the UI

@external
func add_yang{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_address, yang_max, yang_threshold, yang_price, gate_address
):
    Auth.assert_caller_authed()

    with_attr error_message("Abbot: address cannot be zero"):
        assert_not_zero(yang_address)
        assert_not_zero(gate_address)
    end

    with_attr error_message("Abbot: yang already added"):
        let (stored_address) = abbot_yang_to_gate_storage.read(yang_address)
        assert stored_address = 0
    end

    let (yang_addresses_count) = abbot_yang_addresses_count_storage.read()
    abbot_yang_addresses_count_storage.write(yang_addresses_count + 1)
    abbot_yang_addresses_storage.write(yang_addresses_count, yang_address)
    abbot_yang_to_gate_storage.write(yang_address, gate_address)

    let (shrine_address) = abbot_shrine_address_storage.read()
    IShrine.add_yang(shrine_address, yang_address, yang_max, yang_threshold, yang_price)

    YangAdded.emit(yang_address, gate_address)

    return ()
end

#
# Internal
#

func assert_trove_owner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, idx
):
    alloc_locals

    let (idx_trove_id) = abbot_user_troves_storage.read(user_address, idx)
    if idx_trove_id == 0:
        # if the trove ID at index idx is 0, it means we reached
        # then end of the array without finding a user_address
        # match, hence they are not the owner and the func raises
        assert 1 = 0
    end

    if idx_trove_id == trove_id:
        # trove ID match, it belongs to the user, all good
        return ()
    end

    return assert_trove_owner(user_address, trove_id, idx + 1)
end

func assert_valid_yangs{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yang_addresses_len, yang_addresses : felt*
):
    alloc_locals

    if yang_addresses_len == 0:
        return ()
    end

    let yang_address = [yang_addresses]
    let (gate_address) = abbot_yang_to_gate_storage.read(yang_address)
    with_attr error_message("Abbot: yang {yang_address} is not approved"):
        assert_not_zero(gate_address)
    end

    return assert_valid_yangs(yang_addresses_len - 1, yang_addresses + 1)
end

func get_yang_addresses_loop{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    count, idx, addresses : felt*
):
    if count == idx:
        return ()
    end
    let (address) = abbot_yang_addresses_storage.read(idx)
    assert [addresses] = address
    return get_yang_addresses_loop(count, idx + 1, addresses + 1)
end

# loop through all the yangs and their respective amounts that need to be deposited
# and call the appropriate Gate's `deposit` function
func do_deposits{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, deposits_count, yang_addresses : felt*, amounts : felt*
):
    if deposits_count == 0:
        return ()
    end

    let (gate_address) = abbot_yang_to_gate_storage.read([yang_addresses])
    IGate.deposit(gate_address, user_address, trove_id, [amounts])

    return do_deposits(user_address, trove_id, deposits_count - 1, yang_addresses + 1, amounts + 1)
end

# loop through all the yangs of a trove and withdraw full yang amount
# deposited into the trove
func do_withdrawals_full{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shrine_address, user_address, trove_id, yang_idx, yang_count
):
    alloc_locals

    if yang_idx == yang_count:
        return ()
    end

    let (yang_address) = abbot_yang_addresses_storage.read(yang_idx)
    let (amount_wad) = IShrine.get_deposit(shrine_address, trove_id, yang_address)

    if amount_wad == 0:
        return do_withdrawals_full(shrine_address, user_address, trove_id, yang_idx + 1, yang_count)
    else:
        let (gate_address) = abbot_yang_to_gate_storage.read(yang_address)
        IGate.withdraw(gate_address, user_address, trove_id, amount_wad)
        return do_withdrawals_full(shrine_address, user_address, trove_id, yang_idx + 1, yang_count)
    end
end

func get_user_trove_ids_loop{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, count, idx, ids : felt*
):
    if count == idx:
        return ()
    end
    let (trove_id) = abbot_user_troves_storage.read(user_address, idx)
    assert [ids] = trove_id
    return get_user_trove_ids_loop(user_address, count, idx + 1, ids + 1)
end
