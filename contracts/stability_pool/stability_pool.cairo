%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.starknet.common.syscalls import get_contract_address, get_caller_address

from contracts.interfaces import IShrine

#############################################
##                STORAGE                  ##
#############################################

@storage_var
func shrine() -> (shrine : felt):
end

@storage_var
func balances(provider : felt) -> (balance : felt):
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
    let (curr_balance) = balances.read(caller)
    # TODO : payout here ...
    # transfer yin from caller to the stability pool
    IShrine.move_yin(contract_address=shrine_address, src_address=caller, dst_address=this, amount=amount)
    # update balance
    balances.write(caller, curr_balance + amount)
    # emit event
    Provided.emit(caller, amount)
    return ()
end

# Allows user to withdraw his share of collaterals and synth.
#
# * before *
# - re-entrancy check
# - user's balance on pool needs to >= amount
# * after *
# - sends a proportionate share of the seized collaterals to user
# - sends leftover synth. balance of the user
# - zero out balances of user
func withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(amount: felt):
    return ()
end

# Liquidates a trove ;
#    - burns an amount of the asset held by the pool equivalent to the trove's debt
#    - seizes collaterals
#
# * before *
# - re-entrancy check
# - trove id exists
# - SP has a balance >= trove's debt
# * after *
# - proper amount of the asset burned
# - collaterals seized
func liquidate{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(trove_id: felt):
    return ()
end

#############################################
##                GETTERS                  ##
#############################################

# Returns the amounts of collaterals the provider is owed.
# func get_provider_owed_collaterals{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(provider: felt) -> (collaterals_len : felt, collaterals : felt*):
#     return ()
# end

# Returns the amount of the synthetic asset the provider is owed.
func get_provider_owed_asset{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(provider: felt) -> (asset : felt):
    return (0)
end