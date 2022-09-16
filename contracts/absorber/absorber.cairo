%lang starknet


// Based of Liquity's implementation ; https://github.com/liquity/dev/blob/main/packages/contracts/contracts/StabilityPool.sol


from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_lt, assert_le, assert_not_zero
from starkware.cairo.common.math_cmp import is_not_zero, is_le
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_contract_address, get_caller_address

from contracts.interfaces import IShrine, IYin, IPurger, IAbbot
from contracts.shared.wad_ray import WadRay
from contracts.shared.types import Trove
from contracts.shared.interfaces import IERC20

/////////////////////////////////////////////
//                CONSTANTS                //
/////////////////////////////////////////////
const SCALE_FACTOR = 10**9;

/////////////////////////////////////////////
//                STRUCTS                  //
/////////////////////////////////////////////

struct Snapshot{
    P: felt,
    epoch: felt,
    scale: felt,
}

/////////////////////////////////////////////
//                STORAGE                  //
/////////////////////////////////////////////

using wad = felt;
using address = felt;

// Holds the address at which the yin's Shrine is deployed.
@storage_var
func yin() -> (yin: address) {
}

@storage_var
func shrine() -> (shrine: address) {
}

@storage_var
func purger() -> (purger: address) {
}

@storage_var
func abbot() -> (abbot: address) {
}

// P is the running product factor that weighs the deposit of a provider
// and is used for computing the compounded deposit, owed yangs and interests.
@storage_var
func P() -> (P: felt) {
}

@storage_var
func current_scale() -> (scale: felt) {
}

@storage_var
func current_epoch() -> (epoch: felt) {
}

// Mapping user => snapshot (of their deposit).
@storage_var
func snapshots(provider: address) -> (snapshot: Snapshot) {
}

@storage_var
func snapshots_S(provider: address, yang: address) -> (S: felt) {
}

@storage_var
func snapshots_G(provider: address, token: address) -> (G: felt) {
}

@storage_var
func total_deposits() -> (balance: wad) {
}

// Tracks the users' deposits.
@storage_var
func deposits(provider: felt) -> (balance: wad) {
}

@storage_var
func epoch_to_scale_to_sum(yang: address, epoch: felt, scale: felt) -> (sum: felt) {
}

@storage_var
func epoch_to_scale_to_g(token: address, epoch: felt, scale: felt) -> (G: felt) {
}


// errors tracking
@storage_var
func last_yin_loss_offset() -> (error: felt) {
}

@storage_var
func last_yang_loss_offset(yang: address) -> (error: felt) {
}

@storage_var
func last_interest_error(token: address) -> (error: felt) {
}

/////////////////////////////////////////////
//                EVENTS                   //
/////////////////////////////////////////////

@event
func Provided(provider: felt, amount: wad) {
}

@event
func Withdrawn(provider: felt, amount: wad) {
}

@event
func Liquidated(trove_id: felt) {
}

/////////////////////////////////////////////
//                CONSTRUCTOR              //
/////////////////////////////////////////////

@constructor
func constructor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yin_address: felt,
    shrine_address: felt,
    purger_address: felt,
    abbot_address: felt
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
func provide{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(amount: wad) {
    alloc_locals;
    let (yin_address: address) = yin.read();
    let (this: address) = get_contract_address();
    let (local caller: address) = get_caller_address();
    let (current_deposit: wad) = deposits.read(caller);

    // Pre-payout snippet
    let (abbot_address: address) = abbot.read();
    let (yangs_len: felt, yangs: address*) = IAbbot.get_yang_addresses(contract_address=abbot_address);
    let (owed: felt*) = alloc();
    _get_provider_owed_yangs(caller, current_deposit, yangs_len, yangs, yangs_len, owed);

    let (compounded_deposit: wad) = get_provider_owed_yin(caller);

    _payout_interests(caller);

    // transfer yin from caller to the absorber
    IYin.transferFrom(contract_address=yin_address, sender=caller, recipient=this, amount=amount);
    _increase_total_deposits(amount);

    // update deposit and snapshots
    let (new_deposit: wad) = WadRay.add_unsigned(current_deposit, amount);
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
func withdraw{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    alloc_locals;
    let (local caller) = get_caller_address();
    let (deposit: wad) = deposits.read(caller);
    // get owed yangs
    let (abbot_address: address) = abbot.read();
    let (len: felt, yangs: address*) = IAbbot.get_yang_addresses(contract_address=abbot_address);
    let (owed: felt*) = alloc();
    _get_provider_owed_yangs(caller, deposit, len, yangs, len, owed);
    // get compounded deposit
    let (compounded_deposit: wad) = get_provider_owed_yin(caller);
    _payout_interests(caller);
    // send deposit
    let (yin_address: address) = yin.read();
    IYin.transfer(contract_address=yin_address, recipient=caller, amount=compounded_deposit);
    _decrease_total_deposits(compounded_deposit);
    // update user's deposit
    _update_deposit_and_snapshot(caller, 0);

    _distribute_owed_yangs(caller, len, yangs, len, owed);

    Withdrawn.emit(caller, compounded_deposit);
    return ();
}

// Allows user to withdraw his owed shares of yangs.
// It doesn't withdraw any % of the compounded deposit.
@external
func claim{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    alloc_locals;
    let (local caller) = get_caller_address();
    let (abbot_: address) = abbot.read();
    let (deposit: wad) = deposits.read(caller);

    // get yangs gains
    let (local len: felt, yangs: address*) = IAbbot.get_yang_addresses(contract_address=abbot_);
    let (owed: felt*) = alloc();
    _get_provider_owed_yangs(caller, deposit, len, yangs, len, owed);

    let (compounded_deposit: wad) = get_provider_owed_yin(caller);
    _payout_interests(caller);

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
func liquidate{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(trove_id: felt) -> (absorbed: wad) {
    alloc_locals;
    let (total_deposits_: wad) = total_deposits.read();
    let (purger_address) = purger.read();
    let (amount: wad) = IPurger.get_max_close_amount(contract_address=purger_address, trove_id=trove_id);
    if (total_deposits_ == 0) {
        return (0,);
    }
    if (amount == 0) {
        return (0,);
    }
    let (local to_absorb: felt) = WadRay.min(total_deposits_, amount);
    _purge_and_update(trove_id, total_deposits_, to_absorb);
    Liquidated.emit(trove_id);
    return (to_absorb,);
}

// This is the entry point for the protocol to distribute interest to the absorber.
//
// Parameters
// * token  : address of the interest token
// * amount : amount of interest to distribute
@external
func transfer_interests{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    token: address,
    amount: felt
) {
    // TODO
    // [] - check if token is whitelisted by calling some module??
    // [] - use gate (?) to handle automatically tokens with diff. decimals and uint256 vs felt
    let (caller: address) = get_caller_address();
    let (this: address) = get_contract_address();
    IYin.transferFrom(contract_address=token, sender=caller, recipient=this, amount=amount);
    _update_G(token, amount);
    return ();
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
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    provider: address,
    new_deposit: wad
) {
    alloc_locals;
    deposits.write(provider, new_deposit);
    // update P
    let (curr_P: felt) = P.read();
    let (local current_epoch_: felt) = current_epoch.read();
    let (local current_scale_: felt) = current_scale.read();
    snapshots.write(provider, Snapshot(curr_P, current_epoch_, current_scale_));
    // update G
    _update_provider_G(provider, current_epoch_, current_scale_);
    // update S
    _update_provider_S(provider, current_epoch_, current_scale_);
    return ();
}

// Computes part of the equation of the running products and sums.
// 
// Parameters
// * to_absorb       : debt to absorb
// * total_deposits_ : total deposits absorber holds
// * yangs           : array of yangs' addresses
// * freed_amounts   : array of amounts of yangs freed from liquidation
//
// Returns
// * yin_unit_loss    : amount of yin lost per unit staked
// * yangs_unit_gains : array of amount of yang gained per unit staked
func _update_loss_and_rewards_units{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    to_absorb: wad,
    total_deposits_: wad,
    yangs_len: felt,
    yangs: address*,
    amounts_len: felt,
    freed_amounts: felt*,
) -> (yin_unit_loss: wad, len: felt, yangs_unit_gains: felt*) {
    alloc_locals;
    with_attr error_message("Absorber: not enough deposits to liquidate") {
        assert_le(to_absorb, total_deposits_);
    }
    if (is_not_zero(total_deposits_ - to_absorb) == 0) {
        tempvar yin_loss_per_unit = WadRay.WAD_SCALE;
        last_yin_loss_offset.write(0);
    } else {
        let (last_yin_loss_offset_: felt) = last_yin_loss_offset.read();
        // What is called the yin loss per unit is actually a part of the running product equation.
        // In particular, it corresponds to Q_i / D_(i-1)
        let (yin_loss_numerator: felt) = WadRay.wmul(to_absorb, WadRay.WAD_SCALE);
        let (yin_loss_numerator: felt) = WadRay.sub_unsigned(yin_loss_numerator, last_yin_loss_offset_);
        let (_yin_loss_per_unit: felt) = WadRay.wunsigned_div(yin_loss_numerator, total_deposits_);
        let (_yin_loss_per_unit: felt) = WadRay.add_unsigned(_yin_loss_per_unit, 1);
        let (last_yin_loss_offset_: felt) = WadRay.wmul(_yin_loss_per_unit, total_deposits_);
        let (last_yin_loss_offset_: felt) = WadRay.sub_unsigned(last_yin_loss_offset_, yin_loss_numerator);
        tempvar yin_loss_per_unit = _yin_loss_per_unit;
        last_yin_loss_offset.write(last_yin_loss_offset_);
    }
    local yin_loss_per_unit = yin_loss_per_unit;
    let (yangs_unit_gains: felt*) = alloc();
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
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    total_deposits_: felt,
    yangs_len: felt,
    yangs: address*,
    amounts_len: felt,
    freed_amounts: felt*,
    gains_len: felt,
    gains: felt*
) {
    if (yangs_len == 0) {
        return ();
    }
    let (last_yang_loss_offset_: felt) = last_yang_loss_offset.read([yangs]);
    let (yang_numerator: felt) = WadRay.wmul([freed_amounts], WadRay.WAD_SCALE);
    let (yang_numerator: felt) = WadRay.add_unsigned(yang_numerator, last_yang_loss_offset_);
    let (yang_unit_gain: felt) = WadRay.wunsigned_div(yang_numerator, total_deposits_);
    let (last_yang_loss_offset_: felt) = WadRay.sub_unsigned(yang_numerator, yang_unit_gain);
    let (last_yang_loss_offset_: felt) = WadRay.wmul(last_yang_loss_offset_, total_deposits_);
    last_yang_loss_offset.write([yangs], last_yang_loss_offset_);
    [gains] = yang_unit_gain; //write yang unit gain to array

    return _update_yangs_unit_gains(total_deposits_, yangs_len-1, yangs+1, amounts_len-1, freed_amounts+1, gains_len-1, gains+1);
}


// Purges (liquidates) a unhealthy trove and update the running sums and products.
//
// Parameters
// * trove_id        : the id of the trove to liquidate
// * total_deposits_ : total deposits held by the absorber
// * to_absorb       : the trove's bad debt to absorb
func _purge_and_update{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    trove_id: felt,
    total_deposits_: wad,
    to_absorb: wad
) {
    alloc_locals;
    let (this: felt) = get_contract_address();
    let (shrine_address: felt) = shrine.read();
    let (purger_address: felt) = purger.read();
    let (curr_P: felt) = P.read();
    // burn Yin
    // Spending approval already done in constructor
    let (
        yangs_len: felt,
        yangs: address*,
        freed_len: felt,
        freed_amounts: felt*
    ) = IPurger.purge(
        contract_address=purger_address,
        trove_id=trove_id,
        purge_amt_wad=to_absorb,
        recipient_address=this
    );
    assert yangs_len = freed_len;

    let (
        yin_loss_per_unit: felt,
        gains_len: felt,
        yangs_unit_gains: felt*
    ) = _update_loss_and_rewards_units(to_absorb, total_deposits_, yangs_len, yangs, freed_len, freed_amounts);

    _update_S_and_P(yin_loss_per_unit, yangs_len, yangs, gains_len, yangs_unit_gains);

    _decrease_total_deposits(to_absorb);

    return ();
}

// Updates the running product and sums.
//
// Parameters
// * yin_loss_per_unit : the amount of yin lost per unit staked
// * yangs             : array of yangs' addresses
// * yangs_unit_gains  : array of amount gained per yang
func _update_S_and_P{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    yin_loss_per_unit: felt,
    yangs_len: felt,
    yangs: address*,
    gains_len: felt,
    yangs_unit_gains: felt*
) {
    alloc_locals;
    let (curr_P: felt) = P.read();
    with_attr error_message("Absorber: yin loss superior to decimal precision") {
        assert_le(yin_loss_per_unit, WadRay.WAD_SCALE);
    }
    let (product_factor: felt) = WadRay.sub_unsigned(WadRay.WAD_ONE, yin_loss_per_unit);

    let (current_epoch_: felt) = current_epoch.read();
    let (current_scale_: felt) = current_scale.read();

    _update_all_S(current_epoch_, current_scale_, curr_P, yangs_len, yangs, gains_len, yangs_unit_gains);

    if (product_factor == 0) {
        let (new_epoch: felt) = WadRay.add_unsigned(current_epoch_, 1);
        current_epoch.write(new_epoch);
        current_scale.write(0);
        tempvar new_P = WadRay.WAD_SCALE;
        tempvar syscall_ptr = syscall_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar range_check_ptr = range_check_ptr;
    } else {
        let (potential_new_P: felt) = WadRay.wmul(product_factor, curr_P);
        let (potential_new_P: felt) = WadRay.wunsigned_div(potential_new_P, WadRay.WAD_SCALE);
        if (is_le(potential_new_P, SCALE_FACTOR) == 1) {
            let (new_P_: felt) = WadRay.wmul(product_factor, curr_P);
            let (new_P_: felt) = WadRay.wmul(new_P_, SCALE_FACTOR);
            let (new_P_: felt) = WadRay.wunsigned_div(new_P_, WadRay.WAD_SCALE);
            current_scale.write(current_scale_+1);
            tempvar new_P = new_P_;
            tempvar syscall_ptr = syscall_ptr;
            tempvar pedersen_ptr = pedersen_ptr;
            tempvar range_check_ptr = range_check_ptr;
        } else {
            tempvar new_P = potential_new_P;
            tempvar syscall_ptr = syscall_ptr;
            tempvar pedersen_ptr = pedersen_ptr;
            tempvar range_check_ptr = range_check_ptr;
        }
    }

    local new_P = new_P;
    with_attr error_message("Absorber: P would be 0") {
        assert_not_zero(new_P);
    }
    P.write(new_P);
    return ();
}

// Updates all the S (for every yang) for a given user.
//
// Parameters
// * provider : address of the provider
// * epoch    : epoch to use for the snapshot
// * scale    : scale to use for the snapshot
func _update_provider_S{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    provider: address,
    epoch: felt,
    scale: felt
) {
    let (abbot_address: address) = abbot.read();
    let (len: felt, yangs: address*) = IAbbot.get_yang_addresses(contract_address=abbot_address);
    _update_provider_single_S(provider, epoch, scale, len, yangs);
    return ();
}

// Updates a single S of a given yang for a given user.
//
// Parameters
// * provider : address of the provider
// * epoch    : epoch to use for the snapshot
// * scale    : scale to use for the snapshot
// * yangs    : array of yangs' addresses
func _update_provider_single_S{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    provider: address,
    epoch: felt,
    scale: felt,
    yangs_len: felt,
    yangs: address*
) {
    if (yangs_len == 0) {
        return ();
    }
    
    let (curr_S: felt) = epoch_to_scale_to_sum.read([yangs], epoch, scale);
    snapshots_S.write(provider, [yangs], curr_S);
    return _update_provider_single_S(provider, epoch, scale, yangs_len - 1, yangs + 1);
}

// Updates all the G (for every interest token) for a given user.
//
// Parameters
// * provider : address of the provider
// * epoch    : epoch to use for the snapshot
// * scale    : scale to use for the snapshot
func _update_provider_G{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    provider: address,
    epoch: felt,
    scale: felt
) {
    let (tokens_len: felt, tokens: address*) = _get_interests_tokens();
    _update_provider_single_G(provider, epoch, scale, tokens_len, tokens);
    return ();
}

// Updates a single G of a given interest-token for a given user.
//
// Parameters
// * provider : address of the provider
// * epoch    : epoch to use for the snapshot
// * scale    : scale to use for the snapshot
// * yangs    : array of tokens' addresses
func _update_provider_single_G{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    provider: address,
    epoch: felt,
    scale: felt,
    tokens_len: felt,
    tokens: address*
) {
    if (tokens_len == 0) {
        return ();
    }
    
    let (curr_G: felt) = epoch_to_scale_to_g.read([tokens], epoch, scale);
    snapshots_G.write(provider, [tokens], curr_G);
    return _update_provider_single_S(provider, epoch, scale, tokens_len - 1, tokens + 1);
}

// Update all the running sum for each yang.
//
// Parameters
// * curr_P           : the running product to help us calculate the compounded deposit
// * yangs            : array of the yangs' addresses
// * yangs_unit_gains : array of each yang gain per yin staked
func _update_all_S{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    current_epoch_: felt,
    current_scale_: felt,
    curr_P: felt,
    yangs_len: felt,
    yangs: address*,
    gains_len: felt,
    yangs_unit_gains: felt*
) {
    if (yangs_len == 0) {
        return ();
    }
    
    let (curr_S: felt) = epoch_to_scale_to_sum.read([yangs], current_epoch_, current_scale_);
    let (margin_gain: felt) = WadRay.wmul(curr_P, [yangs_unit_gains]);
    let (new_S) = WadRay.add_unsigned(curr_S, margin_gain);
    epoch_to_scale_to_sum.write([yangs], current_epoch_, current_scale_, new_S);
    return _update_all_S(current_epoch_, current_scale_, curr_P, yangs_len - 1, yangs + 1, gains_len - 1, yangs_unit_gains + 1);
}

// Transfers owed yangs to a provider.
//
// Parameters
// * provider : address of the provider
// * yangs    : array of yangs' addresses
// * owed     : array of owed yangs to send
func _distribute_owed_yangs{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    provider: address,
    yangs_len: felt,
    yangs: address*,
    owed_len: felt,
    owed: felt*
) {
    if (yangs_len == 0) {
        return ();
    }

    IERC20.transfer(contract_address=[yangs], recipient=provider, amount=Uint256([owed], 0));
    return _distribute_owed_yangs(provider, yangs_len - 1, yangs + 1, owed_len - 1, owed + 1);
}

// Computes and transfers the owed interests of a provider.
//
// Parameters
// * provider : address of the provider
func _payout_interests{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(provider: address) {
    let (
        tokens_len: felt,
        tokens: address*,
        gains_len: felt,
        gains: felt*
    ) = get_provider_interests_gains(provider);
    _distribute_interests(provider, tokens_len, tokens, gains_len, gains);
    return ();
} 

// Distributes the interests due to a provider.
//
// Parameters
// * provider : address of the provider
// * tokens   : array of interest tokens' addresses
// * gains    : array of gains to distribute
func _distribute_interests{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    provider: address,
    tokens_len: felt,
    tokens: address*,
    gains_len: felt,
    gains: felt*
) {
    if (gains_len == 0) {
        return ();
    }

    IYin.transfer(contract_address=[tokens], recipient=provider, amount=[gains]);
    return _distribute_interests(provider, tokens_len - 1, tokens + 1, gains_len - 1, gains + 1);
}

// Increases the total deposits by the given amount.
//
// Parameters
// * amount : amount to increase total deposits by
func _increase_total_deposits{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    amount: wad
) {
    let (tdeposits: wad) = total_deposits.read();
    let (new_total_deposits: wad) = WadRay.add_unsigned(tdeposits, amount);
    total_deposits.write(new_total_deposits);
    return ();
}

// Decreases the total deposits by the given amount.
//
// Parameters
// * amount : amount to decrease total deposits by
func _decrease_total_deposits{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    amount: wad
) {
    let (tdeposits: wad) = total_deposits.read();
    let (new_total_deposits: wad) = WadRay.sub_unsigned(tdeposits, amount);
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
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    provider: address,
    deposit: wad,
    yangs_len: felt,
    yangs: address*,
    gains_len: felt,
    gains: felt*
) {
    if (yangs_len == 0) {
        return ();
    }

    if (deposit == 0) {
        assert [gains] = 0;
        return _get_provider_owed_yangs(provider, deposit, yangs_len - 1, yangs + 1, gains_len - 1, gains + 1);
    }

    let (snapshot_S: felt) = snapshots_S.read(provider, [yangs]);
    let (snapshot: Snapshot) = snapshots.read(provider);
    let (S: felt) = epoch_to_scale_to_sum.read([yangs], snapshot.epoch, snapshot.scale);
    let (first_portion: felt) = WadRay.sub_unsigned(S, snapshot_S);
    let (second_portion: felt) = epoch_to_scale_to_sum.read([yangs], snapshot.epoch, snapshot.scale+1);
    let (second_portion: felt) = WadRay.wunsigned_div(second_portion, SCALE_FACTOR);
    let (gain: felt) = WadRay.add_unsigned(first_portion, second_portion);
    let (gain: felt) = WadRay.wmul(deposit, gain);
    let (gain: felt) = WadRay.wunsigned_div(gain, snapshot.P);
    let (gain: felt) = WadRay.wunsigned_div(gain, WadRay.WAD_SCALE);
    assert [gains] = gain;
    return _get_provider_owed_yangs(provider, deposit, yangs_len - 1, yangs + 1, gains_len - 1, gains + 1);
}

// Updates all the G factor of a token that is used to pay interests.
//
// Parameters
// * token  : address of the token
// * amount : amount of interests paid to the absorber
func _update_G{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    token: address,
    amount: felt
) {
    let (total_deposits_: felt) = total_deposits.read();

    if (total_deposits_ == 0) {
        return ();
    }
    if (amount == 0) {
        return ();
    }

    let (curr_P: felt) = P.read();
    // compute token per unit staked
    let (numerator: felt) = WadRay.wmul(amount, WadRay.WAD_SCALE);
    let (error: felt) = last_interest_error.read(token);
    let (numerator: felt) = WadRay.add_unsigned(numerator, error);
    let (interest_per_unit: felt) = WadRay.wunsigned_div(numerator, total_deposits_);

    let (last_interest_error_: felt) = WadRay.wmul(interest_per_unit, total_deposits_);
    let (last_interest_error_: felt) = WadRay.sub_unsigned(numerator, last_interest_error_);
    last_interest_error.write(token, last_interest_error_);

    let (marginal_gain: felt) = WadRay.wmul(interest_per_unit, curr_P);
    let (current_epoch_: felt) = current_epoch.read();
    let (current_scale_: felt) = current_scale.read();
    let (G: felt) = epoch_to_scale_to_g.read(token, current_epoch_, current_scale_);
    let (new_G: felt) = WadRay.add(G, marginal_gain);
    epoch_to_scale_to_g.write(token, current_epoch_, current_scale_, new_G);

    return ();
}

// Sets the interest, for each appropriate token, that is owed to a provider.
//
// Parameters
// * provider : address of the provider
// * tokens   : array of the tokens' addresses
// * gains    : array of the amounts of tokens (interests) the provider is owed
func _get_interests_gains{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    provider: address,
    tokens_len: felt,
    tokens: address *,
    gains_len: felt,
    gains: felt*
) {
    if (tokens_len == 0) {
        return ();
    }

    let (initial_deposit: wad) = deposits.read(provider);

    if (initial_deposit == 0) {
        assert [gains] = 0;
        return _get_interests_gains(provider, tokens_len - 1, tokens + 1, gains_len - 1, gains + 1);
    }

    let (snapshot: Snapshot) = snapshots.read(provider);
    let (snapshot_G: felt) = snapshots_G.read(provider, [tokens]);
    let (first_portion: felt) = epoch_to_scale_to_g.read([tokens], snapshot.epoch, snapshot.scale);
    let (first_portion: felt) = WadRay.sub_unsigned(first_portion, snapshot_G);
    let (second_portion: felt) = epoch_to_scale_to_g.read([tokens], snapshot.epoch, snapshot.scale+1);
    let (second_portion: felt) = WadRay.wunsigned_div(second_portion, SCALE_FACTOR);

    let (gain: felt) = WadRay.add_unsigned(first_portion, second_portion);
    let (gain: felt) = WadRay.wmul(initial_deposit, gain);
    let (gain: felt) = WadRay.wunsigned_div(gain, snapshot.P);
    let (gain: felt) = WadRay.wunsigned_div(gain, WadRay.WAD_SCALE);

    assert [gains] = gain;
    return _get_interests_gains(provider, tokens_len - 1, tokens + 1, gains_len - 1, gains + 1);
}

// WARNING ! TEMPORARY FUNCTION THAT SHOULD NOT MAKE IT TO PRODUCTION
// Returns an array of tokens that are used to pay interest.
func _get_interests_tokens{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}() -> (tokens_len: felt, tokens: address*) {
    let (yin_: address) = yin.read();
    tempvar len = 1;
    let (tokens: address*) = alloc();
    assert tokens[0] = yin_;
    return (len, tokens);
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
func get_provider_owed_yin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(provider: address) -> (yin: wad) {
    alloc_locals;

    let (initial_deposit: wad) = deposits.read(provider);
    if (initial_deposit == 0) {
        return (yin=0,);
    }

    let (curr_P: felt) = P.read();
    let (snapshot: Snapshot) = snapshots.read(provider);
    let (current_epoch_: felt) = current_epoch.read();
    let (current_scale_: felt) = current_scale.read();

    if (is_le(snapshot.epoch, current_epoch_-1) == 1) {
        return (yin=0);
    }

    let (scale_diff: felt) = WadRay.sub_unsigned(current_scale_, snapshot.scale);

    if (scale_diff == 0) {
        let (compounded_deposit_: felt) = WadRay.wmul(initial_deposit, curr_P);
        let (compounded_deposit_: felt) = WadRay.wunsigned_div(compounded_deposit_, snapshot.P);
        tempvar compounded_deposit = compounded_deposit_;
        tempvar range_check_ptr = range_check_ptr;
    } else {
        if (scale_diff == 1) {
            let (compounded_deposit_: felt) = WadRay.wmul(initial_deposit, curr_P);
            let (compounded_deposit_: felt) = WadRay.wunsigned_div(compounded_deposit_, snapshot.P);
            let (compounded_deposit_: felt) = WadRay.wunsigned_div(compounded_deposit_, SCALE_FACTOR);
            tempvar compounded_deposit = compounded_deposit_;
            tempvar range_check_ptr = range_check_ptr;
        } else {
            tempvar compounded_deposit = 0;
            tempvar range_check_ptr = range_check_ptr;
        }
    }
    local compounded_deposit = compounded_deposit;
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
func get_provider_owed_yangs{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(provider: address) -> (yangs_len: felt, yangs: address*, owed_len: felt, owed: felt*) {
    alloc_locals;
    let (deposit: wad) = deposits.read(provider);
    let (abbot_: address) = abbot.read();
    let (local len: felt, yangs: address*) = IAbbot.get_yang_addresses(contract_address=abbot_);
    let (owed: felt*) = alloc();
    _get_provider_owed_yangs(provider, deposit, len, yangs, len, owed);
    return (len, yangs, len, owed);
}

// Returns the interests a provider is owed.
//
// Parameters
// * provider : the address of the provider
//
// Returns
// * tokens : Array of tokens' addresses that are used to pay interest
// * gains  : Array of amounts of claimable interests
@view
func get_provider_interests_gains{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(provider: address) -> (tokens_len: felt, tokens: address*, gains_len: felt, gains: felt*) {
    alloc_locals;
    // get interests tokens somewhere
    let (tokens_len: felt, tokens: address*) = _get_interests_tokens();
    //////////////////////////////////
    let (gains: felt*) = alloc();
    _get_interests_gains(provider, tokens_len, tokens, tokens_len, gains);
    return (tokens_len, tokens, tokens_len, gains);
}