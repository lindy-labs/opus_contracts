%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import (
    assert_le,
    assert_in_range,
    assert_not_zero,
    split_felt,
    unsigned_div_rem,
)
from starkware.cairo.common.math_cmp import is_le, is_not_zero
from starkware.cairo.common.uint256 import (
    ALL_ONES,
    Uint256,
    assert_uint256_le,
    uint256_check,
    uint256_sub,
)
from starkware.starknet.common.syscalls import get_block_timestamp, get_caller_address

from contracts.shrine.roles import ShrineRoles

// these imported public functions are part of the contract's interface
from contracts.lib.accesscontrol.accesscontrol_external import (
    change_admin,
    get_admin,
    get_roles,
    grant_role,
    has_role,
    renounce_role,
    revoke_role,
)
from contracts.lib.accesscontrol.library import AccessControl
from contracts.lib.aliases import address, bool, packed, ray, str, ufelt, wad
from contracts.lib.convert import pack_felt, pack_125, unpack_125
from contracts.lib.exp import exp
from contracts.lib.types import PackedTrove, Trove, YangRedistribution
from contracts.lib.wad_ray import WadRay

//
// Constants
//

// Initial multiplier value to ensure `get_recent_multiplier_from` terminates
const INITIAL_MULTIPLIER = WadRay.RAY_ONE;

const MAX_THRESHOLD = WadRay.RAY_ONE;

const TIME_INTERVAL = 30 * 60;  // 30 minutes * 60 seconds per minute
const TIME_INTERVAL_DIV_YEAR = 57077625570776;  // 1 / (48 30-minute segments per day) / (365 days per year) = 0.000057077625 (wad)
// Interest rate piece-wise function parameters - all rays
const RATE_M1 = 2 * 10 ** 25;  // 0.02
const RATE_B1 = 0;
const RATE_M2 = 1 * 10 ** 26;  // 0.1
const RATE_B2 = (-4) * 10 ** 25;  // -0.04
const RATE_M3 = 10 ** 27;  // 1
const RATE_B3 = (-715) * 10 ** 23;  // -0.715
const RATE_M4 = 3101908 * 10 ** 21;  // 3.101908
const RATE_B4 = (-2651908222) * 10 ** 18;  // -2.651908222

// Interest rate piece-wise range bounds (Bound 0 is implicitly zero) - all rays
const RATE_BOUND1 = 5 * 10 ** 26;  // 0.5
const RATE_BOUND2 = 75 * 10 ** 25;  // 0.75
const RATE_BOUND3 = 9215 * 10 ** 23;  // 0.9215

// Threshold for rounding remaining debt during redistribution
const ROUNDING_THRESHOLD = 10 ** 9;

// Maximum interest rate a yang can have (ray)
const MAX_YANG_RATE = 10 * WadRay.RAY_PERCENT;

// Flag for setting the yang's new base rate to its previous base rate in `update_rates`
const USE_PREV_BASE_RATE = -1;

//
// Events
//

@event
func YangAdded(yang: address, yang_id: ufelt, start_price: wad, initial_rate: ray) {
}

@event
func YangTotalUpdated(yang: address, total: wad) {
}

@event
func DebtTotalUpdated(total: wad) {
}

@event
func YangsCountUpdated(count: ufelt) {
}

@event
func MultiplierUpdated(multiplier: ray, cumulative_multiplier: ray, interval: ufelt) {
}

@event
func YangRatesUpdated(
    new_rate_idx: ufelt,
    current_interval: ufelt,
    yangs_len: ufelt,
    yangs: address*,
    new_rates_len: ufelt,
    new_rates: ray*,
) {
}

@event
func ThresholdUpdated(yang: address, threshold: ray) {
}

@event
func TroveUpdated(trove_id: ufelt, trove: Trove) {
}

@event
func TroveRedistributed(redistribution_id: ufelt, trove_id: ufelt, debt: wad) {
}

@event
func DepositUpdated(yang: address, trove_id: ufelt, amount: wad) {
}

@event
func YangPriceUpdated(yang: address, price: wad, cumulative_price: wad, interval: ufelt) {
}

@event
func CeilingUpdated(ceiling: wad) {
}

@event
func Killed() {
}

// ERC20 events
@event
func Transfer(from_: address, to: address, value: Uint256) {
}

@event
func Approval(owner: address, spender: address, value: Uint256) {
}

//
// Storage
//

// A trove can forge debt up to its threshold depending on the yangs deposited.
@storage_var
func shrine_troves(trove_id: ufelt) -> (trove: PackedTrove) {
}

// Stores the amount of the "yin" (synthetic) each user owns.
// yin can be exchanged for ERC20 synthetic tokens via the yin gate.
@storage_var
func shrine_yin(user: address) -> (balance: wad) {
}

// Stores information about the total supply for each yang
@storage_var
func shrine_yang_total(yang_id: ufelt) -> (total: wad) {
}

// Number of collateral accepted by the system.
// The return value is also the ID of the last added collateral.
@storage_var
func shrine_yangs_count() -> (count: ufelt) {
}

// Mapping from yang address to yang ID.
// Yang ID starts at 1.
@storage_var
func shrine_yang_id(yang: address) -> (id: ufelt) {
}

// Keeps track of how much of each yang has been deposited into each Trove - wad
@storage_var
func shrine_deposits(yang_id: ufelt, trove_id: ufelt) -> (balance: wad) {
}

// Total amount of debt accrued
@storage_var
func shrine_total_debt() -> (total_debt: wad) {
}

// Total amount of synthetic forged
@storage_var
func shrine_total_yin() -> (total_yin: wad) {
}

// Keeps track of the price history of each Yang - packed
// interval: timestamp divided by TIME_INTERVAL.
// packed contains both the actual price (high 125 bits) and the cumulative price (low 125 bits) of
// the yang at each time interval, both as wads
@storage_var
func shrine_yang_price(yang_id: ufelt, interval: ufelt) -> (price_and_cumulative_price: packed) {
}

// Total debt ceiling - wad
@storage_var
func shrine_ceiling() -> (ceiling: wad) {
}

// Global interest rate multiplier - packed
// packed contains both the actual multiplier (high 125 bits), and the cumulative multiplier (low 125 bits) of
// the yang at each time interval, both as rays
@storage_var
func shrine_multiplier(interval: ufelt) -> (mul_and_cumulative_mul: packed) {
}

// Keeps track of the most recent rates index
// Each index is associated with an update to the interest rates of all yangs.
@storage_var
func shrine_rates_latest_era() -> (idx: ufelt) {
}

// Keeps track of the interval at which the rate update at `idx` was made.
@storage_var
func shrine_rates_intervals(idx: ufelt) -> (interval: ufelt) {
}

// Keeps track of the interest rate of each yang at each index
@storage_var
func shrine_yang_rates(yang_id: ufelt, idx: ufelt) -> (rate: ray) {
}

// Liquidation threshold per yang (as LTV) - ray
@storage_var
func shrine_thresholds(yang_id: ufelt) -> (threshold: ray) {
}

// Keeps track of how many redistributions have occurred
@storage_var
func shrine_redistributions_count() -> (count: ufelt) {
}

// Last redistribution accounted for a trove
@storage_var
func shrine_trove_redistribution_id(trove_id: ufelt) -> (redistribution_id: ufelt) {
}

// Mapping of yang ID and redistribution ID to a packed value of
// 1. amount of debt in wad to be redistributed to each wad unit of yang
// 2. amount of debt to be added to the next redistribution to calculate (1)
@storage_var
func shrine_yang_redistribution(yang_id: ufelt, redistribuftion_id: ufelt) -> (
    yang_redistribution: packed
) {
}

@storage_var
func shrine_live() -> (is_live: bool) {
}

// Yin storage

@storage_var
func shrine_yin_name() -> (name: str) {
}

@storage_var
func shrine_yin_symbol() -> (symbol: str) {
}

@storage_var
func shrine_yin_decimals() -> (decimals: ufelt) {
}

@storage_var
func shrine_yin_allowances(owner, spender) -> (allowance: Uint256) {
}

//
// Constructor
//

@constructor
func constructor{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(admin: address, name: str, symbol: str) {
    alloc_locals;

    AccessControl.initializer(admin);

    // Grant admin permission
    AccessControl._grant_role(ShrineRoles.DEFAULT_SHRINE_ADMIN_ROLE, admin);

    shrine_live.write(TRUE);

    // Set initial multiplier value
    let current_interval: ufelt = now();
    let previous_interval: ufelt = current_interval - 1;

    // The initial cumulative multiplier is set to `INITIAL_MULTIPLIER`
    let init_mul_cumulative_mul: packed = pack_125(INITIAL_MULTIPLIER, INITIAL_MULTIPLIER);
    // seeding initial multiplier to the previous interval to ensure `get_recent_multiplier_from` terminates
    // otherwise, the next multiplier update will run into an endless loop of `get_recent_multiplier_from`
    // since it wouldn't find the initial multiplier
    shrine_multiplier.write(previous_interval, init_mul_cumulative_mul);

    // Events
    MultiplierUpdated.emit(INITIAL_MULTIPLIER, INITIAL_MULTIPLIER, previous_interval);

    // ERC20
    shrine_yin_name.write(name);
    shrine_yin_symbol.write(symbol);
    shrine_yin_decimals.write(18);

    return ();
}

//
// Getters
//

// Returns a tuple of a trove's threshold, LTV based on compounded debt, trove value and compounded debt
@view
func get_trove_info{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt
) -> (threshold: ray, ltv: ray, value: wad, debt: wad) {
    alloc_locals;

    let interval: ufelt = now();

    // Get threshold and trove value
    let (yang_count: ufelt) = shrine_yangs_count.read();
    let (threshold: ray, value: wad) = get_trove_threshold_and_value_internal(
        trove_id, interval, yang_count, 0, 0
    );

    // Calculate debt
    let (trove: Trove) = get_trove(trove_id);

    // Catch troves with no value
    if (value == 0) {
        let has_debt: bool = is_not_zero(trove.debt);
        if (has_debt == TRUE) {
            // Handles corner case: forging non-zero debt for a trove with zero value
            return (threshold, WadRay.BOUND, value, trove.debt);
        } else {
            return (threshold, 0, value, trove.debt);
        }
    }

    let debt: wad = compound(trove_id, trove, interval, yang_count);
    let debt: wad = pull_redistributed_debt(trove_id, debt, FALSE);
    let ltv: ray = WadRay.runsigned_div(debt, value);  // Using WadRay.runsigned_div on two wads returns a ray
    return (threshold, ltv, value, debt);
}

@view
func get_yin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(user: address) -> (
    balance: wad
) {
    return shrine_yin.read(user);
}

@view
func get_total_yin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    total_yin: wad
) {
    return shrine_total_yin.read();
}

@view
func get_yang_total{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address
) -> (total: wad) {
    let (yang_id: ufelt) = shrine_yang_id.read(yang);
    return shrine_yang_total.read(yang_id);
}

@view
func get_yangs_count{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    count: ufelt
) {
    return shrine_yangs_count.read();
}

@view
func get_deposit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address, trove_id: ufelt
) -> (balance: wad) {
    let (yang_id: ufelt) = shrine_yang_id.read(yang);
    return shrine_deposits.read(yang_id, trove_id);
}

@view
func get_total_debt{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    total_debt: wad
) {
    return shrine_total_debt.read();
}

@view
func get_yang_price{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address, interval: ufelt
) -> (price: wad, cumulative_price: wad) {
    alloc_locals;
    let (yang_id: ufelt) = shrine_yang_id.read(yang);
    let (price_and_cumulative_price: packed) = shrine_yang_price.read(yang_id, interval);
    let (price: wad, cumulative_price: wad) = unpack_125(price_and_cumulative_price);
    return (price, cumulative_price);
}

@view
func get_yang_rate{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address, idx: ufelt
) -> (rate: ray) {
    let (yang_id: ufelt) = shrine_yang_id.read(yang);
    return shrine_yang_rates.read(yang_id, idx);
}

@view
func get_ceiling{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    ceiling: wad
) {
    return shrine_ceiling.read();
}

@view
func get_multiplier{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    interval: ufelt
) -> (multiplier: ray, cumulative_multiplier: ray) {
    alloc_locals;
    let (mul_and_cumulative_mul: packed) = shrine_multiplier.read(interval);
    let (multiplier: ray, cumulative_multiplier: ray) = unpack_125(mul_and_cumulative_mul);
    return (multiplier, cumulative_multiplier);
}

@view
func get_yang_threshold{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address
) -> (threshold: ray) {
    let yang_id: ufelt = get_valid_yang_id(yang);
    return shrine_thresholds.read(yang_id);
}

@view
func get_shrine_threshold_and_value{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}() -> (threshold: ray, value: wad) {
    let current_interval: ufelt = now();
    let (yang_count: ufelt) = shrine_yangs_count.read();
    let (threshold: ray, value: wad) = get_shrine_threshold_and_value_internal(
        current_interval, yang_count, 0, 0
    );
    return (threshold, value);
}

@view
func get_redistributions_count{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    ) -> (count: ufelt) {
    return shrine_redistributions_count.read();
}

@view
func get_trove_redistribution_id{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt
) -> (redistribution_id: ufelt) {
    return shrine_trove_redistribution_id.read(trove_id);
}

@view
func get_redistributed_unit_debt_for_yang{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(yang: address, redistribution_id: ufelt) -> (unit_debt: wad) {
    let yang_id: ufelt = get_valid_yang_id(yang);
    let redistribution: YangRedistribution = get_yang_redistribution(yang_id, redistribution_id);
    return (redistribution.unit_debt,);
}

@view
func get_live{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    is_live: bool
) {
    return shrine_live.read();
}

// ERC20 getters

@view
func name{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (name: str) {
    return shrine_yin_name.read();
}

@view
func symbol{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (symbol: str) {
    return shrine_yin_symbol.read();
}

@view
func decimals{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    decimals: ufelt
) {
    return shrine_yin_decimals.read();
}

@view
func totalSupply{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    total_supply: Uint256
) {
    let (total_yin: wad) = shrine_total_yin.read();
    let (total_supply: Uint256) = WadRay.to_uint(total_yin);
    return (total_supply,);
}

@view
func balanceOf{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    account: address
) -> (balance: Uint256) {
    let (account_yin: wad) = shrine_yin.read(account);
    let (balance: Uint256) = WadRay.to_uint(account_yin);
    return (balance,);
}

@view
func allowance{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    owner: address, spender: address
) -> (allowance: Uint256) {
    return shrine_yin_allowances.read(owner, spender);
}

//
// Setters
//

// `initial_yang_amt` is passed as an argument from upstream to address the issue of
// first depositor front-running by requiring an initial deposit when adding the yang
// to the Shrine
@external
func add_yang{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, threshold: ray, initial_price: wad, initial_rate: ray, initial_yang_amt: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.ADD_YANG);

    // Assert that yang is not already added
    let (potential_yang_id: ufelt) = shrine_yang_id.read(yang);
    with_attr error_message("Shrine: Yang already exists") {
        assert potential_yang_id = 0;
    }

    assert_rate_is_valid(initial_rate);

    // Validity of `threshold` is asserted in set_threshold
    // Validity of `initial_price` is asserted in pack_125

    // Assign ID to yang and add yang struct
    let (yang_count: ufelt) = shrine_yangs_count.read();
    let yang_id: ufelt = yang_count + 1;

    shrine_yang_id.write(yang, yang_id);

    // Update yangs count
    shrine_yangs_count.write(yang_id);

    // Set threshold
    set_threshold(yang, threshold);

    // Update initial yang supply
    // Used upstream to prevent first depositor front running
    shrine_yang_total.write(yang_id, initial_yang_amt);

    // Since `initial_price` is the first price in the price history, the cumulative price is also set to `initial_price`
    let init_price_and_cumulative_price: packed = pack_125(initial_price, initial_price);

    let current_interval: ufelt = now();
    let previous_interval: ufelt = current_interval - 1;
    // seeding initial price to the previous interval to ensure `get_recent_price_from` terminates
    // new prices are pushed to Shrine from an oracle via `advance` and are always set on the current
    // interval (`now()`); if we wouldn't set this initial price to `now() - 1` and oracle could
    // update a price still in the current interval (as oracle update times are independent of
    // Shrine's intervals, a price can be updated multiple times in a single interval) which would
    // result in an endless loop of `get_recent_price_from` since it wouldn't find the initial price
    shrine_yang_price.write(yang_id, previous_interval, init_price_and_cumulative_price);

    // Setting the base rate for the new yang

    // NOTE: Eras are not incremented when a new yang is added, and the era that is being set
    // for this base rate will have an interval that, in practice, is < now(). This would be a problem
    // if there could be a trove containing the newly-added with `trove.last_rate_era < latest_era`.
    // Luckily, this isn't possible because `charge` is called in `deposit`, so a trove's `last_rate_era`
    // will always be updated to `latest_era` immediately before the newly-added yang is deposited.
    let (latest_era: ufelt) = shrine_rates_latest_era.read();
    shrine_yang_rates.write(yang_id, latest_era, initial_rate);

    // Events
    YangAdded.emit(yang, yang_id, initial_price, initial_rate);
    YangsCountUpdated.emit(yang_id);
    YangTotalUpdated.emit(yang, initial_yang_amt);

    return ();
}

@external
func set_ceiling{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(new_ceiling: wad) {
    AccessControl.assert_has_role(ShrineRoles.SET_CEILING);

    with_attr error_message("Shrine: Value of `new_ceiling` ({new_ceiling}) is out of bounds") {
        WadRay.assert_valid_unsigned(new_ceiling);
    }

    shrine_ceiling.write(new_ceiling);

    CeilingUpdated.emit(new_ceiling);

    return ();
}

@external
func set_threshold{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, new_threshold: ray) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.SET_THRESHOLD);

    with_attr error_message("Shrine: Value of `new_threshold` ({new_threshold}) is out of bounds") {
        WadRay.assert_valid_unsigned(new_threshold);
    }

    // Check that threshold value is not greater than max threshold
    with_attr error_message("Shrine: Threshold exceeds 100%") {
        assert_le(new_threshold, MAX_THRESHOLD);
    }

    let yang_id: ufelt = get_valid_yang_id(yang);
    shrine_thresholds.write(yang_id, new_threshold);

    ThresholdUpdated.emit(yang, new_threshold);

    return ();
}

@external
func kill{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}() {
    AccessControl.assert_has_role(ShrineRoles.KILL);

    shrine_live.write(FALSE);

    Killed.emit();

    return ();
}

//
// Core functions - External
//

// Set the price of the specified Yang for a given interval
@external
func advance{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, price: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.ADVANCE);

    with_attr error_message("Shrine: Cannot set a price value to zero") {
        assert_not_zero(price);  // Cannot set a price value to zero
    }

    with_attr error_message("Shrine: Value of `price` ({price}) is out of bounds") {
        WadRay.assert_valid_unsigned(price);
    }

    let interval: ufelt = now();
    let yang_id: ufelt = get_valid_yang_id(yang);

    // Calculating the new cumulative price
    // To do this, we get the interval of the last price update, find the number of
    // intervals BETWEEN the current interval and the last_interval (non-inclusive), multiply that by
    // the last price, and add it to the last cumulative price. Then we add the new price, `price`.
    let (last_price: wad, last_cumulative_price: wad, last_interval: ufelt) = get_recent_price_from(
        yang_id, interval - 1
    );

    with_attr error_message("Shrine: Cumulative price is out of bounds") {
        let new_cumulative: wad = last_cumulative_price + (interval - last_interval - 1) *
            last_price + price;
        let price_and_cumulative_price: packed = pack_125(price, new_cumulative);
    }

    shrine_yang_price.write(yang_id, interval, price_and_cumulative_price);

    YangPriceUpdated.emit(yang, price, new_cumulative, interval);

    return ();
}

// Appends a new multiplier value
@external
func set_multiplier{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(new_multiplier: ray) {
    alloc_locals;
    AccessControl.assert_has_role(ShrineRoles.SET_MULTIPLIER);

    with_attr error_message("Shrine: Cannot set a multiplier value to zero") {
        assert_not_zero(new_multiplier);  // Cannot set a multiplier value to zero
    }

    with_attr error_message(
            "Shrine: Value of `new_multiplier` ({new_multiplier}) is out of bounds") {
        WadRay.assert_valid_unsigned(new_multiplier);
    }

    let interval: ufelt = now();

    let (
        last_multiplier: ray, last_cumulative_multiplier: ray, last_interval: ufelt
    ) = get_recent_multiplier_from(interval - 1);

    with_attr error_message("Shrine: Cumulative multiplier is out of bounds") {
        let new_cumulative_multiplier: ray = last_cumulative_multiplier + (
            interval - last_interval - 1
        ) * last_multiplier + new_multiplier;
        let mul_and_cumulative_mul: packed = pack_125(new_multiplier, new_cumulative_multiplier);
    }

    shrine_multiplier.write(interval, mul_and_cumulative_mul);

    MultiplierUpdated.emit(new_multiplier, new_cumulative_multiplier, interval);

    return ();
}

// Update the base rates of all yangs
// A base rate of USE_PREV_BASE_RATE means the base rate for the yang stays the same
// Takes an array of yangs and their updated rates.
// yangs[i]'s base rate will be set to new_rates[i]
// yangs's length must equal the number of yangs available.
@external
func update_rates{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yangs_len: ufelt, yangs: address*, new_rates_len: ufelt, new_rates: ray*) {
    alloc_locals;
    AccessControl.assert_has_role(ShrineRoles.UPDATE_RATES);

    // Checking that the lengths of the given rates and yangs arrays are equal to the number of yangs
    let (num_yangs: ufelt) = shrine_yangs_count.read();

    with_attr error_message("Shrine: new rates array length is not equal to yang count") {
        assert new_rates_len = num_yangs;
    }

    with_attr error_message("Shrine: yang addresses array length is not equal to yang count") {
        assert yangs_len = num_yangs;
    }

    let (latest_era: ufelt) = shrine_rates_latest_era.read();
    let (latest_era_interval: ufelt) = shrine_rates_intervals.read(latest_era);
    let current_interval: ufelt = now();

    // If the interest rates were already updated in the current interval, don't increment the era
    // Otherwise, increment the era
    // This way, there is at most one set of base rate updates in every interval
    tempvar new_era = latest_era;

    if (latest_era_interval == current_interval) {
        tempvar new_era = new_era;
    } else {
        tempvar new_era = new_era + 1;
    }

    local new_era: ufelt = new_era;  // Revoked references workaround

    // If new_era = latest_era, then the caller will not be charged additional gas
    // for these storage updates.
    shrine_rates_latest_era.write(new_era);
    shrine_rates_intervals.write(new_era, current_interval);

    // Loop over yangs and update rates, and then verify that
    // all yangs' base rates were updated correctly

    let updated_rates: ray* = alloc();
    update_rates_loop(new_era, yangs_len, yangs, new_rates, updated_rates);
    assert_yang_rates_updated_loop(new_era, num_yangs);

    YangRatesUpdated.emit(
        new_era, current_interval, yangs_len, yangs, new_rates_len, updated_rates
    );
    return ();
}

// Move Yang between two Troves
// Checks should be performed beforehand by the module calling this function
@external
func move_yang{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, src_trove_id: ufelt, dst_trove_id: ufelt, amount: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.MOVE_YANG);

    with_attr error_message("Shrine: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    let yang_id: ufelt = get_valid_yang_id(yang);

    // Charge interest for source trove to ensure it remains safe
    charge(src_trove_id);

    // Charge interest for destination trove since its collateral balance will be changed,
    // affecting its personalized interest rate due to the underlying assumption in `compound`
    // TODO: maybe move this under `assert_healthy` call so failed `move_yang` calls are cheaper?
    // It depends on starknet handles fees for failed transactions
    charge(dst_trove_id);

    let (src_yang_balance: wad) = shrine_deposits.read(yang_id, src_trove_id);

    // Ensure source trove has sufficient yang
    with_attr error_message("Shrine: Insufficient yang") {
        // WadRay.unsigned_sub asserts (src_yang_balance - amount) >= 0
        let new_src_balance: wad = WadRay.unsigned_sub(src_yang_balance, amount);
    }

    // Update yang balance of source trove
    shrine_deposits.write(yang_id, src_trove_id, new_src_balance);

    // Assert source trove is within limits
    assert_healthy(src_trove_id);

    // Update yang balance of destination trove
    let (dst_yang_balance: wad) = shrine_deposits.read(yang_id, dst_trove_id);
    let new_dst_balance: wad = WadRay.unsigned_add(dst_yang_balance, amount);
    shrine_deposits.write(yang_id, dst_trove_id, new_dst_balance);

    // Events
    DepositUpdated.emit(yang, src_trove_id, new_src_balance);
    DepositUpdated.emit(yang, dst_trove_id, new_dst_balance);

    return ();
}

// Deposit a specified amount of a Yang into a Trove
@external
func deposit{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, trove_id: ufelt, amount: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.DEPOSIT);

    // Check system is live
    assert_live();

    with_attr error_message("Shrine: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    // Charge interest
    charge(trove_id);

    // Update yang balance of system
    let yang_id: ufelt = get_valid_yang_id(yang);
    let (old_total: wad) = shrine_yang_total.read(yang_id);
    let new_total: wad = WadRay.add(old_total, amount);
    shrine_yang_total.write(yang_id, new_total);

    // Update yang balance of trove
    let (trove_yang_balance: wad) = shrine_deposits.read(yang_id, trove_id);
    let new_trove_balance: wad = WadRay.add(trove_yang_balance, amount);
    shrine_deposits.write(yang_id, trove_id, new_trove_balance);

    // Events
    YangTotalUpdated.emit(yang, new_total);
    DepositUpdated.emit(yang, trove_id, new_trove_balance);

    return ();
}

// Withdraw a specified amount of a Yang from a Trove with trove safety check
@external
func withdraw{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, trove_id: ufelt, amount: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.WITHDRAW);

    withdraw_internal(yang, trove_id, amount);

    // Check if Trove is within limits
    assert_healthy(trove_id);

    return ();
}

// Mint a specified amount of synthetic and attribute the debt to a Trove
@external
func forge{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(user: address, trove_id: ufelt, amount: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.FORGE);

    // Check system is live
    assert_live();

    with_attr error_message("Shrine: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    // Charge interest
    charge(trove_id);  // TODO: Maybe move this under the debt ceiling check to save gas in case of failed tx

    // Get current Trove information
    let (old_trove_info: Trove) = get_trove(trove_id);

    // Get current interval
    let current_interval: ufelt = now();

    // Check that debt ceiling has not been reached
    let (current_system_debt: wad) = shrine_total_debt.read();

    with_attr error_message("Shrine: System debt overflow") {
        let new_system_debt: wad = WadRay.add(current_system_debt, amount);  // WadRay.add checks for overflow
    }

    let (debt_ceiling: wad) = shrine_ceiling.read();

    // Debt ceiling check
    with_attr error_message("Shrine: Debt ceiling reached") {
        assert_le(new_system_debt, debt_ceiling);
    }

    // Update system debt
    shrine_total_debt.write(new_system_debt);

    // Initialise `Trove.charge_from` to current interval if old debt was 0.
    // Otherwise, set `Trove.charge_from` to current interval + 1 because interest has been
    // charged up to current interval.
    if (old_trove_info.debt == 0) {
        tempvar new_charge_from: ufelt = current_interval;
    } else {
        tempvar new_charge_from: ufelt = old_trove_info.charge_from;
    }

    // Update trove information
    let new_debt: wad = WadRay.unsigned_add(old_trove_info.debt, amount);
    let new_trove_info: Trove = Trove(
        charge_from=new_charge_from, debt=new_debt, last_rate_era=old_trove_info.last_rate_era
    );
    set_trove(trove_id, new_trove_info);

    // Check if Trove is within limits
    assert_healthy(trove_id);

    // Update balances
    forge_internal(user, amount);

    // Events
    DebtTotalUpdated.emit(new_system_debt);
    TroveUpdated.emit(trove_id, new_trove_info);

    return ();
}

// Repay a specified amount of synthetic and deattribute the debt from a Trove
@external
func melt{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(user: address, trove_id: ufelt, amount: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.MELT);

    with_attr error_message("Shrine: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    // Charge interest
    charge(trove_id);

    // Get current Trove information
    let (old_trove_info: Trove) = get_trove(trove_id);

    // Get current interval
    let current_interval: ufelt = now();

    // Cap `amount` to trove's debt if it exceeds
    let melt_amt: wad = WadRay.unsigned_min(old_trove_info.debt, amount);

    // Update system debt
    let (current_system_debt: wad) = shrine_total_debt.read();

    with_attr error_message("Shrine: System debt underflow") {
        let new_system_debt: wad = WadRay.unsigned_sub(current_system_debt, melt_amt);  // WadRay.unsigned_sub contains an underflow check
    }

    shrine_total_debt.write(new_system_debt);

    // Will not revert because amount is capped to trove's debt
    let new_debt: wad = WadRay.unsigned_sub(old_trove_info.debt, melt_amt);
    let new_trove_info: Trove = Trove(
        charge_from=current_interval, debt=new_debt, last_rate_era=old_trove_info.last_rate_era
    );
    set_trove(trove_id, new_trove_info);

    // Update balances
    melt_internal(user, melt_amt);

    // Events
    DebtTotalUpdated.emit(new_system_debt);
    TroveUpdated.emit(trove_id, new_trove_info);

    return ();
}

// Withdraw a specified amount of a Yang from a Trove without trove safety check.
// This is intended for liquidations where collateral needs to be withdrawn and transferred to the liquidator
// even if the trove is still unsafe.
@external
func seize{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(yang: address, trove_id: ufelt, amount: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.SEIZE);

    withdraw_internal(yang, trove_id, amount);

    return ();
}

@external
func redistribute{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(trove_id: ufelt) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.REDISTRIBUTE);

    let (yang_count: ufelt) = shrine_yangs_count.read();
    let interval: ufelt = now();
    let (_, trove_value: wad) = get_trove_threshold_and_value_internal(
        trove_id, interval, yang_count, 0, 0
    );

    // Trove's debt should have been updated to the current interval via `melt` in `Purger.purge`.
    // The trove's debt is used instead of estimated debt from `get_trove_info` to ensure that
    // system has accounted for the accrued interest.
    let trove: Trove = get_trove(trove_id);

    // Get current redistribution ID and update
    let prev_redistribution_id: ufelt = shrine_redistributions_count.read();
    let redistribution_id: ufelt = prev_redistribution_id + 1;
    shrine_redistributions_count.write(redistribution_id);

    // Perform redistribution
    let redistributed_debt = redistribute_internal(
        redistribution_id, trove_id, trove_value, trove.debt, yang_count, interval, 0
    );

    let updated_trove_info: Trove = Trove(
        charge_from=interval, debt=0, last_rate_era=trove.last_rate_era
    );
    set_trove(trove_id, updated_trove_info);

    TroveRedistributed.emit(redistribution_id, trove_id, redistributed_debt);

    return ();
}

// Mint a specified amount of synthetic without attributing the debt to a Trove
@external
func inject{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(receiver: address, amount: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.INJECT);

    with_attr error_message("Shrine: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    // Update balances
    forge_internal(receiver, amount);

    return ();
}

// Repay a specified amount of synthetic without deattributing the debt from a Trove
@external
func eject{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(receiver: address, amount: wad) {
    alloc_locals;

    AccessControl.assert_has_role(ShrineRoles.EJECT);

    with_attr error_message("Shrine: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    // Update balances
    melt_internal(receiver, amount);

    return ();
}

//
// Core Functions - public ERC20
//

@external
func transfer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    recipient: address, amount: Uint256
) -> (success: bool) {
    let (sender: address) = get_caller_address();
    _transfer(sender, recipient, amount);
    return (TRUE,);
}

@external
func transferFrom{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    sender: address, recipient: address, amount: Uint256
) -> (success: bool) {
    let (caller: address) = get_caller_address();
    _spend_allowance(sender, caller, amount);
    _transfer(sender, recipient, amount);
    return (TRUE,);
}

@external
func approve{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    spender: address, amount: Uint256
) -> (success: bool) {
    let (caller: address) = get_caller_address();
    _approve(caller, spender, amount);
    return (TRUE,);
}

//
// Core Functions - View
//

// Get the last updated price for a yang
@view
func get_current_yang_price{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang
) -> (price: wad, cumulative_price: wad, interval: ufelt) {
    alloc_locals;

    let (yang_id: ufelt) = shrine_yang_id.read(yang);
    let interval: ufelt = now();  // Get current interval
    return get_recent_price_from(yang_id, interval);
}

// Gets last updated multiplier value
@view
func get_current_multiplier{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    multiplier: ray, cumulative_multiplier: ray, interval: ufelt
) {
    let interval: ufelt = now();
    return get_recent_multiplier_from(interval);
}

// Returns a bool indicating whether the given trove is healthy or not
@view
func is_healthy{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt
) -> (healthy: bool) {
    let (threshold: ray, ltv: ray, _, _) = get_trove_info(trove_id);
    return (is_le(ltv, threshold),);
}

@view
func get_max_forge{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt
) -> (max: wad) {
    let (threshold: ray, _, value: wad, debt: wad) = get_trove_info(trove_id);

    // Calculate the maximum amount of debt the trove can have
    let max_debt: wad = WadRay.rmul(threshold, value);

    // Early termination if trove cannot forge new debt
    let can_forge: bool = is_le(debt, max_debt);
    if (can_forge == FALSE) {
        return (0,);
    }

    let max_forge_amt: wad = max_debt - debt;
    return (max_forge_amt,);
}

//
// Internal
//

func assert_live{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    // Check system is live
    let (live: bool) = shrine_live.read();

    with_attr error_message("Shrine: System is not live") {
        assert live = TRUE;
    }

    return ();
}

// Helper function to get the yang ID given a yang address, and throw an error if
// yang address has not been added (i.e. yang ID = 0)
func get_valid_yang_id{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address
) -> ufelt {
    let (yang_id: ufelt) = shrine_yang_id.read(yang);

    with_attr error_message("Shrine: Yang does not exist") {
        assert_not_zero(yang_id);
    }

    return yang_id;
}

func get_trove{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt
) -> (trove: Trove) {
    alloc_locals;
    let (trove_packed: PackedTrove) = shrine_troves.read(trove_id);
    let (charge_from: ufelt, debt: wad) = unpack_125(trove_packed.info);
    let trove: Trove = Trove(
        charge_from=charge_from, debt=debt, last_rate_era=trove_packed.last_rate_era
    );
    return (trove,);
}

func set_trove{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt, trove: Trove
) {
    let info: packed = pack_125(trove.charge_from, trove.debt);
    shrine_troves.write(trove_id, PackedTrove(info=info, last_rate_era=trove.last_rate_era));
    return ();
}

func get_yang_redistribution{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang_id: ufelt, redistribution_id: ufelt
) -> (yang_redistribution: YangRedistribution) {
    let (redistribution_packed: packed) = shrine_yang_redistribution.read(
        yang_id, redistribution_id
    );
    let (unit_debt: wad, error: wad) = split_felt(redistribution_packed);
    let yang_redistribution: YangRedistribution = YangRedistribution(
        unit_debt=unit_debt, error=error
    );
    return (yang_redistribution,);
}

func set_yang_redistribution{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang_id: ufelt, redistribution_id: ufelt, yang_redistribution: YangRedistribution
) {
    let packed_redistribution: packed = pack_felt(
        yang_redistribution.unit_debt, yang_redistribution.error
    );
    shrine_yang_redistribution.write(yang_id, redistribution_id, packed_redistribution);
    return ();
}

func now{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> ufelt {
    let (time: ufelt) = get_block_timestamp();
    let (interval: ufelt, _) = unsigned_div_rem(time, TIME_INTERVAL);
    return interval;
}

func forge_internal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    user: address, amount: wad
) {
    with_attr error_message("Shrine: Forge overflow") {
        // Update user's yin
        let (user_yin: wad) = shrine_yin.read(user);
        shrine_yin.write(user, WadRay.unsigned_add(user_yin, amount));

        // Update total yin
        let (total_yin: wad) = shrine_total_yin.read();
        shrine_total_yin.write(WadRay.unsigned_add(total_yin, amount));
    }

    let (amount_uint: Uint256) = WadRay.to_uint(amount);
    Transfer.emit(0, user, amount_uint);

    return ();
}

func melt_internal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    user: address, amount: wad
) {
    // Reverts if amount > user_yin or amount > total_yin.
    with_attr error_message("Shrine: Not enough yin to melt debt") {
        // Update user's yin
        let (user_yin: wad) = shrine_yin.read(user);
        shrine_yin.write(user, WadRay.unsigned_sub(user_yin, amount));

        // Update total yin
        let (total_yin: wad) = shrine_total_yin.read();
        shrine_total_yin.write(WadRay.unsigned_sub(total_yin, amount));
    }

    let (amount_uint: Uint256) = WadRay.to_uint(amount);
    Transfer.emit(user, 0, amount_uint);

    return ();
}

// Withdraw a specified amount of a Yang from a Trove
func withdraw_internal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address, trove_id: ufelt, amount: wad
) {
    alloc_locals;

    with_attr error_message("Shrine: Value of `amount` ({amount}) is out of bounds") {
        WadRay.assert_valid_unsigned(amount);
    }

    // Retrieve yang info
    let yang_id: ufelt = get_valid_yang_id(yang);
    let (old_total: wad) = shrine_yang_total.read(yang_id);

    // Ensure trove has sufficient yang
    let (trove_yang_balance: wad) = shrine_deposits.read(yang_id, trove_id);

    with_attr error_message("Shrine: Insufficient yang") {
        // WadRay.unsigned_sub asserts (trove_yang_balance - amount) >= 0
        let new_trove_balance: wad = WadRay.unsigned_sub(trove_yang_balance, amount);
    }

    // Charge interest
    charge(trove_id);

    // Update yang balance of system
    let new_total: wad = WadRay.unsigned_sub(old_total, amount);
    shrine_yang_total.write(yang_id, new_total);

    // Update yang balance of trove
    shrine_deposits.write(yang_id, trove_id, new_trove_balance);

    // Events
    YangTotalUpdated.emit(yang, new_total);
    DepositUpdated.emit(yang, trove_id, new_trove_balance);

    return ();
}

// Internal function for looping over all yangs and updating their base rates
// ALL yangs must have a new rate value. A new rate value of `USE_PREV_BASE_RATE` means the
// yang's rate isn't being updated, and so we get the previous value.
func update_rates_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    new_idx: ufelt, num_yangs: ufelt, yangs: address*, new_rates: ray*, updated_rates: ray*
) {
    alloc_locals;

    // Termination condition
    if (num_yangs == 0) {
        return ();
    }

    let current_yang_id: ufelt = get_valid_yang_id([yangs]);
    let current_new_rate: ray = [new_rates];

    if (current_new_rate == USE_PREV_BASE_RATE) {
        let (prev_rate: ray) = shrine_yang_rates.read(current_yang_id, new_idx - 1);
        shrine_yang_rates.write(current_yang_id, new_idx, prev_rate);
        assert [updated_rates] = prev_rate;
        return update_rates_loop(
            new_idx, num_yangs - 1, yangs + 1, new_rates + 1, updated_rates + 1
        );
    } else {
        with_attr error_message(
                "Shrine: `new_rates` value of ({[new_rates]}) for `yang_id` ({current_yang_id}) is out of bounds") {
            // Asserts that `current_new_rate` is in the range (0, MAX_YANG_RATE]
            assert_rate_is_valid(current_new_rate);
        }
        shrine_yang_rates.write(current_yang_id, new_idx, current_new_rate);
        assert [updated_rates] = current_new_rate;
        return update_rates_loop(
            new_idx, num_yangs - 1, yangs + 1, new_rates + 1, updated_rates + 1
        );
    }
}

// Function that loops over all yangs and checks that their base rates have all been updated
// A value of zero is taken to mean that the yang's rate hasn't been updated
// This means that no yang can have an interest rate of exactly 0.
// `current_yang_id` must start at `yangs_count` in order to iterate over all yangs
func assert_yang_rates_updated_loop{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(rate_idx: ufelt, current_yang_id: ufelt) {
    alloc_locals;
    let (rate: ray) = shrine_yang_rates.read(current_yang_id, rate_idx);
    with_attr error_message("Shrine: Yang with ID ({current_yang_id}) was not correctly updated") {
        assert_not_zero(rate);
    }

    // End the loop once all yangs have been checked
    if (current_yang_id == 1) {
        return ();
    }

    assert_yang_rates_updated_loop(rate_idx, current_yang_id - 1);
    return ();
}

// Asserts that `current_new_rate` is in the range (0, MAX_YANG_RATE]
func assert_rate_is_valid{range_check_ptr}(rate: ray) {
    assert_in_range(rate, 1, MAX_YANG_RATE + 1);
    return ();
}

// Adds the accumulated interest as debt to the trove
func charge{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(trove_id) {
    alloc_locals;
    // Get trove info
    let (trove: Trove) = get_trove(trove_id);

    // Early termination if no debt
    if (trove.debt == 0) {
        return ();
    }

    // Get current interval and yang count
    let current_interval: ufelt = now();
    let (yang_count: ufelt) = shrine_yangs_count.read();

    // Get new debt amount
    let compounded_debt: wad = compound(trove_id, trove, current_interval, yang_count);

    // Pull undistributed debt and update state
    let new_debt: wad = pull_redistributed_debt(trove_id, compounded_debt, TRUE);

    // Catch troves with zero value
    if (new_debt == trove.debt) {
        return ();
    }

    // Update trove
    let (latest_era: ufelt) = shrine_rates_latest_era.read();
    let updated_trove: Trove = Trove(
        charge_from=current_interval, debt=new_debt, last_rate_era=latest_era
    );
    set_trove(trove_id, updated_trove);

    // Get old system debt amount
    let (old_system_debt: wad) = shrine_total_debt.read();

    // Get interest charged; should not include redistributed debt
    let diff: wad = WadRay.unsigned_sub(compounded_debt, trove.debt);  // TODO: should this be unchecked? `new_debt` >= `trove.debt` is guaranteed

    // Get new system debt
    tempvar new_system_debt: wad = old_system_debt + diff;

    shrine_total_debt.write(new_system_debt);

    // Events
    DebtTotalUpdated.emit(new_system_debt);
    TroveUpdated.emit(trove_id, updated_trove);

    return ();
}

// Returns the amount of debt owed by trove after having interest charged over a given time period
// Assumes the trove hasn't minted or paid back any additional debt during the given time period
// Assumes the trove hasn't deposited or withdrawn any additional collateral during the given time period
// Time period includes `end_interval` and does NOT include `start_interval`.

// Compound interest formula: P(t) = P_0 * e^(rt)
// P_0 = principal
// r = nominal interest rate (what the interest rate would be if there was no compounding
// t = time elapsed, in years

func compound{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt, trove: Trove, end_interval: ufelt, num_yangs: ufelt
) -> wad {
    alloc_locals;
    // Saves gas and prevents bugs for troves with no yangs deposited
    if (trove.debt == 0) {
        return 0;
    }

    let (latest_rate_era: ufelt) = shrine_rates_latest_era.read();

    return compound_inner_loop(
        trove_id,
        trove.debt,
        num_yangs,
        trove.charge_from,
        end_interval,
        trove.last_rate_era,
        latest_rate_era,
    );
}

// `trove_last_rate_era` should always be less than or equal to `latest_rate_era`
// Compound interest formula: P(t) = P_0 * e^(rt)
// P_0 = principal
// r = nominal interest rate (what the interest rate would be if there was no compounding
// t = time elapsed, in years
func compound_inner_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt,
    current_debt: wad,
    num_yangs: ufelt,
    start_interval: ufelt,
    end_interval: ufelt,
    trove_last_rate_era: ufelt,
    latest_rate_era: ufelt,
) -> wad {
    alloc_locals;

    if (trove_last_rate_era == latest_rate_era) {
        let avg_base_rate: ray = get_avg_rate_over_era(
            trove_id, start_interval, end_interval, latest_rate_era, 0, 0, num_yangs
        );

        let avg_multiplier: ray = get_avg_multiplier(start_interval, end_interval);
        let avg_rate: ray = WadRay.rmul(avg_base_rate, avg_multiplier);

        let t: wad = (end_interval - start_interval) * TIME_INTERVAL_DIV_YEAR;  // represents `t` in the compound interest formula
        let compounded_scalar: wad = exp(WadRay.rmul(avg_rate, t));
        let compounded_debt: wad = WadRay.wmul(current_debt, compounded_scalar);

        return compounded_debt;
    } else {
        let next_rate_update_idx: ufelt = trove_last_rate_era + 1;
        let (next_rate_update_idx_interval: ufelt) = shrine_rates_intervals.read(
            next_rate_update_idx
        );

        let avg_base_rate: ray = get_avg_rate_over_era(
            trove_id,
            start_interval,
            next_rate_update_idx_interval,
            trove_last_rate_era,
            0,
            0,
            num_yangs,
        );
        let avg_multiplier: ray = get_avg_multiplier(start_interval, next_rate_update_idx_interval);
        let avg_rate: ray = WadRay.rmul(avg_base_rate, avg_multiplier);
        let t: wad = (next_rate_update_idx_interval - start_interval) * TIME_INTERVAL_DIV_YEAR;  // represents `t` in the compound interest formula
        let compounded_scalar: wad = exp(WadRay.rmul(avg_rate, t));
        let compounded_debt: wad = WadRay.wmul(current_debt, compounded_scalar);

        return compound_inner_loop(
            trove_id,
            compounded_debt,
            num_yangs,
            next_rate_update_idx_interval,
            end_interval,
            next_rate_update_idx,
            latest_rate_era,
        );
    }
}

// Returns the average interest rate charged to a trove from `start_interval` to `end_interval`,
// Assumes that the time from `start_interval` to `end_interval` spans only a single "era".
// An era is the time between two interest rate updates, during which all yang interest rates are constant.
//
// Also assumes that the trove's debt, and the trove's yang deposits
// remain constant over the entire time period.
// Should start at current_yang_id = yang_count, and recurses until it hits yang_id == 0
func get_avg_rate_over_era{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt,
    start_interval: ufelt,
    end_interval: ufelt,
    rate_idx: ufelt,
    cum_weighted_sum: ray,
    cum_yang_value: wad,
    current_yang_id: ufelt,
) -> ray {
    alloc_locals;

    // If all yangs have been iterated over, return the average rate
    if (current_yang_id == 0) {
        // This would be a problem if the total trove value was ever zero.
        // However, `cum_yang_value` cannot be zero because a trove with no yangs deposited
        // cannot have any debt, meaning this code would never run (see `compound`)
        let avg_base_rate: ray = WadRay.wunsigned_div(cum_weighted_sum, cum_yang_value);
        return avg_base_rate;
    }

    // Early termination if this yang hasn't been deposited in the trove
    let yang_deposited: wad = shrine_deposits.read(current_yang_id, trove_id);
    if (yang_deposited == 0) {
        return get_avg_rate_over_era(
            trove_id,
            start_interval,
            end_interval,
            rate_idx,
            cum_weighted_sum,
            cum_yang_value,
            current_yang_id - 1,
        );
    }

    let yang_rate: ray = shrine_yang_rates.read(current_yang_id, rate_idx);
    let (avg_price: wad) = get_avg_price(current_yang_id, start_interval, end_interval);
    let yang_value: wad = WadRay.wmul(yang_deposited, avg_price);
    let weighted_rate: ray = WadRay.wmul(yang_value, yang_rate);  // wmul of wad and ray is a ray
    let new_cum_weighted_sum: ray = WadRay.add(cum_weighted_sum, weighted_rate);
    let new_cum_yang_value: wad = WadRay.add(cum_yang_value, yang_value);

    return get_avg_rate_over_era(
        trove_id,
        start_interval,
        end_interval,
        rate_idx,
        new_cum_weighted_sum,
        new_cum_yang_value,
        current_yang_id - 1,
    );
}

// Loop through yangs for the trove:
// 1. set the deposit to 0
// 2. calculate the redistributed debt for that yang and fixed point division error, and write to storage
//
// Returns the total amount of debt redistributed.
func redistribute_internal{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(
    redistribution_id: ufelt,
    trove_id: ufelt,
    trove_value: wad,
    trove_debt: wad,
    current_yang_id: ufelt,
    current_interval: ufelt,
    redistributed_debt: wad,
) -> wad {
    alloc_locals;

    if (current_yang_id == 0) {
        return redistributed_debt;
    }

    let deposited: wad = shrine_deposits.read(current_yang_id, trove_id);
    if (deposited == 0) {
        return redistribute_internal(
            redistribution_id,
            trove_id,
            trove_value,
            trove_debt,
            current_yang_id - 1,
            current_interval,
            redistributed_debt,
        );
    }

    // Set the yang amount to 0, causing the exchange rate from yang to the underlying asset
    // in Gate to automatically rebase
    shrine_deposits.write(current_yang_id, trove_id, 0);

    // Update yang balance of system
    let old_yang_total: wad = shrine_yang_total.read(current_yang_id);

    // Decrementing the system's yang balance by the amount deposited in the trove has the effect of
    // rebasing (i.e. appreciating) the ratio of asset to yang for the remaining troves.
    // By removing the distributed yangs from the system, it distributes the assets between
    // the remaining yangs.
    let new_yang_total: wad = WadRay.unsigned_sub(old_yang_total, deposited);
    shrine_yang_total.write(current_yang_id, new_yang_total);

    // Calculate (value of yang / trove value) * debt and assign redistributed debt to yang
    let (yang_price: wad, _, _) = get_recent_price_from(current_yang_id, current_interval);
    let yang_value: wad = WadRay.wmul(deposited, yang_price);
    let raw_debt_to_distribute: wad = WadRay.wmul(
        WadRay.wunsigned_div(yang_value, trove_value), trove_debt
    );

    let (debt_to_distribute: wad, updated_redistributed_debt: wad) = round_distributed_debt(
        trove_debt, raw_debt_to_distribute, redistributed_debt
    );

    // Adjust debt to distribute by adding the error from the last redistribution
    let last_error: wad = get_recent_redistribution_error_for_yang(
        current_yang_id, redistribution_id - 1
    );
    let adjusted_debt_to_distribute: wad = WadRay.unsigned_add(debt_to_distribute, last_error);

    let unit_debt: wad = WadRay.wunsigned_div(adjusted_debt_to_distribute, new_yang_total);

    // Due to loss of precision from fixed point division, the actual debt distributed will be less than
    // or equal to the amount of debt to distribute.
    let actual_debt_distributed: wad = WadRay.wmul(unit_debt, new_yang_total);
    let new_error: wad = WadRay.unsigned_sub(adjusted_debt_to_distribute, actual_debt_distributed);
    let current_yang_redistribution: YangRedistribution = YangRedistribution(
        unit_debt=unit_debt, error=new_error
    );
    set_yang_redistribution(current_yang_id, redistribution_id, current_yang_redistribution);

    // Continue iteration if there is no dust
    if (debt_to_distribute == raw_debt_to_distribute) {
        return redistribute_internal(
            redistribution_id,
            trove_id,
            trove_value,
            trove_debt,
            current_yang_id - 1,
            current_interval,
            updated_redistributed_debt,
        );
    }

    // Otherwise, if debt is rounded up and fully redistributed, skip the remaining yangs
    return updated_redistributed_debt;
}

// Returns the last error for `yang_id` at a given `redistribution_id` if the packed value is non-zero.
// Otherwise, check `redistribution_id` - 1 recursively for the last error.
func get_recent_redistribution_error_for_yang{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(yang_id: ufelt, redistribution_id: ufelt) -> (error: wad) {
    alloc_locals;

    if (redistribution_id == 0) {
        return (0,);
    }

    let (packed_yang_redistribution: packed) = shrine_yang_redistribution.read(
        yang_id, redistribution_id
    );
    if (packed_yang_redistribution != 0) {
        let (_, error: wad) = split_felt(packed_yang_redistribution);
        return (error,);
    }

    return get_recent_redistribution_error_for_yang(yang_id, redistribution_id - 1);
}

// Helper function to round up the debt to be redistributed for a yang if the remaining debt
// falls below the defined threshold, so as to avoid rounding errors and ensure that the amount
// of debt redistributed is equal to the trove's debt
func round_distributed_debt{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    total_debt_to_distribute: wad,
    remaining_debt_to_distribute: wad,
    cumulative_redistributed_debt: wad,
) -> (total_debt_to_distribute: wad, cumulative_redistributed_debt: wad) {
    alloc_locals;

    let updated_cumulative_redistributed_debt = remaining_debt_to_distribute +
        cumulative_redistributed_debt;
    let remaining_debt: wad = total_debt_to_distribute - updated_cumulative_redistributed_debt;
    let round_up: bool = is_le(remaining_debt, ROUNDING_THRESHOLD);
    if (round_up == TRUE) {
        return (
            remaining_debt_to_distribute + remaining_debt,
            updated_cumulative_redistributed_debt + remaining_debt,
        );
    }
    return (remaining_debt_to_distribute, updated_cumulative_redistributed_debt);
}

// Takes in a value for the trove's debt, and returns the updated value after adding
// the redistributed debt, if any.
// Takes in a boolean flag to determine whether the redistribution ID for the trove should be updated.
// Any state update of the trove's debt should be performed in the caller function.
func pull_redistributed_debt{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt, trove_debt: wad, update_redistribution_id: bool
) -> (new_debt: wad) {
    alloc_locals;

    let latest_redistribution_id: ufelt = shrine_redistributions_count.read();
    let trove_last_redistribution_id: ufelt = shrine_trove_redistribution_id.read(trove_id);

    // Early termination if no redistributions since trove was last updated
    if (latest_redistribution_id == trove_last_redistribution_id) {
        return (trove_debt,);
    }

    let (yang_count: ufelt) = shrine_yangs_count.read();
    let new_debt: wad = pull_redistributed_debt_outer_loop(
        trove_last_redistribution_id, latest_redistribution_id, trove_id, trove_debt, yang_count
    );

    if (update_redistribution_id == TRUE) {
        shrine_trove_redistribution_id.write(trove_id, latest_redistribution_id);
        return (new_debt,);
    }

    return (new_debt,);
}

// Outer loop iterating over the trove's yangs
func pull_redistributed_debt_outer_loop{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    last_redistribution_id: ufelt,
    current_redistribution_id: ufelt,
    trove_id: ufelt,
    trove_debt: wad,
    current_yang_id: ufelt,
) -> (new_debt: wad) {
    alloc_locals;

    if (current_yang_id == 0) {
        return (trove_debt,);
    }

    let deposited: wad = shrine_deposits.read(current_yang_id, trove_id);
    if (deposited == 0) {
        return pull_redistributed_debt_outer_loop(
            last_redistribution_id,
            current_redistribution_id,
            trove_id,
            trove_debt,
            current_yang_id - 1,
        );
    }

    let debt_increment: wad = pull_redistributed_debt_inner_loop(
        last_redistribution_id, current_redistribution_id, current_yang_id, deposited, 0
    );

    return pull_redistributed_debt_outer_loop(
        last_redistribution_id,
        current_redistribution_id,
        trove_id,
        trove_debt + debt_increment,
        current_yang_id - 1,
    );
}

// Inner loop iterating over the redistribution IDs for each of the trove's yangs
func pull_redistributed_debt_inner_loop{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    last_redistribution_id: ufelt,
    current_redistribution_id: ufelt,
    yang_id: ufelt,
    yang_amt: wad,
    cumulative_debt: wad,
) -> (debt: wad) {
    alloc_locals;

    if (last_redistribution_id == current_redistribution_id) {
        return (cumulative_debt,);
    }

    // Get the amount of debt per yang for the current redistribution
    let redistribution: YangRedistribution = get_yang_redistribution(
        yang_id, current_redistribution_id
    );

    // Early termination if no debt was distributed for given yang
    if (redistribution.unit_debt == 0) {
        return pull_redistributed_debt_inner_loop(
            last_redistribution_id,
            current_redistribution_id - 1,
            yang_id,
            yang_amt,
            cumulative_debt,
        );
    }

    let debt_increment: wad = WadRay.wmul(yang_amt, redistribution.unit_debt);
    let cumulative_debt: wad = cumulative_debt + debt_increment;
    return pull_redistributed_debt_inner_loop(
        last_redistribution_id, current_redistribution_id - 1, yang_id, yang_amt, cumulative_debt
    );
}

// Returns the price for `yang_id` at `interval` if it is non-zero.
// Otherwise, check `interval` - 1 recursively for the last available price.
func get_recent_price_from{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang_id, interval
) -> (price: wad, cumulative_price: wad, interval: ufelt) {
    alloc_locals;
    let (price_and_cumulative_price: packed) = shrine_yang_price.read(yang_id, interval);

    if (price_and_cumulative_price != 0) {
        let (price: wad, cumulative_price: wad) = unpack_125(price_and_cumulative_price);
        return (price, cumulative_price, interval);
    }

    return get_recent_price_from(yang_id, interval - 1);
}

// Returns the average price for a yang between two intervals, including `end_interval` but NOT including `start_interval`
// - If `start_interval` is the same as `end_interval`, return the price at that interval.
// - If `start_interval` is different from `end_interval`, return the average price.
// Return value is a tuple so that function can be modified as an external view for testing
func get_avg_price{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang_id: ufelt, start_interval: ufelt, end_interval: ufelt
) -> (price: wad) {
    alloc_locals;

    let (
        start_yang_price: wad, start_cumulative_yang_price: wad, available_start_interval: ufelt
    ) = get_recent_price_from(yang_id, start_interval);

    let (
        end_yang_price: wad, end_cumulative_yang_price: wad, available_end_interval
    ) = get_recent_price_from(yang_id, end_interval);

    // If the last available price for both start and end intervals are the same,
    // return that last available price
    // This also catches `start_interval == end_interval`
    if (available_start_interval == available_end_interval) {
        return (start_yang_price,);
    }

    // subtraction operations can be unchecked since the `end_` vars are
    // guaranteed to be greater than or equal to the `start_` variables
    let cumulative_diff: wad = end_cumulative_yang_price - start_cumulative_yang_price;

    // Early termination if `start_interval` and `end_interval` are updated
    if (start_interval == available_start_interval and end_interval == available_end_interval) {
        let (avg_price: wad, _) = unsigned_div_rem(cumulative_diff, end_interval - start_interval);
        return (avg_price,);
    }

    // If the start interval is not updated, adjust the cumulative difference (see `advance`) by deducting
    // (number of intervals missed from `available_start_interval` to `start_interval` * start price).
    if (start_interval == available_start_interval) {
        tempvar intermediate_adjusted_cumulative_diff: wad = cumulative_diff;
    } else {
        let cumulative_offset: wad = (start_interval - available_start_interval) * start_yang_price;
        tempvar intermediate_adjusted_cumulative_diff: wad = cumulative_diff - cumulative_offset;
    }

    // If the end interval is not updated, adjust the cumulative difference by adding
    // (number of intervals missed from `available_end_interval` to `end_interval` * end price).
    if (end_interval == available_end_interval) {
        tempvar final_adjusted_cumulative_diff: wad = intermediate_adjusted_cumulative_diff;
    } else {
        let cumulative_offset: wad = (end_interval - available_end_interval) * end_yang_price;
        tempvar final_adjusted_cumulative_diff: wad = intermediate_adjusted_cumulative_diff +
            cumulative_offset;
    }

    let (avg_price: wad, _) = unsigned_div_rem(
        final_adjusted_cumulative_diff, end_interval - start_interval
    );
    return (avg_price,);
}

// Returns the multiplier at `interval` if it is non-zero.
// Otherwise, check `interval` - 1 recursively for the last available value.
func get_recent_multiplier_from{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    interval: ufelt
) -> (multiplier: ray, cumulative_multiplier: ray, interval: ufelt) {
    alloc_locals;
    let (mul_and_cumulative_mul: packed) = shrine_multiplier.read(interval);

    if (mul_and_cumulative_mul != 0) {
        let (multiplier: ray, cumulative_multiplier: ray) = unpack_125(mul_and_cumulative_mul);
        return (multiplier, cumulative_multiplier, interval);
    }

    return get_recent_multiplier_from(interval - 1);
}

// Returns the average multiplier over the specified time period, including `end_interval` but NOT including `start_interval`
// - If `start_interval` is the same as `end_interval`, return the multiplier value at that interval.
// - If `start_interval` is different from `end_interval`, return the average.
// Return value is a tuple so that function can be modified as an external view for testing
func get_avg_multiplier{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    start_interval: ufelt, end_interval: ufelt
) -> (multiplier: ray) {
    alloc_locals;

    let (
        start_multiplier: ray, start_cumulative_multiplier: ray, available_start_interval
    ) = get_recent_multiplier_from(start_interval);

    let (
        end_multiplier: ray, end_cumulative_multiplier: ray, available_end_interval
    ) = get_recent_multiplier_from(end_interval);

    // If the last available multiplier for both start and end intervals are the same,
    // return that last available multiplier
    // This also catches `start_interval == end_interval`
    if (available_start_interval == available_end_interval) {
        return (start_multiplier,);
    }

    // subtraction operations can be unchecked since the `end_` vars are
    // guaranteed to be greater than or equal to the `start_` variables
    let cumulative_diff: ray = end_cumulative_multiplier - start_cumulative_multiplier;

    // Early termination if `start_interval` and `end_interval` are updated
    if (start_interval == available_start_interval and end_interval == available_end_interval) {
        let (avg_multiplier: wad, _) = unsigned_div_rem(
            cumulative_diff, end_interval - start_interval
        );
        return (avg_multiplier,);
    }

    // If the start interval is not updated, adjust the cumulative difference (see `advance`) by deducting
    // (number of intervals missed from `available_start_interval` to `start_interval` * start price).
    if (start_interval == available_start_interval) {
        tempvar intermediate_adjusted_cumulative_diff: wad = cumulative_diff;
    } else {
        let neg_cumulative_offset: wad = (start_interval - available_start_interval) *
            start_multiplier;
        tempvar intermediate_adjusted_cumulative_diff: wad = cumulative_diff -
            neg_cumulative_offset;
    }

    // If the end interval is not updated, adjust the cumulative difference by adding
    // (number of intervals missed from `available_end_interval` to `end_interval` * end price).
    if (end_interval == available_end_interval) {
        tempvar final_adjusted_cumulative_diff: wad = intermediate_adjusted_cumulative_diff;
    } else {
        let pos_cumulative_offset: wad = (end_interval - available_end_interval) * end_multiplier;
        tempvar final_adjusted_cumulative_diff: wad = intermediate_adjusted_cumulative_diff +
            pos_cumulative_offset;
    }

    let (avg_multiplier: wad, _) = unsigned_div_rem(
        final_adjusted_cumulative_diff, end_interval - start_interval
    );
    return (avg_multiplier,);
}

//
// Trove health internal functions
//

func assert_healthy{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    trove_id: ufelt
) {
    alloc_locals;

    let (healthy: bool) = is_healthy(trove_id);

    with_attr error_message("Shrine: Trove LTV is too high") {
        assert healthy = TRUE;
    }

    return ();
}

// Returns a tuple of the custom threshold (maximum LTV before liquidation) of a trove and the total trove value, at a given interval.
// This function can use historical prices but the currently deposited yang amounts to calculate value.
// The underlying assumption is that the amount of each yang deposited at `interval` is the same as the amount currently deposited.
func get_trove_threshold_and_value_internal{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    trove_id: ufelt,
    interval: ufelt,
    current_yang_id: ufelt,
    cumulative_weighted_threshold: ray,
    cumulative_trove_value: wad,
) -> (threshold: ray, value: wad) {
    alloc_locals;

    if (current_yang_id == 0) {
        if (cumulative_trove_value != 0) {
            // WadRay.wunsigned_div, with the numerator a ray, and the denominator a wad, returns a ray
            let threshold: ray = WadRay.wunsigned_div(
                cumulative_weighted_threshold, cumulative_trove_value
            );
            return (threshold=threshold, value=cumulative_trove_value);
        } else {
            return (threshold=0, value=0);
        }
    }

    let (deposited: wad) = shrine_deposits.read(current_yang_id, trove_id);

    // Gas optimization - skip over the current yang if the user hasn't deposited any
    if (deposited == 0) {
        return get_trove_threshold_and_value_internal(
            trove_id,
            interval,
            current_yang_id - 1,
            cumulative_weighted_threshold,
            cumulative_trove_value,
        );
    }

    let (yang_threshold: ray) = shrine_thresholds.read(current_yang_id);

    let (price: wad, _, _) = get_recent_price_from(current_yang_id, interval);
    let deposited_value: wad = WadRay.wmul(price, deposited);

    let weighted_threshold: ray = WadRay.wmul(yang_threshold, deposited_value);

    // WadRay.unsigned_add includes overflow check on result
    let cumulative_trove_value: wad = WadRay.unsigned_add(cumulative_trove_value, deposited_value);
    let cumulative_weighted_threshold: ray = WadRay.unsigned_add(
        cumulative_weighted_threshold, weighted_threshold
    );

    return get_trove_threshold_and_value_internal(
        trove_id,
        interval,
        current_yang_id - 1,
        cumulative_weighted_threshold,
        cumulative_trove_value,
    );
}

// Returns a tuple of the threshold and value of all troves combined.
// This function uses historical prices but the total amount of currently deposited yangs across
// all troves to calculate the total value of all troves.
func get_shrine_threshold_and_value_internal{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    current_interval: ufelt,
    current_yang_id: ufelt,
    cumulative_weighted_threshold: ray,
    cumulative_value: wad,
) -> (threshold: ray, value: wad) {
    alloc_locals;

    if (current_yang_id == 0) {
        if (cumulative_value != 0) {
            // WadRay.wunsigned_div, with the numerator a ray, and the denominator a wad, returns a ray
            let threshold: ray = WadRay.wunsigned_div(
                cumulative_weighted_threshold, cumulative_value
            );
            return (threshold=threshold, value=cumulative_value);
        } else {
            return (threshold=0, value=0);
        }
    }

    let (deposited: wad) = shrine_yang_total.read(current_yang_id);

    // Gas optimization - skip over the current yang if none has been deposited
    if (deposited == 0) {
        return get_shrine_threshold_and_value_internal(
            current_interval, current_yang_id - 1, cumulative_weighted_threshold, cumulative_value
        );
    }

    let (yang_threshold: ray) = shrine_thresholds.read(current_yang_id);

    let (price: wad, _, _) = get_recent_price_from(current_yang_id, current_interval);
    let deposited_value: wad = WadRay.wmul(price, deposited);

    let weighted_threshold: ray = WadRay.wmul(yang_threshold, deposited_value);

    // WadRay.unsigned_add includes overflow check on result
    let cumulative_value: wad = WadRay.unsigned_add(cumulative_value, deposited_value);
    let cumulative_weighted_threshold: ray = WadRay.unsigned_add(
        cumulative_weighted_threshold, weighted_threshold
    );

    return get_shrine_threshold_and_value_internal(
        current_interval, current_yang_id - 1, cumulative_weighted_threshold, cumulative_value
    );
}

//
// Internal ERC20 functions
//

func _transfer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    sender: address, recipient: address, amount: Uint256
) {
    with_attr error_message("Shrine: Cannot transfer to the zero address") {
        assert_not_zero(recipient);
    }

    with_attr error_message("Shrine: Amount not valid") {
        uint256_check(amount);
    }

    with_attr error_message("Shrine: Amount value ({amount}) is out of bounds") {
        let amount_wad: wad = WadRay.from_uint(amount);
    }

    let (sender_balance: wad) = shrine_yin.read(sender);
    let (recipient_balance: wad) = shrine_yin.read(recipient);

    // WadRay.unsigned_sub reverts on underflow, so this function cannot be used
    // to move more yin than sender owns
    with_attr error_message("Shrine: Transfer amount exceeds yin balance") {
        shrine_yin.write(sender, WadRay.unsigned_sub(sender_balance, amount_wad));
    }
    shrine_yin.write(recipient, WadRay.add(recipient_balance, amount_wad));

    Transfer.emit(sender, recipient, amount);
    return ();
}

func _approve{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    owner: address, spender: address, amount: Uint256
) {
    with_attr error_message("Shrine: Cannot approve from the zero address") {
        assert_not_zero(owner);
    }

    with_attr error_message("Shrine: Cannot approve to the zero address") {
        assert_not_zero(spender);
    }

    with_attr error_message("Shrine: Amount not valid") {
        uint256_check(amount);
    }

    shrine_yin_allowances.write(owner, spender, amount);
    Approval.emit(owner, spender, amount);
    return ();
}

func _spend_allowance{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    owner: address, spender: address, amount: Uint256
) {
    alloc_locals;

    let (current_allowance: Uint256) = shrine_yin_allowances.read(owner, spender);
    if (current_allowance.low == ALL_ONES and current_allowance.high == ALL_ONES) {
        // infinite allowance 2**256 - 1
        return ();
    }

    with_attr error_message("Shrine: Insufficient yin allowance") {
        assert_uint256_le(amount, current_allowance);
        let (new_allowance: Uint256) = uint256_sub(current_allowance, amount);
        _approve(owner, spender, new_allowance);
    }

    return ();
}