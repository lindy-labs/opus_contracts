%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.starknet.common.syscalls import get_contract_address, get_caller_address

from contracts.interfaces import IShrine
from contracts.shared.wad_ray import WadRay
from contracts.shared.types import Trove

#############################################
##                STRUCTS                  ##
#############################################

struct Snapshot:
    member P : felt # can be moved to packed with other var
end

#############################################
##                STORAGE                  ##
#############################################

# Holds the address at which the yin's Shrine is deployed.
@storage_var
func shrine() -> (shrine : felt):
end

# P is ... P
@storage_var
func P() -> (P : felt):
end

# Mapping user => snapshot (of their deposit).
@storage_var
func snapshots(provider : felt) -> (snapshot : Snapshot):
end

# Tracks the users' deposits.
@storage_var
func deposits(provider : felt) -> (balance : felt):
end

# TODO ; remove by a call to Shrine?
@storage_var
func total_balance() -> (total_balance : felt):
end

#############################################
##                EVENTS                   ##
#############################################Ò

@event
func Provided(provider : felt, amount : felt):
end

@event
func Withdrawed(provider : felt, amount : felt):
end

@event
func Liquidated(trove_id : felt):
end

#############################################
##                CONSTRUCTOR              ##
#############################################

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shrine_address : felt
):
    shrine.write(shrine_address)
    P.write(10**18)
    return ()
end

#############################################
##                EXTERNAL                 ##
#############################################

# Allows user to provide the synthetic asset allowed by the pool.
#
# * before *
# - user's balance of synth. needs to be >= amount
# * after *
# - credit user's balance on pool
func provide{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(amount: felt):
    let (shrine_address) = shrine.read()
    let (this) = get_contract_address()
    let (caller) = get_caller_address()
    # payout user before crediting deposit
    let (curr_balance) = deposits.read(caller)
    # TODO : payout here ...
    # transfer yin from caller to the stability pool
    IShrine.move_yin(contract_address=shrine_address, src_address=caller, dst_address=this, amount=amount)
    # update balance
    deposits.write(caller, curr_balance + amount)
    let (curr_total_balance) = total_balance.read()
    total_balance.write(curr_total_balance + amount)
    # update snapshot
    let (curr_P) = P.read()
    snapshots.write(caller, Snapshot(P=curr_P))
    # emit event
    Provided.emit(caller, amount)
    return ()
end

# Allows user to withdraw his share of collaterals and synth.
#
# * before *
# - re-entrancy check ?
# - user's balance on pool needs to >= amount
# * after *
# - sends a proportionate share of the seized collaterals to user
# - sends leftover synth. balance of the user
# - zero out deposits of user
func withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(amount: felt):
    return ()
end

# Liquidates a trove ;
#    - burns an amount of the asset held by the pool equivalent to the trove's debt
#    - seizes collaterals
#
# * before *
# - re-entrancy check ?
# - trove id exists
# - SP has a balance >= trove's debt
# * after *
# - proper amount of the asset burned
# - collaterals seized
func liquidate{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(trove_id: felt):
    let (shrine_address) = shrine.read()
    # get amount of debt from trove
    let (trove : Trove) = IShrine.get_trove(contract_address=shrine_address, trove_id=trove_id)
    _update(trove.debt)
    return ()
end

#############################################
##                INTERNAL                 ##
#############################################

# Update the "internal" storage variables of the pool.
# - Updates P, the running product to help us calculate the compounded deposit
# - The total balance of yin held by the pool
func _update{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(amount: felt):
    let (curr_P) = P.read()
    # amount / total_balance
    let (curr_total_balance) = total_balance.read()
    let (new_P) = WadRay.wunsigned_div(amount, curr_total_balance)
    tempvar one = WadRay.WAD_ONE
    # 1 - (amount / total_balance)
    new_P = one - new_P
    let (new_P) = WadRay.wmul(curr_P, new_P)

    # update total_balance
    let (curr_total_balance) = total_balance.read()
    total_balance.write(curr_total_balance - amount)
    return ()
end

#############################################
##                GETTERS                  ##
#############################################

# Returns the amounts of collaterals the provider is owed.
# func get_provider_owed_yangs{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(provider: felt) -> (yangs_len : felt, yangs : felt*):
#     return ()
# end

# Returns the amount of the synthetic asset the provider is owed.
func get_provider_owed_yin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(provider: felt) -> (yin : felt):
    let (initial_deposit) = deposits.read(provider)
    let (curr_P) = P.read()
    let (snapshot) = snapshots.read(provider)
    let (P_ratio) = WadRay.wunsigned_div(curr_P, snapshot.P)
    let (compounded_deposit) = WadRay.wmul(initial_deposit, P_ratio)
    return (compounded_deposit)
end