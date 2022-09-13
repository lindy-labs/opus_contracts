%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_contract_address, get_caller_address
from starkware.cairo.common.math import assert_lt

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

@storage_var
func total_deposits() -> (balance : wad) {
}

// Tracks the users' deposits.
@storage_var
func deposits(provider : felt) -> (balance : wad) {
}

// errors tracking
@storage_var
func last_yin_loss_offset() -> (error : felt) {
}

@storage_var
func last_yang_loss_offset(yang : address) -> (error : felt) {
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

// Allows the user to provide yin and make a deposit.
// Requires the user to approve absorber spending.
//
// Parameters
// * amount : amount of yin to deposit
@external
func provide{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(amount: wad) {
    alloc_locals;
    let (yin_address : address) = yin.read();
    let (this : address) = get_contract_address();
    let (local caller : address) = get_caller_address();
    let (current_deposit : wad) = deposits.read(caller);

    // Pre-payout snippet
    let (abbot_address : address) = abbot.read();
    let (yangs_len : felt, yangs : address*) = IAbbot.get_yang_addresses(contract_address=abbot_address);
    let (owed : felt*) = alloc();
    _get_provider_owed_yangs(caller, current_deposit, yangs_len, yangs, yangs_len, owed);

    let (compounded_deposit : wad) = get_provider_owed_yin(caller);

    // transfer yin from caller to the absorber
    IYin.transferFrom(contract_address=yin_address, sender=caller, recipient=this, amount=amount);
    _increase_total_deposits(amount);

    // update deposit and snapshots
    let (new_deposit : wad) = WadRay.add_unsigned(current_deposit, amount);
    _update_deposit_and_snapshot(caller, new_deposit);

    // payout the owed yangs
    _distribute_owed_yangs(caller, yangs_len, yangs, yangs_len, owed);

    // emit event
    Provided.emit(caller, amount);
    return ();
}

// Allows user to withdraw his share of collaterals and deposit.
// It withdraws the entire compounded deposit.
@external
func withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() {
    alloc_locals;
    let (local caller) = get_caller_address();
    let (deposit : wad) = deposits.read(caller);
    // get owed yangs
    let (abbot_address : address) = abbot.read();
    let (len : felt, yangs : address*) = IAbbot.get_yang_addresses(contract_address=abbot_address);
    let (owed : felt*) = alloc();
    _get_provider_owed_yangs(caller, deposit, len, yangs, len, owed);
    // get compounded deposit
    let (compounded_deposit : wad) = get_provider_owed_yin(caller);
    // send deposit
    let (yin_address : address) = yin.read();
    IYin.transfer(contract_address=yin_address, recipient=caller, amount=compounded_deposit);
    _decrease_total_deposits(compounded_deposit);
    // update user's deposit
    _update_deposit_and_snapshot(caller, 0);

    _distribute_owed_yangs(caller, len, yangs, len, owed);
    return ();
}

// Allows user to withdraw his owed shares of yangs.
// It doesn't withdraw any % of the compounded deposit.
@external
func claim{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() {
    alloc_locals;
    let (local caller) = get_caller_address();
    let (abbot_ : address) = abbot.read();
    let (deposit : wad) = deposits.read(caller);

    // get yangs gains
    let (local len : felt, yangs : address*) = IAbbot.get_yang_addresses(contract_address=abbot_);
    let (owed : felt*) = alloc();
    _get_provider_owed_yangs(caller, deposit, len, yangs, len, owed);

    let (compounded_deposit : wad) = get_provider_owed_yin(caller);
    // update deposit
    _update_deposit_and_snapshot(caller, compounded_deposit);
    // send out yangs gains
    _distribute_owed_yangs(caller, len, yangs, len, owed);
    return ();
}

// Liquidates a unhealthy trove by paying off its bad debt and acquiring the collaterals.
//
// Parameters
// * trove_id : id of trove to liquidate
//
// Returns
// * absorbed : amount of debt that was absorbed
@external
func liquidate{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(trove_id: felt) -> (absorbed : wad) {
    alloc_locals;
    let (total_deposits_ : wad) = total_deposits.read();
    let (purger_address) = purger.read();
    let (amount : wad) = IPurger.get_max_close_amount(contract_address=purger_address, trove_id=trove_id);
    let (local to_absorb : felt) = WadRay.min(total_deposits_, amount);
    _purge_and_update(trove_id, to_absorb);
    return (to_absorb,);
}

/////////////////////////////////////////////
//                INTERNAL                 //
/////////////////////////////////////////////

// Updates the deposit and snapshot of a provider.
//
// Parameters
// * provider    : address of the provider
// * new_deposit : new amount of yin to store
func _update_deposit_and_snapshot{
    syscall_ptr : felt*,
    pedersen_ptr : HashBuiltin*,
    range_check_ptr
}(
    provider : address,
    new_deposit : wad
) {

    deposits.write(provider, new_deposit);
    // update P
    let (curr_P : felt) = P.read();
    snapshots.write(provider, Snapshot(P=curr_P));
    // update S
    _update_provider_S(provider);
    return ();
}

// Computes part of the equation of the running products and sums.
// 
// Parameters
// * to_absorb     : debt to absorb
// * yangs         : array of yangs' addresses
// * freed_amounts : array of amounts of yangs freed from liquidation
func _update_loss_and_rewards_units{
    syscall_ptr : felt*,
    pedersen_ptr : HashBuiltin*,
    range_check_ptr
}(
    to_absorb : wad,
    yangs_len : felt,
    yangs : address*,
    amounts_len : felt,
    freed_amounts : felt*,
) -> (yin_unit_loss : wad, len : felt, yangs_unit_gains : felt*) {
    alloc_locals;
    let (last_yin_loss_offset_ : felt) = last_yin_loss_offset.read();
    let (total_deposits_ : felt) = total_deposits.read();

    // What is called the yin loss per unit is actually a part of the running product equation.
    // In particular, it corresponds to Q_i / D_(i-1)
    let (local yin_loss_numerator : felt) = WadRay.wmul(to_absorb, WadRay.WAD_SCALE);
    let (yin_loss_numerator : felt) = WadRay.sub_unsigned(yin_loss_numerator, last_yin_loss_offset_);
    let (yin_loss_per_unit : felt) = WadRay.wunsigned_div(yin_loss_numerator, total_deposits_);
    let (yin_loss_per_unit : felt) = WadRay.add_unsigned(yin_loss_per_unit, 1);
    let (last_yin_loss_offset_ : felt) = WadRay.wmul(yin_loss_per_unit, total_deposits_);
    let (last_yin_loss_offset_ : felt) = WadRay.sub_unsigned(last_yin_loss_offset_, yin_loss_numerator);
    last_yin_loss_offset.write(last_yin_loss_offset_);

    let (yangs_unit_gains : felt*) = alloc();
    _update_yangs_unit_gains(total_deposits_, yangs_len, yangs, amounts_len, freed_amounts, yangs_len, yangs_unit_gains);

    return (yin_loss_per_unit, yangs_len, yangs_unit_gains);
}

// Computes the gain per unit for every yang and updates the error offset.
// The gains per unit are stored in the gains array passed to the function.
//
// Parameters
// * total_deposits_ : total deposits of yin held by the absorber
// * yangs           : array of the yangs' addresses
// * freed_amounts   : array of yangs amounts freed from the trove
// * gains           : array of the yangs' gains per unit
func _update_yangs_unit_gains{
    syscall_ptr : felt*,
    pedersen_ptr : HashBuiltin*,
    range_check_ptr
}(
    total_deposits_ : felt,
    yangs_len : felt,
    yangs : address*,
    amounts_len : felt,
    freed_amounts : felt*,
    gains_len : felt,
    gains : felt*
) {
    if (yangs_len == 0) {
        return ();
    }
    let (last_yang_loss_offset_ : felt) = last_yang_loss_offset.read([yangs]);
    let (yang_numerator : felt) = WadRay.wmul([freed_amounts], WadRay.WAD_SCALE);
    let (yang_numerator : felt) = WadRay.add_unsigned(yang_numerator, last_yang_loss_offset_);
    let (yang_unit_gain : felt) = WadRay.wunsigned_div(yang_numerator, total_deposits_);
    let (last_yang_loss_offset_ : felt) = WadRay.sub_unsigned(yang_numerator, yang_unit_gain);
    let (last_yang_loss_offset_ : felt) = WadRay.wmul(last_yang_loss_offset_, total_deposits_);
    last_yang_loss_offset.write([yangs], last_yang_loss_offset_);
    [gains] = yang_unit_gain; //write yang unit gain to array

    return _update_yangs_unit_gains(total_deposits_, yangs_len-1, yangs+1, amounts_len-1, freed_amounts+1, gains_len-1, gains+1);
}


// Purges (liquidates) a unhealthy trove and update the running sums and products.
//
// Parameters
// * trove_id : the id of the trove to liquidate
// * to_absorb : the trove's bad debt to absorb
func _purge_and_update{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(trove_id : felt, to_absorb: wad) {
    alloc_locals;
    let (this : felt) = get_contract_address();
    let (shrine_address : felt) = shrine.read();
    let (purger_address : felt) = purger.read();
    let (curr_P : felt) = P.read();
    let (this_balance) = total_deposits.read();
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
        purge_amt_wad=to_absorb,
        recipient_address=this
    );
    assert yangs_len = freed_len;
    let (
        yin_loss_per_unit : felt,
        gains_len : felt,
        yangs_unit_gains : felt*
    ) = _update_loss_and_rewards_units(to_absorb, yangs_len, yangs, freed_len, freed_amounts);

    // updates all S
    _update_all_S(this_balance, curr_P, yangs_len, yangs, gains_len, yangs_unit_gains);

    let (new_P : felt) = WadRay.sub_unsigned(WadRay.WAD_ONE, yin_loss_per_unit);
    let (new_P : felt) = WadRay.wmul(new_P, curr_P);
    let (new_P : felt) = WadRay.wunsigned_div(new_P, WadRay.WAD_SCALE);

    P.write(new_P);
    _decrease_total_deposits(to_absorb);

    return ();
}

// Updates all the S (for every yang) for a given user.
//
// Parameters
// * provider : address of the provider
func _update_provider_S{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(provider : address) {
    let (abbot_address : address) = abbot.read();
    let (len : felt, yangs : address*) = IAbbot.get_yang_addresses(contract_address=abbot_address);
    _update_provider_single_S(provider, len, yangs);
    return ();
}

// Updates a single S of a given yang for a given user.
//
// Parameters
// * provider : address of the provider
// * yangs    : array of yangs' addresses
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

// Update all the running sum for each yang.
//
// Parameters
// * this_balance     : the total balance of yin held by the pool
// * curr_P           : the running product to help us calculate the compounded deposit
// * yangs            : array of the yangs' addresses
// * yangs_unit_gains : array of each yang gain per yin staked
func _update_all_S{
    syscall_ptr : felt*,
    pedersen_ptr : HashBuiltin*,
    range_check_ptr
}(
    this_balance : wad,
    curr_P : felt,
    yangs_len : felt,
    yangs : address*,
    gains_len : felt,
    yangs_unit_gains : felt*
) {
    if (yangs_len == 0) {
        return ();
    }
    
    let (curr_S : felt) = S.read([yangs]);
    let (margin_gain : felt) = WadRay.wmul(curr_P, [yangs_unit_gains]);
    let (new_S) = WadRay.add_unsigned(curr_S, margin_gain);
    S.write([yangs], new_S);
    return _update_all_S(this_balance, curr_P, yangs_len - 1, yangs + 1, gains_len - 1, yangs_unit_gains + 1);
}

// Transfers owed yangs to a provider.
//
// Parameters
// * provider : address of the provider
// * yangs    : array of yangs' addresses
// * owed     : array of owed yangs to send
func _distribute_owed_yangs{
    syscall_ptr : felt*,
    pedersen_ptr : HashBuiltin*,
    range_check_ptr
}(
    provider : address,
    yangs_len : felt,
    yangs : address*,
    owed_len : felt,
    owed : felt*
) {
    if (yangs_len == 0) {
        return ();
    }

    IERC20.transfer(contract_address=[yangs], recipient=provider, amount=Uint256([owed], 0));
    return _distribute_owed_yangs(provider, yangs_len - 1, yangs + 1, owed_len - 1, owed + 1);
}

// Increases the total deposits by the given amount.
//
// Parameters
// * amount : amount to increase total deposits by
func _increase_total_deposits{
    syscall_ptr : felt*,
    pedersen_ptr : HashBuiltin*,
    range_check_ptr
}(
    amount : wad
) {
    let (tdeposits : wad) = total_deposits.read();
    let (new_total_deposits : wad) = WadRay.add_unsigned(tdeposits, amount);
    total_deposits.write(new_total_deposits);
    return ();
}

// Decreases the total deposits by the given amount.
//
// Parameters
// * amount : amount to decrease total deposits by
func _decrease_total_deposits{
    syscall_ptr : felt*,
    pedersen_ptr : HashBuiltin*,
    range_check_ptr
}(
    amount : wad
) {
    let (tdeposits : wad) = total_deposits.read();
    let (new_total_deposits : wad) = WadRay.sub_unsigned(tdeposits, amount);
    total_deposits.write(new_total_deposits);
    return ();
}

// Sets an array with the amounts of yangs a provider is owed.
// It does NOT return a new array but relies on an empty array passed as a parameter.
//
// Parameters
// * provider : address of the provider
// * deposit  : deposit of the provider (yin)
// * yangs    : array of the yangs' addresses
// * owed     : array of the amounts of yangs the provider is owed
func _get_provider_owed_yangs{
    syscall_ptr : felt*,
    pedersen_ptr : HashBuiltin*,
    range_check_ptr
}(
    provider : address,
    deposit : wad,
    yangs_len : felt,
    yangs : address*,
    gains_len : felt,
    gains : felt*
) {
    if (yangs_len == 0) {
        return ();
    }

    if (deposit == 0) {
        assert [gains] = 0;
        return _get_provider_owed_yangs(provider, deposit, yangs_len - 1, yangs + 1, gains_len - 1, gains + 1);
    }

    let (snapshot_S : felt) = snapshots_S.read(provider, [yangs]);
    let (curr_S : felt) = S.read([yangs]);
    let (snapshot : Snapshot) = snapshots.read(provider);
    let (S_delta : felt) = WadRay.sub_unsigned(curr_S, snapshot_S);
    let (gain : felt) = WadRay.wmul(deposit, S_delta);
    let (gain : felt) = WadRay.wunsigned_div(gain, snapshot.P);
    let (gain : felt) = WadRay.wunsigned_div(gain, WadRay.WAD_SCALE);
    assert [gains] = gain;
    return _get_provider_owed_yangs(provider, deposit, yangs_len - 1, yangs + 1, gains_len - 1, gains + 1);

}

/////////////////////////////////////////////
//                GETTERS                  //
/////////////////////////////////////////////

// Returns the amount of the synthetic asset the provider is owed.
//
// Parameters
// * provider : the address of the provider
//
// Returns
// * yin : the compounded deposit of the provider
@view
func get_provider_owed_yin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(provider: address) -> (yin : wad) {
    let (initial_deposit : wad) = deposits.read(provider);
    if (initial_deposit == 0) {
        return (yin=0,);
    }
    let (curr_P : felt) = P.read();
    let (snapshot : Snapshot) = snapshots.read(provider);
    let (P_ratio : felt) = WadRay.wunsigned_div(curr_P, snapshot.P);
    let (compounded_deposit : wad) = WadRay.wmul(initial_deposit, P_ratio);
    return (compounded_deposit,);
}

// Returns the amounts of yangs a given provider (user) can claim.
//
// Parameters
// * provider : the address of the provider 
//
// Returns
// * gains : Array of amounts of claimable yangs
@view
func get_provider_owed_yangs{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(provider : address) -> (owed_len : felt, owed : felt*) {
    alloc_locals;
    let (deposit : wad) = deposits.read(provider);
    let (abbot_ : address) = abbot.read();
    let (local len : felt, yangs : address*) = IAbbot.get_yang_addresses(contract_address=abbot_);
    let (owed : felt*) = alloc();
    _get_provider_owed_yangs(provider, deposit, len, yangs, len, owed);
    return (len, owed);
}