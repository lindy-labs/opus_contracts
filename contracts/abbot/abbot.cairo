%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero
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

# mapping between a gage address and our deployed Gate
@storage_var
func abbot_yang_to_gate_storage(yang_address) -> (address):
end

# append-only array of yangs added to the system (Shrine)
# the value at index 0 is the length of the array
# since we only ever add yangs and never remove any,
# it works well for our purpose
@storage_var
func abbot_yang_addresses_storage(idx) -> (address):
end

# the address of the Shrine associated with this Abbot
@storage_var
func abbot_shrine_address_storage() -> (address):
end

# total number of troves in Shrine; monotonically increasing
# also used to calculate the next ID (count+1) when opening a new trove
# in essense, it serves as an index / primary key in a SQL table
@storage_var
func abbot_troves_count_storage() -> (ufelt):
end

# a mapping between user addresses and their trove IDs
# the value at each key (user_address) is na append-only array
# where the value at index 0 is the array length and the rest
# are the trove IDs
# in other words, the value at 0 (array length) is the number
# of troves a particular user has; because it's an append-only
# array, this value is monotonically increasing
#
#
# user_troves_count = abbot_trove_ids_storage[user_address][0]
# user_trove_id_1 = abbot_trove_ids_storage[user_address][1]
# assert 0 == abbot_trove_ids_storage[user_address][user_troves_count]
@storage_var
func abbot_trove_ids_storage(user_address, index) -> (ufelt):
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
    let (len) = abbot_trove_ids_storage.read(user_address, 0)
    let (ids : felt*) = alloc()
    get_user_trove_ids_internal(user_address, 1, ids)
    return (len, ids)
end

@view
func get_yang_addresses{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    addresses_len, addresses : felt*
):
    alloc_locals
    let (len) = abbot_yang_addresses_storage.read(0)
    let (addresses : felt*) = alloc()
    get_yang_addresses_loop(1, addresses)
    return (len, addresses)
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
    # TODO: test w/ forge_amount = 0
    alloc_locals

    with_attr error_message("Abbot: input arguments mismatch: {yang_addrs_len} != {amounts_len}"):
        assert yang_addrs_len = amounts_len
    end

    with_attr error_message("Abbot: no yangs selected"):
        assert_not_zero(yang_addrs_len)
    end

    let (user_address) = get_caller_address()

    let (user_troves_count) = abbot_trove_ids_storage.read(user_address, 0)
    abbot_trove_ids_storage.write(user_address, 0, user_troves_count + 1)

    let (troves_count) = abbot_troves_count_storage.read()
    let new_trove_id = troves_count + 1
    abbot_troves_count_storage.write(new_trove_id)
    abbot_trove_ids_storage.write(user_address, user_troves_count + 1, new_trove_id)

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

    let (user_address) = get_caller_address()
    let (shrine_address) = abbot_shrine_address_storage.read()

    with_attr error_message("Abbot: caller does not own trove ID {trove_id}"):
        assert_trove_owner(user_address, trove_id, 1)
    end

    # check if trove is healthy
    with_attr error_message("Abbot: trove {trove_id} is not healthy"):
        let (is_healthy) = IShrine.is_healthy(shrine_address, trove_id)
        assert is_healthy = TRUE
    end

    let (trove : Trove) = IShrine.get_trove(shrine_address, trove_id)
    let (outstanding_debt) = IShrine.estimate(shrine_address, trove_id)
    let total_debt = trove.debt + outstanding_debt

    IShrine.melt(shrine_address, total_debt, trove_id)
    do_withdrawals(shrine_address, user_address, trove_id, 1)

    # TODO: emit an event?

    return ()
end

@external
func deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    trove_id, yangs_addrs_len, yangs_addrs : felt*, amounts_len, amounts : felt*
):
    alloc_locals

    with_attr error_message("Abbot: input arguments mismatch: {yang_addrs_len} != {amounts_len}"):
        assert yangs_addrs_len = amounts_len
    end

    with_attr error_message("Abbot: no yangs selected"):
        assert_not_zero(yang_addrs_len)
    end

    let (user_address) = get_caller_address()

    # don't allow depositing to foreign troves
    with_attr error_message("Abbot: caller does not own trove ID {trove_id}"):
        assert_trove_owner(user_address, trove_id, 1)
    end

    do_deposits(user_address, trove_id, yangs_addrs_len, yangs_addrs, amounts)

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

    let (yang_count) = abbot_yang_addresses_storage.read(0)
    abbot_yang_to_gate_storage.write(yang_address, gate_address)
    abbot_yang_addresses_storage.write(0, yang_count + 1)
    abbot_yang_addresses_storage.write(yang_count + 1, yang_address)

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

    let (idx_trove_id) = abbot_trove_ids_storage.read(user_address, idx)
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

func get_yang_addresses_loop{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    idx, addresses : felt*
):
    # taking advantage of the 1-based append-only nature of
    # abbot_yang_addresses_storage - the first 0 value we
    # encounter marks the end of the array
    let (address_at_idx) = abbot_yang_addresses_storage.read(idx)
    if address_at_idx == 0:
        return ()
    end
    assert [addresses] = address_at_idx

    return get_yang_addresses_loop(idx + 1, addresses + 1)
end

# loop through all the yangs and their respective amounts that need to be deposited
# and call the appropriate Gate's `deposit` function
func do_deposits{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, deposits_count, yang_addresses : felt*, amounts : felt*
):
    if deposits_count == 0:
        return ()
    end

    let yang_address = [yang_addresses]
    let (gate_address) = abbot_yang_to_gate_storage.read(yang_address)
    with_attr error_message("Abbot: yang {yang_address} is not allowed"):
        assert_not_zero(gate_address)
    end
    IGate.deposit(gate_address, user_address, trove_id, [amounts])

    return do_deposits(user_address, trove_id, deposits_count - 1, yang_addresses + 1, amounts + 1)
end

# loop through all the yangs of a trove and withdraw full yang amount
# deposited into the trove
func do_withdrawals{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shrine_address, user_address, trove_id, yang_idx
):
    alloc_locals

    # taking advantage of the 1-based append-only nature of
    # abbot_yang_addresses_storage - the first 0 value we
    # encounter marks the end of the array
    let (yang_address) = abbot_yang_addresses_storage.read(yang_idx)
    if yang_address == 0:
        return ()
    end
    let (amount) = IShrine.get_deposit(shrine_address, trove_id, yang_address)

    if amount == 0:
        return do_withdrawals(shrine_address, user_address, trove_id, yang_idx + 1)
    else:
        let (gate_address) = abbot_yang_to_gate_storage.read(yang_address)
        IGate.redeem(gate_address, user_address, trove_id, amount)
        return do_withdrawals(shrine_address, user_address, trove_id, yang_idx + 1)
    end
end

func get_user_trove_ids_internal{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, idx, ids : felt*
):
    # taking advantage of the 1-based append-only nature of
    # abbot_trove_ids_storage - the first 0 value we encounter
    # marks the end of the array
    let (trove_id) = abbot_trove_ids_storage.read(user_address, idx)
    if trove_id == 0:
        return ()
    end
    assert [ids] = trove_id

    return get_user_trove_ids_internal(user_address, idx + 1, ids + 1)
end
