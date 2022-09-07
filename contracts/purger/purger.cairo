%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import assert_le, unsigned_div_rem
from starkware.cairo.common.math_cmp import is_le
from starkware.starknet.common.syscalls import get_caller_address

from contracts.interfaces import IAbbot, IGate, IShrine
from contracts.shared.wad_ray import WadRay

//
// Constants
//

const CF1 = WadRay.RAY_PERCENT * 270;
const CF2 = WadRay.RAY_PERCENT * 22;

//
// Storage
//

@storage_var
func purger_shrine_storage() -> (address: felt) {
}

@storage_var
func purger_abbot_storage() -> (address: felt) {
}

@storage_var
func purger_yin_storage() -> (address: felt) {
}

//
// Events
//

@event
func Purged(trove_id, purge_amt_wad, recipient_address, funder_address, percentage_freed_ray) {
}

//
// View functions
//

// Returns the liquidation penalty based on the LTV (ray)
// Returns 0 if trove is healthy
@view
func get_purge_penalty{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id
) -> (ray: felt) {
    alloc_locals;

    let (shrine_address) = purger_shrine_storage.read();

    let (is_healthy) = IShrine.is_healthy(contract_address=shrine_address, trove_id=trove_id);
    if (is_healthy == TRUE) {
        return (0,);
    }

    let (trove_ltv_ray) = IShrine.get_current_trove_ratio(
        contract_address=shrine_address, trove_id=trove_id
    );

    // placeholder
    return get_purge_penalty_internal(trove_ltv_ray);
}

// Returns the maximum amount of debt that can be closed for a Trove based on the close factor
// Returns 0 if trove is healthy
@view
func get_max_close_amount{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id
) -> (wad: felt) {
    alloc_locals;

    let (shrine_address) = purger_shrine_storage.read();

    let (is_healthy) = IShrine.is_healthy(contract_address=shrine_address, trove_id=trove_id);
    if (is_healthy == TRUE) {
        return (0,);
    }

    let (trove_ltv_ray) = IShrine.get_current_trove_ratio(
        contract_address=shrine_address, trove_id=trove_id
    );

    return get_max_close_amount_internal(shrine_address, trove_id, trove_ltv_ray);
}

//
// Constructor
//

@constructor
func constructor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine_address, abbot_address, yin_address
) {
    purger_shrine_storage.write(shrine_address);
    purger_abbot_storage.write(abbot_address);
    purger_yin_storage.write(yin_address);
    return ();
}

//
// External functions
//

@external
func purge{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id, purge_amt_wad, recipient_address
) -> (
    yang_addresses_len: felt,
    yang_addresses: felt*,
    freed_assets_wad_len: felt,
    freed_assets_wad: felt*,
) {
    alloc_locals;

    let (caller_address) = get_caller_address();
    let (shrine_address) = purger_shrine_storage.read();

    // Check that trove can be liquidated
    let (is_healthy) = IShrine.is_healthy(contract_address=shrine_address, trove_id=trove_id);
    with_attr error_message("Purger: Trove is not liquidatable") {
        assert is_healthy = FALSE;
    }

    let (before_ltv_ray) = IShrine.get_current_trove_ratio(
        contract_address=shrine_address, trove_id=trove_id
    );

    // Check purge_amt <= max_close_amt
    let (max_close_amt) = get_max_close_amount_internal(shrine_address, trove_id, before_ltv_ray);
    let is_valid = is_le(purge_amt_wad, max_close_amt);
    with_attr error_message("Purger: Maximum close amount exceeded") {
        assert is_valid = TRUE;
    }

    let (percentage_freed_ray) = get_percentage_freed(
        shrine_address, trove_id, purge_amt_wad, before_ltv_ray
    );

    // Melt from the caller address directly
    let (yin_address) = purger_yin_storage.read();
    IShrine.melt(
        contract_address=shrine_address,
        user_address=caller_address,
        trove_id=trove_id,
        amount=purge_amt_wad,
    );

    // Loop through yang addresses and transfer to recipient
    let (abbot_address) = purger_abbot_storage.read();
    let (yang_count, yang_addresses: felt*) = IAbbot.get_yang_addresses(
        contract_address=abbot_address
    );
    let (freed_assets_wad: felt*) = alloc();

    free_yangs(
        shrine_address,
        abbot_address,
        recipient_address,
        trove_id,
        yang_count,
        yang_addresses,
        percentage_freed_ray,
        freed_assets_wad,
    );

    // Assert new LTV < old LTV
    let (after_ltv_ray) = IShrine.get_current_trove_ratio(
        contract_address=shrine_address, trove_id=trove_id
    );
    with_attr error_message("Purger: Loan-to-value ratio increased") {
        assert_le(after_ltv_ray, before_ltv_ray);
    }

    Purged.emit(trove_id, purge_amt_wad, recipient_address, caller_address, percentage_freed_ray);

    return (yang_count, yang_addresses, yang_count, freed_assets_wad);
}

//
// Internal
//

// Returns the close factor based on the LTV (ray)
// closeFactor = 2.7 * (LTV ** 2) - 2 * LTV + 0.22
//               [CF1]                        [CF2]
//               [factor_one] - [ factor_two ]
func get_close_factor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(ltv_ray) -> (
    ray: felt
) {
    let (ltv_ray_squared) = WadRay.rmul(ltv_ray, ltv_ray);
    let (factor_one) = WadRay.rmul(CF1, ltv_ray_squared);

    let (factor_two) = WadRay.add_unsigned(ltv_ray, ltv_ray);
    let (factors_sum) = WadRay.sub(factor_one, factor_two);
    let (close_factor) = WadRay.add_unsigned(factors_sum, CF2);

    return (close_factor,);
}

func get_max_close_amount_internal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine_address, trove_id, trove_ltv_ray
) -> (wad: felt) {
    alloc_locals;

    let (close_factor) = get_close_factor(trove_ltv_ray);
    let (debt) = IShrine.estimate(contract_address=shrine_address, trove_id=trove_id);

    // `rmul` of a wad and a ray returns a wad
    let (close_amt) = WadRay.rmul(debt, close_factor);

    let exceeds_debt = is_le(debt, close_amt);
    if (exceeds_debt == TRUE) {
        return (debt,);
    }

    return (close_amt,);
}

func get_purge_penalty_internal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    ltv_ray
) -> (ray: felt) {
    // placeholder
    let (penalty, _) = unsigned_div_rem(ltv_ray, 20);
    return (penalty,);
}

// Helper function to calculate percentage of collateral freed.
// If LTV > 100%. pro-rate based on amount paid down divided by total debt.
// If LTV <= 100%, calculate based on the sum of amount paid down and liquidation penalty divided
// by total trove value.
func get_percentage_freed{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine_address, trove_id, purge_amt_wad, ltv_ray
) -> (ray: felt) {
    let is_covered = is_le(ltv_ray, WadRay.RAY_ONE);
    if (is_covered == FALSE) {
        let (trove_debt) = IShrine.estimate(contract_address=shrine_address, trove_id=trove_id);

        // `runsigned_div` of two wads returns a ray
        let (prorata_percentage_freed_ray) = WadRay.runsigned_div(purge_amt_wad, trove_debt);
        return (prorata_percentage_freed_ray,);
    }

    let (penalty_ray) = get_purge_penalty_internal(ltv_ray);

    // `rmul` of a wad and a ray returns a wad
    let (penalty_amt_wad) = WadRay.rmul(purge_amt_wad, penalty_ray);

    let (freed_amt_wad) = WadRay.add_unsigned(penalty_amt_wad, purge_amt_wad);
    let (_, trove_value_wad) = IShrine.get_trove_threshold(
        contract_address=shrine_address, trove_id=trove_id
    );

    // `runsigned_div` of two wads returns a ray
    let (percentage_freed_ray) = WadRay.runsigned_div(freed_amt_wad, trove_value_wad);

    return (percentage_freed_ray,);
}

// Helper function to loop through yang addresses and transfer freed yang to recipient
func free_yangs{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine_address,
    abbot_address,
    recipient_address,
    trove_id,
    yang_count,
    yang_addresses: felt*,
    percentage_freed_ray,
    freed_assets_wad: felt*,
) {
    alloc_locals;

    if (yang_count == 0) {
        return ();
    }

    free_yang(
        shrine_address,
        abbot_address,
        recipient_address,
        trove_id,
        [yang_addresses],
        percentage_freed_ray,
        freed_assets_wad,
    );
    return free_yangs(
        shrine_address,
        abbot_address,
        recipient_address,
        trove_id,
        yang_count - 1,
        yang_addresses + 1,
        percentage_freed_ray,
        freed_assets_wad + 1,
    );
}

// Helper function to transfer freed yang to recipient for a specific yang
func free_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    shrine_address,
    abbot_address,
    recipient_address,
    trove_id,
    yang_address,
    percentage_freed_ray,
    freed_assets_wad: felt*,
) {
    alloc_locals;

    let (deposited_amt_wad) = IShrine.get_deposit(
        contract_address=shrine_address, yang_address=yang_address, trove_id=trove_id
    );

    // Early termination if no yang deposited
    if (deposited_amt_wad == 0) {
        return ();
    }

    let (gate_address) = IAbbot.get_gate_address(
        contract_address=abbot_address, yang_address=yang_address
    );

    // `rmul` of a wad and a ray returns a wad
    let (freed_yang_wad) = WadRay.rmul(deposited_amt_wad, percentage_freed_ray);

    // Get amount of underlying collateral to free before Shrine is updated
    let (freed_asset_wad) = IGate.preview_withdraw(
        contract_address=gate_address, yang_wad=freed_yang_wad
    );
    assert [freed_assets_wad] = freed_asset_wad;

    IShrine.seize(
        contract_address=shrine_address,
        yang_address=yang_address,
        trove_id=trove_id,
        amount=freed_yang_wad,
    );

    IGate.withdraw(
        contract_address=gate_address,
        user_address=recipient_address,
        trove_id=trove_id,
        assets_wad=freed_asset_wad,
    );

    return ();
}
