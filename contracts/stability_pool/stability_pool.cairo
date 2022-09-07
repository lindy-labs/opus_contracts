%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_contract_address, get_caller_address

from contracts.interfaces import IShrine, IYin, IPurger, IAbbot
from contracts.shared.wad_ray import WadRay
from contracts.shared.types import Trove
from contracts.shared.interfaces import IERC20

/////////////////////////////////////////////
//                STRUCTS                  //
/////////////////////////////////////////////

struct Snapshot{
    P : felt,
}

/////////////////////////////////////////////
//                STORAGE                  //
/////////////////////////////////////////////

using wad = felt;
using address = felt;

// Holds the address at which the yin's Shrine is deployed.
@storage_var
func yin() -> (yin : address) {
}

@storage_var
func shrine() -> (shrine : address) {
}

@storage_var
func purger() -> (purger: address) {
}

@storage_var
func abbot() -> (abbot: address) {
}

// P is ... P
@storage_var
func P() -> (P : felt) {
}

@storage_var
func S(yang : address) -> (S : felt) {
}

// Mapping user => snapshot (of their deposit).
@storage_var
func snapshots(provider : address) -> (snapshot : Snapshot) {
}

@storage_var
func snapshots_S(provider : address, yang : address) -> (S : felt) {
}

// Tracks the users' deposits.
@storage_var
func deposits(provider : felt) -> (balance : wad) {
}

/////////////////////////////////////////////
//                EVENTS                   //
/////////////////////////////////////////////Ò

@event
func Provided(provider : felt, amount : wad) {
}

@event
func Withdrawed(provider : felt, amount : wad) {
}

@event
func Liquidated(trove_id : felt) {
}

/////////////////////////////////////////////
//                CONSTRUCTOR              //
/////////////////////////////////////////////

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    yin_address : felt,
    shrine_address : felt,
    purger_address : felt,
    abbot_address : felt
){
    yin.write(yin_address);
    shrine.write(shrine_address);
    purger.write(purger_address);
    abbot.write(abbot_address);
    IYin.approve(contract_address=yin_address, spender=purger_address, amount=2**125);
    P.write(10**18);
    return ();
}

/////////////////////////////////////////////
//                EXTERNAL                 //
/////////////////////////////////////////////

// Allows user to provide the synthetic asset allowed by the pool.
//
// * before *
// - user's balance of synth. needs to be >= amount
// * after *
// - credit user's balance on pool
@external
func provide{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(amount: wad) {
    alloc_locals;
    let (yin_address : address) = yin.read();
    let (this : address) = get_contract_address();
    let (local caller : address) = get_caller_address();
    //payout user before crediting deposit
    let (curr_balance) = deposits.read(caller);
    // TODO : payout here ...
    // transfer yin from caller to the stability pool
    IYin.transferFrom(contract_address=yin_address, sender=caller, recipient=this, amount=amount);
    // update balance
    deposits.write(caller, curr_balance + amount);
    // update snapshot
    let (curr_P) = P.read();
    snapshots.write(caller, Snapshot(P=curr_P));
    // update all S
    _update_provider_S(caller);
    // emit event
    Provided.emit(caller, amount);
    return ();
}

// Allows user to withdraw his share of collaterals and synth.
//
// * before *
// - re-entrancy check ?
// - user's balance on pool needs to >= amount
// * after *
// - s}s a proportionate share of the seized collaterals to user
// - s}s leftover synth. balance of the user
// - zero out deposits of user
@external
func withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() {
    alloc_locals;
    let (local caller) = get_caller_address();
    // get compounded deposit
    let (compounded_deposit : wad) = get_provider_owed_yin(caller);
    // send deposit
    let (yin_address : address) = yin.read();

    let (this) = get_contract_address();
    let (b) = IYin.balanceOf(contract_address=yin_address, account=this);
    %{
        print(f"Current balance is : {ids.b}")
        print(f"Trying to transfer : {ids.compounded_deposit}")
    %}
    
    IYin.transfer(contract_address=yin_address, recipient=caller, amount=compounded_deposit);
    // send owed yangs
    let (abbot_address : address) = abbot.read();
    let (len : felt, yangs : address*) = IAbbot.get_yang_addresses(contract_address=abbot_address);
    _distribute_owed_yang(caller, len, yangs);
    // update user's deposit
    deposits.write(caller, 0);
    return ();
}

// Liquidates a trove ;
//    - burns an amount of the asset held by the pool equivalent to the trove's debt
//    - seizes collaterals
//
// * before *
// - re-entrancy check ?
// - trove id exists
// - SP has a balance >= trove's debt
// * after *
// - proper amount of the asset burned
// - collaterals seized
@external
func liquidate{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(trove_id: felt) {
    let (purger_address) = purger.read();
    let (amount : wad) = IPurger.get_max_close_amount(contract_address=purger_address, trove_id=trove_id);
    _purge_and_update(trove_id, amount);
    return ();
}

/////////////////////////////////////////////
//                INTERNAL                 //
/////////////////////////////////////////////

// Update the "internal" storage variables of the pool.
// - Purges the trove
// - Updates P, the running product to help us calculate the compounded deposit
// - The total balance of yin held by the pool
func _purge_and_update{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(trove_id : felt, amount: wad) {
    alloc_locals;
    let (this : felt) = get_contract_address();
    let (shrine_address : felt) = shrine.read();
    let (purger_address : felt) = purger.read();
    let (curr_P : felt) = P.read();
    // amount / total_balance
    let (local this_balance : wad) = IShrine.get_yin(contract_address=shrine_address, user_address=this);
    // burn Yin
    // Spending approval already done in constructor
    let (
        yangs_len : felt,
        yangs : address*,
        freed_len : felt,
        freed_amounts : felt*
    ) = IPurger.purge(
        contract_address=purger_address,
        trove_id=trove_id,
        purge_amt_wad=amount,
        recipient_address=this
    );
    assert yangs_len = freed_len;
    // updates all S
    _update_all_S(this_balance, curr_P, yangs_len, yangs, freed_len, freed_amounts);
    let (new_P : felt) = WadRay.wunsigned_div(amount, this_balance);
    tempvar one = WadRay.WAD_ONE;
    // 1 - (amount / total_balance)
    let new_P = one - new_P;
    let (new_P) = WadRay.wmul(curr_P, new_P);
    P.write(new_P);
    return ();
}

// Updates all the S (for every yang) for a given user.
func _update_provider_S{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(provider : address) {
    let (abbot_address : address) = abbot.read();
    let (len : felt, yangs : address*) = IAbbot.get_yang_addresses(contract_address=abbot_address);
    _update_provider_single_S(provider, len, yangs);
    return ();
}

// Updates a single S of a given yang for a given user.
func _update_provider_single_S{
    syscall_ptr : felt*,
    pedersen_ptr : HashBuiltin*,
    range_check_ptr
}(
    provider : address,
    len : felt,
    yangs : address*
) {
    if (len == 0) {
        return ();
    }
    let (curr_S : felt) = S.read([yangs]);
    snapshots_S.write(provider, [yangs], curr_S);
    return _update_provider_single_S(provider, len - 1, yangs + 1);
}

// Update all the running sums.
func _update_all_S{
    syscall_ptr : felt*,
    pedersen_ptr : HashBuiltin*,
    range_check_ptr
}(
    this_balance : wad,
    curr_P : felt,
    yangs_len : felt,
    yangs : address*,
    freed_len : felt,
    freed_amounts : felt*
) {
    if (yangs_len == 0) {
        return ();
    }
    _update_single_S(this_balance, curr_P, [yangs], [freed_amounts]);
    return _update_all_S(this_balance, curr_P, yangs_len - 1, yangs + 1, freed_len - 1, freed_amounts + 1);
}

// Update the running sum of a single yang.
func _update_single_S{
    syscall_ptr : felt*,
    pedersen_ptr : HashBuiltin*,
    range_check_ptr
}(
    this_balance : wad,
    curr_P : felt,
    yang_address : address,
    freed_amount : felt
) {
    let (curr_S : felt) = S.read(yang_address);
    let (ratio : felt) = WadRay.wunsigned_div(freed_amount, this_balance);
    let (prod : felt) = WadRay.wmul(curr_P, ratio);
    let (new_S : felt) = WadRay.add_unsigned(curr_S, prod);
    S.write(yang_address, new_S);
    return ();
}

func _distribute_owed_yang{
    syscall_ptr : felt*,
    pedersen_ptr : HashBuiltin*,
    range_check_ptr
}(
    provider : address,
    len : felt,
    yangs : address*
) {
    if (len == 0) {
        return ();
    }
    let (owed : wad) = get_provider_owed_yang(provider, [yangs]);
    IERC20.transfer(contract_address=[yangs], recipient=provider, amount=Uint256(owed, 0));
    return _distribute_owed_yang(provider, len - 1, yangs + 1);
}

/////////////////////////////////////////////
//                GETTERS                  //
/////////////////////////////////////////////

//Returns the amounts of collaterals the provider is owed.
func get_provider_owed_yang{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(provider: felt, yang : address) -> (amount : wad){
    let (initial_deposit : wad) = deposits.read(provider);
    let (snapshot : Snapshot) = snapshots.read(provider);
    let (provider_S : felt) = snapshots_S.read(provider, yang);
    let (curr_S : felt) = S.read(yang);
    let (S_delta : felt) = WadRay.sub_unsigned(curr_S, provider_S);
    let (ratio : felt) = WadRay.wunsigned_div(S_delta, snapshot.P);
    let (amount : wad) = WadRay.wmul(initial_deposit, ratio);
    return (amount,);
}

// Returns the amount of the synthetic asset the provider is owed.
@view
func get_provider_owed_yin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(provider: felt) -> (yin : wad) {
    let (initial_deposit : wad) = deposits.read(provider);
    let (curr_P : felt) = P.read();
    let (snapshot : Snapshot) = snapshots.read(provider);
    let (P_ratio : felt) = WadRay.wunsigned_div(curr_P, snapshot.P);
    let (compounded_deposit : wad) = WadRay.wmul(initial_deposit, P_ratio);
    return (compounded_deposit,);
}