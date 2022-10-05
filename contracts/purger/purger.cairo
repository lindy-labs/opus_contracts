%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import assert_nn_le, unsigned_div_rem
from starkware.cairo.common.math_cmp import is_nn_le
from starkware.starknet.common.syscalls import get_caller_address

from contracts.lib.openzeppelin.security.reentrancyguard.library import ReentrancyGuard

from contracts.abbot.interface import IAbbot
from contracts.gate.interface import IGate
from contracts.lib.aliases import address, bool, ray, ufelt, wad
from contracts.lib.wad_ray import WadRay
from contracts.shrine.interface import IShrine

//
// Constants
//

const CF1 = WadRay.RAY_PERCENT * 270;
const CF2 = WadRay.RAY_PERCENT * 22;

//
// Storage
//

@storage_var
func purger_shrine() -> (shrine: address) {
}

@storage_var
func purger_abbot() -> (abbot: address) {
}

//
// Events
//

@event
func Purged(
    trove_id: ufelt,
    purge_amt: wad,
    recipient: address,
    funder: address,
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
func get_purge_penalty{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt
) -> (penalty: ray) {
    alloc_locals;

    let (shrine: address) = purger_shrine.read();

    let (is_healthy: bool) = IShrine.is_healthy(shrine, trove_id);
    if (is_healthy == TRUE) {
        return (0,);
    }

    let (trove_ltv: ray) = IShrine.get_current_trove_ltv(shrine, trove_id);

    // placeholder
    let penalty: ray = get_purge_penalty_internal(trove_ltv);
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

    let close_amount = get_max_close_amount_internal(shrine, trove_id, trove_ltv);
    return (close_amount,);
}

//
// Constructor
//

@constructor
func constructor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine: address, abbot: address
) {
    purger_shrine.write(shrine);
    purger_abbot.write(abbot);
    return ();
}

//
// External functions
//

@external
func purge{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt, purge_amt: wad, recipient: address
) -> (yangs_len: ufelt, yangs: address*, freed_assets_amt_len: ufelt, freed_assets_amt: wad*) {
    alloc_locals;

    let (caller: address) = get_caller_address();
    let (shrine: address) = purger_shrine.read();

    // Check that trove can be liquidated
    let (is_healthy: bool) = IShrine.is_healthy(shrine, trove_id);
    with_attr error_message("Purger: Trove {trove_id} is not liquidatable") {
        assert is_healthy = FALSE;
    }

    let (before_ltv: ray) = IShrine.get_current_trove_ltv(shrine, trove_id);

    // Check purge_amt <= max_close_amt
    let max_close_amt: wad = get_max_close_amount_internal(shrine, trove_id, before_ltv);
    with_attr error_message("Purger: Maximum close amount exceeded") {
        assert_nn_le(purge_amt, max_close_amt);
    }

    let percentage_freed: ray = get_percentage_freed(shrine, trove_id, purge_amt, before_ltv);

    // Melt from the caller address directly
    IShrine.melt(shrine, caller, trove_id, purge_amt);

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
        recipient,
        caller,
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

//
// Internal
//

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
    shrine: address, trove_id: ufelt, trove_ltv: ray
) -> wad {
    let close_factor: ray = get_close_factor(trove_ltv);
    let (debt: wad) = IShrine.estimate(shrine, trove_id);

    // `rmul` of a wad and a ray returns a wad
    let close_amt: wad = WadRay.rmul(debt, close_factor);

    let exceeds_debt = is_nn_le(debt, close_amt);
    if (exceeds_debt == TRUE) {
        return debt;
    }

    return close_amt;
}

func get_purge_penalty_internal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    ltv: ray
) -> ray {
    // placeholder
    let is_covered = is_nn_le(ltv, WadRay.RAY_ONE);
    if (is_covered == FALSE) {
        return 0;
    }

    let rem: ray = WadRay.sub(WadRay.RAY_ONE, ltv);
    let (penalty, _) = unsigned_div_rem(rem, 20);
    return penalty;
}

// Helper function to calculate percentage of collateral freed.
// If LTV > 100%, pro-rate based on amount paid down divided by total debt.
// If LTV <= 100%, calculate based on the sum of amount paid down and liquidation penalty divided
// by total trove value.
func get_percentage_freed{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine: address, trove_id: ufelt, purge_amt: wad, ltv: ray
) -> ray {
    let is_covered = is_nn_le(ltv, WadRay.RAY_ONE);
    if (is_covered == FALSE) {
        let (trove_debt) = IShrine.estimate(shrine, trove_id);

        // `runsigned_div` of two wads returns a ray
        let prorata_percentage_freed: ray = WadRay.runsigned_div(purge_amt, trove_debt);
        return prorata_percentage_freed;
    }

    let penalty: ray = get_purge_penalty_internal(ltv);

    // `rmul` of a wad and a ray returns a wad
    let penalty_amt: wad = WadRay.rmul(purge_amt, penalty);
    let freed_amt: wad = WadRay.add_unsigned(penalty_amt, purge_amt);
    let (_, trove_value: wad) = IShrine.get_trove_threshold_and_value(shrine, trove_id);

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
