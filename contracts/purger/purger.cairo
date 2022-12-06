%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import assert_nn_le
from starkware.cairo.common.math_cmp import is_nn_le
from starkware.starknet.common.syscalls import get_caller_address

from contracts.gate.interface import IGate
from contracts.sentinel.interface import ISentinel
from contracts.shrine.interface import IShrine

from contracts.lib.aliases import address, bool, ray, ufelt, wad
from contracts.lib.openzeppelin.security.reentrancyguard.library import ReentrancyGuard
from contracts.lib.wad_ray import WadRay

//
// Constants
//

// Close factor function parameters
const CF1 = WadRay.RAY_PERCENT * 270;
const CF2 = WadRay.RAY_PERCENT * 22;

// Maximum liquidation penalty
const MAX_PENALTY = 125 * 10 ** 24;  // 0.125

// Minimum liquidation penalty
const MIN_PENALTY = 3 * 10 ** 25;  // 0.03

// Difference between minimum and maximum liquidation penalty
const PENALTY_DIFF = MAX_PENALTY - MIN_PENALTY;

// LTV at the maximum liquidation penalty
const MAX_PENALTY_LTV = 8888 * 10 ** 23;  // 0.8888

//
// Storage
//

@storage_var
func purger_shrine() -> (shrine: address) {
}

@storage_var
func purger_sentinel() -> (sentinel: address) {
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
    freed_assets_amt: ufelt*,
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
    let (shrine: address) = purger_shrine.read();
    let (threshold: ray, ltv: ray, value: wad, debt: wad) = IShrine.get_trove_info(
        shrine, trove_id
    );

    let is_healthy: bool = is_nn_le(ltv, threshold);
    if (is_healthy == TRUE) {
        return (0,);
    }

    let penalty: ray = get_penalty_internal(threshold, ltv, value, debt);
    return (penalty,);
}

// Returns the maximum amount of debt that can be closed for a Trove based on the close factor
// Returns 0 if trove is healthy
@view
func get_max_close_amount{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt
) -> (amount: wad) {
    let (shrine: address) = purger_shrine.read();
    let (threshold: ray, ltv: ray, _, debt: wad) = IShrine.get_trove_info(shrine, trove_id);

    let is_healthy: bool = is_nn_le(ltv, threshold);
    if (is_healthy == TRUE) {
        return (0,);
    }

    let close_amount: wad = get_max_close_amount_internal(ltv, debt);
    return (close_amount,);
}

//
// Constructor
//

@constructor
func constructor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine: address, sentinel: address, absorber: address
) {
    purger_shrine.write(shrine);
    purger_sentinel.write(sentinel);
    purger_absorber.write(absorber);
    return ();
}

//
// External functions
//

// Performs searcher liquidations that requires the caller address to supply the amount of debt to repay
// and the recipient address to send the freed collateral to.
// Reverts if the trove is not liquidatable (i.e. LTV > threshold)
// Reverts if the repayment amount exceeds the maximum amount as determined by the close factor.
@external
func liquidate{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt, purge_amt: wad, recipient: address
) -> (yangs_len: ufelt, yangs: address*, freed_assets_amt_len: ufelt, freed_assets_amt: ufelt*) {
    alloc_locals;

    let (shrine: address) = purger_shrine.read();
    let (
        trove_threshold: ray, trove_ltv: ray, trove_value: wad, trove_debt: wad
    ) = IShrine.get_trove_info(shrine, trove_id);

    // Assert validity of `purge_amt` argument
    with_attr error_message("Purger: Value of `purge_amt` ({purge_amt}) is out of bounds") {
        WadRay.assert_valid_unsigned(purge_amt);
    }

    assert_liquidatable(trove_id, trove_threshold, trove_ltv);

    // Check purge_amt <= max_close_amt
    // Since the value of `max_close_amt` cannot exceed `debt`, this also checks that 0 < `purge_amt` < `debt`
    let max_close_amt: wad = get_max_close_amount_internal(trove_ltv, trove_debt);
    let safe_purge_amt: wad = WadRay.unsigned_min(purge_amt, max_close_amt);

    // Get percentage freed
    let percentage_freed: ray = get_percentage_freed(
        trove_threshold, trove_ltv, trove_value, trove_debt, safe_purge_amt
    );

    let (funder: address) = get_caller_address();
    return purge(shrine, trove_id, trove_ltv, safe_purge_amt, percentage_freed, funder, recipient);
}

// Performs stability pool liquidations to pay down a trove's debt in full and transfer the freed collateral
// to the stability pool. If the stability pool does not have sufficient yin, the trove's debt and collateral
// will be proportionally redistributed among all troves containing the trove's collateral.
// - The amount of debt distributed to each collateral = (value of collateral / trove value) * trove debt
// Reverts if the trove's LTV is not above the max penalty LTV
// - It follows that the trove must also be liquidatable because threshold < max penalty LTV.
@external
func absorb{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(trove_id: ufelt) -> (
    yangs_len: ufelt, yangs: address*, freed_assets_amt_len: ufelt, freed_assets_amt: ufelt*
) {
    alloc_locals;

    let (shrine: address) = purger_shrine.read();
    let (
        trove_threshold: ray, trove_ltv: ray, trove_value: wad, trove_debt: wad
    ) = IShrine.get_trove_info(shrine, trove_id);

    assert_liquidatable(trove_id, trove_threshold, trove_ltv);

    // Check that max penalty LTV is exceeded
    let is_absorbable: bool = is_nn_le(trove_ltv, MAX_PENALTY_LTV);
    with_attr error_message("Purger: Trove {trove_id} is not absorbable") {
        assert is_absorbable = FALSE;
    }

    let (absorber: address) = purger_absorber.read();
    let (absorber_yin_balance: wad) = IShrine.get_yin(shrine, absorber);

    // This also checks that the value that is passed as `purge_amt` to `purge` cannot exceed `debt`.
    let fully_absorbable: bool = is_nn_le(trove_debt, absorber_yin_balance);
    if (fully_absorbable == TRUE) {
        // Call purge with `percentage_freed` set to 100%
        let (
            yangs_len: ufelt, yangs: address*, freed_assets_amt_len: ufelt, freed_assets_amt: ufelt*
        ) = purge(shrine, trove_id, trove_ltv, trove_debt, WadRay.RAY_ONE, absorber, absorber);
    } else {
        let percentage_freed: ray = get_percentage_freed(
            trove_threshold, trove_ltv, trove_value, trove_debt, absorber_yin_balance
        );
        let (
            yangs_len: ufelt, yangs: address*, freed_assets_amt_len: ufelt, freed_assets_amt: ufelt*
        ) = purge(
            shrine, trove_id, trove_ltv, absorber_yin_balance, percentage_freed, absorber, absorber
        );
        // TODO: Redistribute
    }

    // TODO: Call Absorber to update its internal accounting

    return (yangs_len, yangs, freed_assets_amt_len, freed_assets_amt);
}

//
// Internal
//

// Asserts that a trove is liquidatable given its LTV and threshold
func assert_liquidatable{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt, threshold: ray, ltv: ray
) {
    let is_healthy: bool = is_nn_le(ltv, threshold);
    with_attr error_message("Purger: Trove {trove_id} is not liquidatable") {
        assert is_healthy = FALSE;
    }
    return ();
}

// Internal function to handle the paying down of a trove's debt in return for the
// corresponding freed collateral to be sent to the recipient address
// Reverts if the trove's LTV is worse off than before the purge
// - This should not be possible, but is added in for safety.
func purge{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine: address,
    trove_id: ufelt,
    trove_ltv: ray,
    purge_amt: wad,
    percentage_freed: ray,
    funder: address,
    recipient: address,
) -> (yangs_len: ufelt, yangs: address*, freed_assets_amt_len: ufelt, freed_assets_amt: ufelt*) {
    alloc_locals;
    // Melt from the funder address directly
    IShrine.melt(shrine, funder, trove_id, purge_amt);

    // Loop through yang addresses and transfer to recipient
    let (sentinel: address) = purger_sentinel.read();
    let (yang_count, yangs: address*) = ISentinel.get_yang_addresses(sentinel);
    let (freed_assets_amt: ufelt*) = alloc();

    free_yangs(
        shrine, sentinel, recipient, trove_id, yang_count, yangs, percentage_freed, freed_assets_amt
    );

    // Assert new LTV < old LTV
    let (_, updated_trove_ltv: ray, _, _) = IShrine.get_trove_info(shrine, trove_id);
    with_attr error_message("Purger: Loan-to-value ratio increased") {
        assert_nn_le(updated_trove_ltv, trove_ltv);
    }

    Purged.emit(
        trove_id,
        purge_amt,
        funder,
        recipient,
        percentage_freed,
        yang_count,
        yangs,
        yang_count,
        freed_assets_amt,
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
//
//                                              maxLiqPenalty - minLiqPenalty
// - If LTV <= MAX_PENALTY_LTV, penalty = LTV * ----------------------------- + b
//                                              maxPenaltyLTV - liqThreshold
//
//                                      = LTV * m + b
//
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
    let is_penalizable: bool = is_nn_le(trove_ltv, WadRay.RAY_ONE);
    if (is_penalizable == FALSE) {
        return (0,);
    }

    let below_max_penalty_ltv: bool = is_nn_le(trove_ltv, MAX_PENALTY_LTV);
    if (below_max_penalty_ltv == TRUE) {
        // Derive the 'm' term
        let m: ray = WadRay.rsigned_div(PENALTY_DIFF, WadRay.sub(MAX_PENALTY_LTV, trove_threshold));

        // Derive the `b` constant
        let b: ray = WadRay.sub(MIN_PENALTY, WadRay.rmul(trove_threshold, m));

        let penalty: ray = WadRay.add(WadRay.rmul(m, trove_ltv), b);
        return (penalty,);
    }

    let penalty: ray = WadRay.runsigned_div(
        WadRay.sub_unsigned(trove_value, trove_debt), trove_debt
    );
    return (penalty,);
}

// Helper function to calculate percentage of collateral freed.
// If LTV > 100%, pro-rate based on amount paid down divided by total debt.
// If LTV <= 100%, calculate based on the sum of amount paid down and liquidation penalty divided
// by total trove value.
func get_percentage_freed{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_threshold: ray, trove_ltv: ray, trove_value: wad, trove_debt: wad, purge_amt: wad
) -> ray {
    alloc_locals;

    let is_penalizable: bool = is_nn_le(trove_ltv, WadRay.RAY_ONE);
    if (is_penalizable == FALSE) {
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
    sentinel: address,
    recipient: address,
    trove_id: ufelt,
    yang_count: ufelt,
    yangs: address*,
    percentage_freed: ray,
    freed_assets_amt: ufelt*,
) {
    if (yang_count == 0) {
        return ();
    }

    free_yang(shrine, sentinel, recipient, trove_id, [yangs], percentage_freed, freed_assets_amt);

    return free_yangs(
        shrine,
        sentinel,
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
    sentinel: address,
    recipient: address,
    trove_id: ufelt,
    yang: address,
    percentage_freed: ray,
    freed_assets_amt: ufelt*,
) {
    let (deposited_yang_amt: wad) = IShrine.get_deposit(shrine, yang, trove_id);

    // Early termination if no yang deposited
    if (deposited_yang_amt == 0) {
        assert [freed_assets_amt] = 0;
        return ();
    }

    let (gate: address) = ISentinel.get_gate_address(sentinel, yang);

    // `rmul` of a wad and a ray returns a wad
    let freed_yang: wad = WadRay.rmul(deposited_yang_amt, percentage_freed);

    ReentrancyGuard._start();
    // The denomination is based on the number of decimals for the token
    let (freed_asset_amt: ufelt) = IGate.exit(gate, recipient, trove_id, freed_yang);
    assert [freed_assets_amt] = freed_asset_amt;
    IShrine.seize(shrine, yang, trove_id, freed_yang);
    ReentrancyGuard._end();

    return ();
}
