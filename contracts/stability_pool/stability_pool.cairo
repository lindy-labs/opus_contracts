%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.starknet.common.syscalls import get_contract_address, get_caller_address

from contracts.interfaces import IShrine, IYin
from contracts.shared.wad_ray import WadRay
from contracts.shared.types import Trove

@contract_interface
namespace IPurger {
    func purge(trove_id : felt, purge_amt_wad : felt, funder_address : felt, recipient_address : felt) {
    }
    func get_max_close_amount(trove_id : felt) -> (wad: felt) {
    }
}

/////////////////////////////////////////////
//                STRUCTS                  //
/////////////////////////////////////////////

struct Snapshot{
    P : felt,
}

/////////////////////////////////////////////
//                STORAGE                  //
/////////////////////////////////////////////

// Holds the address at which the yin's Shrine is deployed.
@storage_var
func yin() -> (yin : felt) {
}

@storage_var
func shrine() -> (shrine : felt) {
}

@storage_var
func purger() -> (purger: felt) {
}

// P is ... P
@storage_var
func P() -> (P : felt) {
}

// Mapping user => snapshot (of their deposit).
@storage_var
func snapshots(provider : felt) -> (snapshot : Snapshot) {
}

// Tracks the users' deposits.
@storage_var
func deposits(provider : felt) -> (balance : felt) {
}

/////////////////////////////////////////////
//                EVENTS                   //
/////////////////////////////////////////////Ò

@event
func Provided(provider : felt, amount : felt) {
}

@event
func Withdrawed(provider : felt, amount : felt) {
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
){
    yin.write(yin_address);
    shrine.write(shrine_address);
    purger.write(purger_address);
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
func provide{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(amount: felt) {
    let (yin_address) = yin.read();
    let (this) = get_contract_address();
    let (caller) = get_caller_address();
    //payout user before crediting deposit
    let (curr_balance) = deposits.read(caller);
    // TODO { payout here ...
    // transfer yin from caller to the stability pool
    IYin.transferFrom(contract_address=yin_address, sender=caller, recipient=this, amount=amount);
    // update balance
    deposits.write(caller, curr_balance + amount);
    // update snapshot
    let (curr_P) = P.read();
    snapshots.write(caller, Snapshot(P=curr_P));
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
func withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(amount: felt) {
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
    let (amount) = IPurger.get_max_close_amount(contract_address=purger_address, trove_id=trove_id);
    _update(trove_id, amount);
    return ();
}

/////////////////////////////////////////////
//                INTERNAL                 //
/////////////////////////////////////////////

// Update the "internal" storage variables of the pool.
// - Updates P, the running product to help us calculate the compounded deposit
// - The total balance of yin held by the pool
func _update{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(trove_id : felt, amount: felt) {
    let (this) = get_contract_address();
    let (shrine_address) = shrine.read();
    let (purger_address) = purger.read();
    let (curr_P) = P.read();
    // amount / total_balance
    let (this_balance) = IShrine.get_yin(contract_address=shrine_address, user_address=this);
    let (new_P) = WadRay.wunsigned_div(amount, this_balance);
    tempvar one = WadRay.WAD_ONE;
    // 1 - (amount / total_balance)
    new_P = one - new_P;
    let (new_P) = WadRay.wmul(curr_P, new_P);
    // burn Yin
    // Spending approval already done in constructor
    IPurger.purge(
        contract_address=-purger_address,
        trove_id=trove_id,
        purge_amt_wad=amount,
        funder_address=this,
        recipient_address=this
    );
    return ();
}

/////////////////////////////////////////////
//                GETTERS                  //
/////////////////////////////////////////////

// Returns the amounts of collaterals the provider is owed.
// func get_provider_owed_yangs{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(provider: felt) -> (yangs_len : felt, yangs : felt*){
//     return ()
// }

// Returns the amount of the synthetic asset the provider is owed.
@view
func get_provider_owed_yin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(provider: felt) -> (yin : felt) {
    let (initial_deposit) = deposits.read(provider);
    let (curr_P) = P.read();
    let (snapshot) = snapshots.read(provider);
    let (P_ratio) = WadRay.wunsigned_div(curr_P, snapshot.P);
    let (compounded_deposit) = WadRay.wmul(initial_deposit, P_ratio);
    return (compounded_deposit,);
}