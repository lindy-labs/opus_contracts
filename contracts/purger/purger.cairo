%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import assert_nn_le, unsigned_div_rem
from starkware.cairo.common.math_cmp import is_nn_le
from starkware.starknet.common.syscalls import get_caller_address

from contracts.abbot.interface import IAbbot
from contracts.gate.interface import IGate
from contracts.shrine.interface import IShrine

from contracts.lib.aliases import address, bool, ray, ufelt, wad
from contracts.lib.openzeppelin.security.reentrancyguard.library import ReentrancyGuard
from contracts.lib.wad_ray import WadRay

//
// Constants
//

const CF1 = WadRay.RAY_PERCENT * 270;
const CF2 = WadRay.RAY_PERCENT * 22;

const MAX_PENALTY = 125 * 10 ** 24;  // 0.125
const MIN_PENALTY = 3 * 10 ** 25;  // 0.03
const PENALTY_DIFF = MAX_PENALTY - MIN_PENALTY;
const MAX_PENALTY_LTV = 8888 * 10 ** 23;  // 0.8888

//
// Storage
//

@storage_var
func purger_shrine() -> (shrine: address) {
}

@storage_var
func purger_abbot() -> (abbot: address) {
}

@storage_var
func purger_absorber() -> (absorber: address) {
}

//
// Events
//

@event
func Purged(
    trove_id: ufelt,
    purge_amt: wad,
    funder: address,
    recipient: address,
    percentage_freed: ray,
    yangs_len: ufelt,
    yangs: address*,
    freed_assets_amt_len: ufelt,
    freed_assets_amt: wad*,
) {
}

//
// View functions
//

// Returns the liquidation penalty based on the LTV (ray)
// Returns 0 if trove is healthy
@view
func get_penalty{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt
) -> (penalty: ray) {
    alloc_locals;

    let (shrine: address) = purger_shrine.read();

    let (is_healthy: bool) = IShrine.is_healthy(shrine, trove_id);
    if (is_healthy == TRUE) {
        return (0,);
    }

    let (trove_threshold: ray, trove_value: wad) = IShrine.get_trove_threshold_and_value(
        shrine, trove_id
    );
    let (trove_debt: wad) = IShrine.estimate(shrine, trove_id);
    let (trove_ltv: ray) = IShrine.get_current_trove_ltv(shrine, trove_id);

    let penalty: ray = get_penalty_internal(trove_threshold, trove_ltv, trove_value, trove_debt);
    return (penalty,);
}

// Returns the maximum amount of debt that can be closed for a Trove based on the close factor
// Returns 0 if trove is healthy
@view
func get_max_close_amount{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt
) -> (amount: wad) {
    alloc_locals;

    let (shrine: address) = purger_shrine.read();

    let (is_healthy: bool) = IShrine.is_healthy(shrine, trove_id);
    if (is_healthy == TRUE) {
        return (0,);
    }

    let (trove_ltv: ray) = IShrine.get_current_trove_ltv(shrine, trove_id);
    let (debt: wad) = IShrine.estimate(shrine, trove_id);

    let close_amount = get_max_close_amount_internal(trove_ltv, debt);
    return (close_amount,);
}

//
// Constructor
//

@constructor
func constructor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine: address, abbot: address, absorber: address
) {
    purger_shrine.write(shrine);
    purger_abbot.write(abbot);
    purger_absorber.write(absorber);
    return ();
}

//
// External functions
//

@external
func liquidate{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt, purge_amt: wad, recipient: address
) -> (yangs_len: ufelt, yangs: address*, freed_assets_amt_len: ufelt, freed_assets_amt: wad*) {
    alloc_locals;

    let (shrine: address) = purger_shrine.read();

    // Check that trove can be liquidated
    let (is_healthy: bool) = IShrine.is_healthy(shrine, trove_id);
    with_attr error_message("Purger: Trove {trove_id} is not liquidatable") {
        assert is_healthy = FALSE;
    }

    // Check purge_amt <= max_close_amt
    let (debt: wad) = IShrine.estimate(shrine, trove_id);
    let (trove_ltv: ray) = IShrine.get_current_trove_ltv(shrine, trove_id);

    let max_close_amt: wad = get_max_close_amount_internal(trove_ltv, debt);
    with_attr error_message("Purger: Maximum close amount exceeded") {
        assert_nn_le(purge_amt, max_close_amt);
    }

    let (funder: address) = get_caller_address();
    return purge(shrine, trove_id, trove_ltv, debt, purge_amt, funder, recipient);
}

@external
func absorb{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(trove_id: ufelt) -> (
    yangs_len: ufelt, yangs: address*, freed_assets_amt_len: ufelt, freed_assets_amt: wad*
) {
    alloc_locals;

    let (shrine: address) = purger_shrine.read();

    // Check that trove can be liquidated
    let (is_healthy: bool) = IShrine.is_healthy(shrine, trove_id);
    with_attr error_message("Purger: Trove {trove_id} is not liquidatable") {
        assert is_healthy = FALSE;
    }

    let (trove_ltv: ray) = IShrine.get_current_trove_ltv(shrine, trove_id);
    // Check that max penalty LTV is exceeded
    let below_max_penalty_ltv: bool = is_nn_le(trove_ltv, MAX_PENALTY_LTV);
    with_attr error_message("Purger: Trove {trove_id} is not absorbable") {
        assert below_max_penalty_ltv = FALSE;
    }

    let (debt: wad) = IShrine.estimate(shrine, trove_id);
    let (absorber: address) = purger_absorber.read();

    let (absorber_yin_balance: wad) = IShrine.get_yin(shrine, absorber);

    let fully_absorbable: bool = is_nn_le(debt, absorber_yin_balance);
    if (fully_absorbable == TRUE) {
        let (
            yangs_len: ufelt, yangs: address*, freed_assets_amt_len: ufelt, freed_assets_amt: wad*
        ) = purge(shrine, trove_id, trove_ltv, debt, debt, absorber, absorber);
    } else {
        let (
            yangs_len: ufelt, yangs: address*, freed_assets_amt_len: ufelt, freed_assets_amt: wad*
        ) = purge(shrine, trove_id, trove_ltv, debt, absorber_yin_balance, absorber, absorber);
        // TODO: Redistribute
    }

    return (yangs_len, yangs, freed_assets_amt_len, freed_assets_amt);
}

//
// Internal
//

func purge{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine: address,
    trove_id: ufelt,
    before_ltv: ray,
    debt: wad,
    purge_amt: wad,
    funder: address,
    recipient: address,
) -> (yangs_len: ufelt, yangs: address*, freed_assets_amt_len: ufelt, freed_assets_amt: wad*) {
    alloc_locals;

    let (trove_threshold: ray, trove_value: wad) = IShrine.get_trove_threshold_and_value(
        shrine, trove_id
    );

    let percentage_freed: ray = get_percentage_freed(
        trove_threshold, before_ltv, trove_value, debt, purge_amt
    );

    // Melt from the funder address directly
    IShrine.melt(shrine, funder, trove_id, purge_amt);

    // Loop through yang addresses and transfer to recipient
    let (abbot: address) = purger_abbot.read();
    let (yang_count, yangs: address*) = IAbbot.get_yang_addresses(abbot);
    let (freed_assets_amt: wad*) = alloc();

    free_yangs(
        shrine, abbot, recipient, trove_id, yang_count, yangs, percentage_freed, freed_assets_amt
    );

    // Assert new LTV < old LTV
    let (after_ltv: ray) = IShrine.get_current_trove_ltv(shrine, trove_id);
    with_attr error_message("Purger: Loan-to-value ratio increased") {
        assert_nn_le(after_ltv, before_ltv);
    }

    Purged.emit(
        trove_id,
        purge_amt,
        funder,
        recipient,
        percentage_freed,
        yang_count,
        &yangs[0],
        yang_count,
        &freed_assets_amt[0],
    );

    // The denomination for each value in `freed_assets_amt` will be based on the decimals
    // for the respective asset.
    return (yang_count, yangs, yang_count, freed_assets_amt);
}

// Returns the close factor based on the LTV (ray)
// closeFactor = 2.7 * (LTV ** 2) - 2 * LTV + 0.22
//               [CF1]                        [CF2]
//               [factor_one] - [ factor_two ]
func get_close_factor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    ltv: ray
) -> ray {
    let ltv_squared = WadRay.rmul(ltv, ltv);
    let factor_one = WadRay.rmul(CF1, ltv_squared);

    let factor_two = WadRay.add_unsigned(ltv, ltv);
    let factors_sum = WadRay.sub(factor_one, factor_two);
    let close_factor = WadRay.add_unsigned(factors_sum, CF2);

    return close_factor;
}

func get_max_close_amount_internal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_ltv: ray, debt: wad
) -> wad {
    let close_factor: ray = get_close_factor(trove_ltv);

    // `rmul` of a wad and a ray returns a wad
    let close_amt: wad = WadRay.rmul(debt, close_factor);

    let exceeds_debt = is_nn_le(debt, close_amt);
    if (exceeds_debt == TRUE) {
        return debt;
    }

    return close_amt;
}

// Assumption: Trove's LTV has exceeded its threshold
// - If LTV <= MAX_PENALTY_LTV, penalty = m * LTV + b (see `get_penalty_fn`)
//
//                                               (trove_value - trove_debt)
// - If MAX_PENALTY_LTV < LTV <= 100%, penalty = -------------------------
//                                                      trove_debt
//
// - If 100% < LTV, penalty = 0
// Return value is a tuple so that function can be modified as an external view for testing
func get_penalty_internal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_threshold: ray, trove_ltv: ray, trove_value: wad, trove_debt: wad
) -> (penalty: ray) {
    let is_covered = is_nn_le(trove_ltv, WadRay.RAY_ONE);
    if (is_covered == FALSE) {
        return (0,);
    }

    let below_max_penalty_ltv: bool = is_nn_le(trove_ltv, MAX_PENALTY_LTV);
    if (below_max_penalty_ltv == TRUE) {
        let (m: ray, b: ray) = get_penalty_fn(trove_threshold);
        let penalty: ray = WadRay.add(WadRay.rmul(m, trove_ltv), b);
        return (penalty,);
    }

    let penalty: ray = WadRay.runsigned_div(
        WadRay.sub_unsigned(trove_value, trove_debt), trove_debt
    );
    return (penalty,);
}

// Determine the function for calculating purge penalty based on the threshold
//
//                    maxLiqPenalty - minLiqPenalty
// liqPenalty = LTV * ----------------------------- + b
//                    maxPenaltyLTV - liqThreshold
//
// Returns the `m` coefficient and `b` constant for the penalty in the form of liqPenalty = m * LTV + b
func get_penalty_fn{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_threshold: ray
) -> (m: ray, b: ray) {
    // Derive the `m` coefficient
    let denominator: ray = WadRay.sub(MAX_PENALTY_LTV, trove_threshold);
    let m: ray = WadRay.rsigned_div(PENALTY_DIFF, denominator);

    // Derive the `b` constant
    let m_ltv: ray = WadRay.rmul(trove_threshold, m);
    let b: ray = WadRay.sub(MIN_PENALTY, m_ltv);

    return (m, b);
}

// Helper function to calculate percentage of collateral freed.
// If LTV > 100%, pro-rate based on amount paid down divided by total debt.
// If LTV <= 100%, calculate based on the sum of amount paid down and liquidation penalty divided
// by total trove value.
func get_percentage_freed{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_threshold: ray, trove_ltv: ray, trove_value: wad, trove_debt: wad, purge_amt: wad
) -> ray {
    alloc_locals;

    let is_covered: bool = is_nn_le(trove_ltv, WadRay.RAY_ONE);
    if (is_covered == FALSE) {
        // `runsigned_div` of two wads returns a ray
        let prorata_percentage_freed: ray = WadRay.runsigned_div(purge_amt, trove_debt);
        return prorata_percentage_freed;
    }

    let penalty: ray = get_penalty_internal(trove_threshold, trove_ltv, trove_value, trove_debt);

    // `rmul` of a wad and a ray returns a wad
    let penalty_amt: wad = WadRay.rmul(purge_amt, penalty);
    let freed_amt: wad = WadRay.add_unsigned(penalty_amt, purge_amt);

    // `runsigned_div` of two wads returns a ray
    let percentage_freed: ray = WadRay.runsigned_div(freed_amt, trove_value);
    return percentage_freed;
}

// Helper function to loop through yang addresses and transfer freed yang to recipient
func free_yangs{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine: address,
    abbot: address,
    recipient: address,
    trove_id: ufelt,
    yang_count: ufelt,
    yangs: address*,
    percentage_freed: ray,
    freed_assets_amt: wad*,
) {
    if (yang_count == 0) {
        return ();
    }

    free_yang(shrine, abbot, recipient, trove_id, [yangs], percentage_freed, freed_assets_amt);

    return free_yangs(
        shrine,
        abbot,
        recipient,
        trove_id,
        yang_count - 1,
        yangs + 1,
        percentage_freed,
        freed_assets_amt + 1,
    );
}

// Helper function to transfer freed yang to recipient for a specific yang
func free_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine: address,
    abbot: address,
    recipient: address,
    trove_id: ufelt,
    yang: address,
    percentage_freed: ray,
    freed_assets_amt: wad*,
) {
    let (deposited_amt: wad) = IShrine.get_deposit(shrine, yang, trove_id);

    // Early termination if no yang deposited
    if (deposited_amt == 0) {
        assert [freed_assets_amt] = 0;
        return ();
    }

    let (gate: address) = IAbbot.get_gate_address(abbot, yang);

    // `rmul` of a wad and a ray returns a wad
    let freed_yang: wad = WadRay.rmul(deposited_amt, percentage_freed);

    ReentrancyGuard._start();
    // The denomination is based on the number of decimals for the token
    let (freed_asset_amt: wad) = IGate.withdraw(gate, recipient, trove_id, freed_yang);
    assert [freed_assets_amt] = freed_asset_amt;
    IShrine.seize(shrine, yang, trove_id, freed_yang);
    ReentrancyGuard._end();

    return ();
}
