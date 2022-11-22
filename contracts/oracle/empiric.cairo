%lang starknet

from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import (
    assert_in_range,
    assert_le,
    assert_not_equal,
    assert_not_zero,
)
from starkware.cairo.common.math_cmp import is_le, is_nn, is_nn_le
from starkware.starknet.common.syscalls import get_block_timestamp, get_caller_address

from contracts.gate.interface import IGate
from contracts.oracle.roles import EmpiricRoles
from contracts.sentinel.interface import ISentinel
from contracts.shrine.interface import IShrine

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
from contracts.lib.aliases import address, bool, ufelt, wad
from contracts.lib.interfaces import IEmpiricOracle
from contracts.lib.pow import pow10
from contracts.lib.wad_ray import WadRay

// there are sanity bounds for settable values, i.e. they can never
// be set outside of this hardcoded range
// the range is [lower, upper)
const LOWER_FRESHNESS_BOUND = 60;  // 1 minute
const UPPER_FRESHNESS_BOUND = 60 * 60 * 4 + 1;  // 4 hours
const LOWER_SOURCES_BOUND = 3;
const UPPER_SOURCES_BOUND = 13;
const LOWER_UPDATE_INTERVAL_BOUND = 15;  // seconds (StarkNet block prod goal)
const UPPER_UPDATE_INTERVAL_BOUND = 60 * 60 * 4 + 1;  // 4 hours

struct PriceValidityThresholds {
    freshness: ufelt,
    sources: ufelt,
}

struct YangSettings {
    empiric_id: ufelt,
    yang: address,
}

//
// Storage
//

// address of the Empiric oracle contract (conforming to IEmpiricOracle)
@storage_var
func empiric_oracle() -> (oracle: address) {
}

// address of Shrine contract (conforming to IShrine)
@storage_var
func empiric_shrine() -> (shrine: address) {
}

// address of Sentinel contract (conforming to ISentinel)
@storage_var
func empiric_sentinel() -> (sentinel: address) {
}

// the minimal time difference in seconds of how often
// we want to fetch from the oracle
@storage_var
func empiric_update_interval() -> (interval: ufelt) {
}

// block timestamp of when the prices were updated last time
@storage_var
func empiric_last_price_update() -> (timestamp: ufelt) {
}

// the storage variable holds a two-tuple of values used to determine if
// we consider a price update stale
// `freshness` is the maximum number of seconds between block timestamp and
// the last update timestamp (as reported by Empiric) for which we consider a
// price update valid
// `sources` is the minimum number of data publishers used to aggregate the
// price value
@storage_var
func empiric_price_validity_thresholds() -> (thresholds: PriceValidityThresholds) {
}

// number of yangs in the `empiric_yang_settings` array
@storage_var
func empiric_yangs_count() -> (count: ufelt) {
}

// array holding tuples of a short string of the asset denominated in USD
// and the StarkNet address of the token
// Empiric uses the numerical value of a short string (i.e. how Cairo
// represents strings) as the asset key:
// https://docs.empiric.network/using-empiric/supported-assets
//
// array example: [('ETH/USD', 999), ('BTC/USD', 800)]
@storage_var
func empiric_yang_settings(index: ufelt) -> (settings: YangSettings) {
}

//
// Events
//

@event
func InvalidPriceUpdate(
    yang: address,
    price: ufelt,
    empiric_last_updated_ts: ufelt,
    empiric_num_sources: ufelt,
    asset_amt_per_yang: wad,
) {
}

@event
func OracleAddressUpdated(old_address: address, new_address: address) {
}

@event
func PricesUpdated(timestamp: ufelt, caller: address) {
}

@event
func PriceValidityThresholdsUpdated(
    old_thresholds: PriceValidityThresholds, new_thresholds: PriceValidityThresholds
) {
}

@event
func UpdateIntervalUpdated(old_interval: ufelt, new_interval: ufelt) {
}

@event
func YangAdded(index: ufelt, settings: YangSettings) {
}

//
// Constructor
//

@constructor
func constructor{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(
    admin: address,
    oracle: address,
    shrine: address,
    sentinel: address,
    update_interval: ufelt,
    freshness_threshold: ufelt,
    sources_threshold: ufelt,
) {
    alloc_locals;

    AccessControl.initializer(admin);

    // grant admin permissions
    AccessControl._grant_role(EmpiricRoles.DEFAULT_EMPIRIC_ADMIN_ROLE, admin);

    empiric_oracle.write(oracle);
    empiric_shrine.write(shrine);
    empiric_sentinel.write(sentinel);
    empiric_update_interval.write(update_interval);
    let validity_thresholds = PriceValidityThresholds(freshness_threshold, sources_threshold);
    empiric_price_validity_thresholds.write(validity_thresholds);

    OracleAddressUpdated.emit(0, oracle);
    UpdateIntervalUpdated.emit(0, update_interval);
    PriceValidityThresholdsUpdated.emit(PriceValidityThresholds(0, 0), validity_thresholds);

    return ();
}

//
// Setters
//

@external
func set_oracle_address{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(oracle: address) {
    AccessControl.assert_has_role(EmpiricRoles.SET_ORACLE_ADDRESS);

    with_attr error_message("Empiric: Address cannot be zero") {
        assert_not_zero(oracle);
    }

    let (old: address) = empiric_oracle.read();
    empiric_oracle.write(oracle);

    OracleAddressUpdated.emit(old, oracle);

    return ();
}

@external
func set_price_validity_thresholds{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(freshness: ufelt, sources: ufelt) {
    alloc_locals;

    AccessControl.assert_has_role(EmpiricRoles.SET_PRICE_VALIDITY_THRESHOLDS);

    with_attr error_message("Empiric: Freshness threshold out of bounds") {
        assert_in_range(freshness, LOWER_FRESHNESS_BOUND, UPPER_FRESHNESS_BOUND);
    }

    with_attr error_message("Empiric: Sources threshold out of bounds") {
        assert_in_range(sources, LOWER_SOURCES_BOUND, UPPER_SOURCES_BOUND);
    }

    let (old_thresholds: PriceValidityThresholds) = empiric_price_validity_thresholds.read();
    let new_thresholds: PriceValidityThresholds = PriceValidityThresholds(freshness, sources);
    empiric_price_validity_thresholds.write(new_thresholds);
    PriceValidityThresholdsUpdated.emit(old_thresholds, new_thresholds);

    return ();
}

@external
func set_update_interval{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(new_interval: ufelt) {
    AccessControl.assert_has_role(EmpiricRoles.SET_UPDATE_INTERVAL);

    with_attr error_message("Empiric: Update interval out of bounds") {
        assert_in_range(new_interval, LOWER_UPDATE_INTERVAL_BOUND, UPPER_UPDATE_INTERVAL_BOUND);
    }

    let (old_interval: ufelt) = empiric_update_interval.read();
    empiric_update_interval.write(new_interval);

    UpdateIntervalUpdated.emit(old_interval, new_interval);

    return ();
}

//
// External
//

@external
func add_yang{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(empiric_id: ufelt, yang: address) {
    alloc_locals;

    AccessControl.assert_has_role(EmpiricRoles.ADD_YANG);

    with_attr error_message("Empiric: Invalid values") {
        assert_not_zero(empiric_id);
        assert_not_zero(yang);
    }

    let (index) = empiric_yangs_count.read();

    // check if adding a yang that's already in the system
    with_attr error_message("Empiric: Yang already present") {
        assert_new_yang(index - 1, yang);
    }

    // doing a sanity check if Empiric actually offers a price feed
    // on the requested asset and if it's suitable for our needs
    let (oracle: address) = empiric_oracle.read();
    with_attr error_message("Empiric: Problem fetching oracle price") {
        let (_, decimals: ufelt, _, _) = IEmpiricOracle.get_spot_median(oracle, empiric_id);
    }
    with_attr error_message("Empiric: Unknown pair ID") {
        // Empirict returns 0 decimals for an unknown pair ID
        assert_not_zero(decimals);
    }
    with_attr error_message("Empiric: Feed with too many decimals") {
        assert_le(decimals, WadRay.WAD_DECIMALS);
    }

    let settings: YangSettings = YangSettings(empiric_id, yang);
    empiric_yang_settings.write(index, settings);
    empiric_yangs_count.write(index + 1);

    YangAdded.emit(index, settings);

    return ();
}

@external
func update_prices{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    alloc_locals;

    with_attr error_message("Empiric: Too soon to update prices") {
        let (can_proceed_with_update: bool) = probeTask();
        assert can_proceed_with_update = TRUE;
    }
    // TODO: this func will be open to anyone, do we need any other asserts here?

    let (yangs_count: ufelt) = empiric_yangs_count.read();
    let (oracle: address) = empiric_oracle.read();
    let (shrine: address) = empiric_shrine.read();
    let (sentinel: address) = empiric_sentinel.read();
    let (block_timestamp: ufelt) = get_block_timestamp();

    update_prices_loop(yangs_count - 1, oracle, shrine, sentinel, block_timestamp);

    // record update timestamp
    empiric_last_price_update.write(block_timestamp);

    let (caller: address) = get_caller_address();
    PricesUpdated.emit(block_timestamp, caller);

    return ();
}

//
// ITask (Yagi keepers)
//

@view
func probeTask{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    is_task_ready: bool
) {
    let (block_timestamp: ufelt) = get_block_timestamp();
    let (last_updated_ts: ufelt) = empiric_last_price_update.read();
    let (update_interval: ufelt) = empiric_update_interval.read();

    let seconds_since_last_update = block_timestamp - last_updated_ts;
    let is_task_ready: bool = is_le(update_interval, seconds_since_last_update);

    return (is_task_ready,);
}

@external
func executeTask{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    update_prices();
    return ();
}

//
// Internal
//

func assert_new_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    index: ufelt, yang: address
) {
    if (index == -1) {
        return ();
    }

    let (settings: YangSettings) = empiric_yang_settings.read(index);
    assert_not_equal(settings.yang, yang);

    return assert_new_yang(index - 1, yang);
}

func update_prices_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    index: ufelt, oracle: address, shrine: address, sentinel: address, block_timestamp: ufelt
) {
    alloc_locals;

    if (index == -1) {
        return ();
    }

    let (settings: YangSettings) = empiric_yang_settings.read(index);

    let (asset_amt_per_yang: wad) = get_asset_amt_per_yang(settings.yang, sentinel);

    let (
        value: ufelt, decimals: ufelt, last_updated_ts: ufelt, num_sources: ufelt
    ) = IEmpiricOracle.get_spot_median(oracle, settings.empiric_id);

    // convert the price to wad
    let (mul: ufelt) = pow10(WadRay.WAD_DECIMALS - decimals);
    let price: wad = value * mul;

    let (is_valid) = is_valid_price_update(
        value, block_timestamp, last_updated_ts, num_sources, asset_amt_per_yang
    );
    if (is_valid == TRUE) {
        IShrine.advance(shrine, settings.yang, price, asset_amt_per_yang);
    } else {
        InvalidPriceUpdate.emit(
            settings.yang, price, last_updated_ts, num_sources, asset_amt_per_yang
        );
    }

    return update_prices_loop(index - 1, oracle, shrine, sentinel, block_timestamp);
}

// Internal function to fetch the amount of the underlying asset represented by one unit of yang
// The asset amount is scaled to wad.
// Returns 0 (sentinel value) if the Gate is invalid
func get_asset_amt_per_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang: address, sentinel: address
) -> (asset_amt: wad) {
    alloc_locals;

    let (gate: address) = ISentinel.get_gate_address(sentinel, yang);

    // Return the sentinel value if Gate is zero address
    if (gate == 0) {
        return (0,);
    }

    let (asset_amt: wad) = IGate.get_asset_amt_per_yang(gate);
    return (asset_amt,);
}

func is_valid_price_update{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    value: ufelt,
    block_timestamp: ufelt,
    last_updated_ts: ufelt,
    num_sources: ufelt,
    asset_amt_per_yang: wad,
) -> (is_valid: bool) {
    alloc_locals;

    let is_positive_value: bool = is_nn(value);
    if (is_positive_value == FALSE) {
        return (FALSE,);
    }

    let (required: PriceValidityThresholds) = empiric_price_validity_thresholds.read();

    // check if the update is from enough sources
    let has_enough_sources: bool = is_le(required.sources, num_sources);

    // it is possible that the last_updates_ts is greater than the block_timestamp (in other words,
    // it is from the future from the chain's perspective), because the update timestamp is coming
    // from a data publisher while the block timestamp from the sequencer, they can be out of sync
    //
    // in such a case, we base the whole validity check only on the number of sources and we trust
    // Empiric with regards to data freshness - they have a check in place where they discard
    // updates that are too far in the future
    //
    // we considered having our own "too far in the future" check but that could lead to us
    // discarding updates in cases where just a single publisher would push updates with future
    // timestamp; that could be disastrous as we would have stale prices
    let is_from_future: bool = is_le(block_timestamp, last_updated_ts);
    if (is_from_future == TRUE) {
        return (has_enough_sources,);
    }

    // use of is_le here is intentional because the result of the first argument
    // block_timestamp - last_updates_ts can never be negative if the code reaches here
    let is_fresh: bool = is_le(block_timestamp - last_updated_ts, required.freshness);

    // check if asset amount is valid
    let is_valid_ratio: bool = is_nn_le(WadRay.WAD_ONE, asset_amt_per_yang);

    // multiplication simulates boolean AND
    return (has_enough_sources * is_fresh * is_valid_ratio,);
}
