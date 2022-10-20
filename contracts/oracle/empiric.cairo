%lang starknet

from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math import assert_in_range, assert_le, assert_not_zero
from starkware.cairo.common.math_cmp import is_le, is_le_felt
from starkware.starknet.common.syscalls import get_block_timestamp

from contracts.oracle.roles import EmpiricRoles

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
from contracts.lib.pow import pow10
from contracts.lib.interfaces import IEmpiricOracle
from contracts.shrine.interface import IShrine

const WAD_DECIMALS = 18;
// TODO: comment
// [lower, upper)
const LOWER_FRESHNESS_BOUND = 60;  // 1 minute
const UPPER_FRESHNESS_BOUND = 60 * 60 * 4 + 1;  // 4 hours
const LOWER_SOURCES_BOUND = 1;
const UPPER_SOURCES_BOUND = 13;
const LOWER_UPDATE_INTERVAL_BOUND = 15;  // seconds (SN tx goal)
const UPPER_UPDATE_INTERVAL_BOUND = 60 * 60 * 4 + 1;

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
    yang: address, price: ufelt, empiric_last_updated_ts: ufelt, empiric_num_sources: ufelt
) {
}

@event
func OracleAddressUpdated(old_address: address, new_address: address) {
}

@event
func PricesUpdated(timestamp: ufelt) {
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
func set_price_validity_thresholds{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(freshness: ufelt, sources: ufelt) {
    alloc_locals;

    AccessControl.assert_has_role(EmpiricRoles.SET_PRICE_VALIDITY_THRESHOLDS);

    with_attr error_message("Empiric: freshness threshold out of bounds") {
        assert_in_range(freshness, LOWER_FRESHNESS_BOUND, UPPER_FRESHNESS_BOUND);
    }

    with_attr error_message("Empiric: sources threshold out of bounds") {
        assert_in_range(sources, LOWER_SOURCES_BOUND, UPPER_SOURCES_BOUND);
    }

    let (old_thresholds: PriceValidityThresholds) = empiric_price_validity_thresholds.read();
    let new_thresholds: PriceValidityThresholds = PriceValidityThresholds(freshness, sources);
    empiric_price_validity_thresholds.write(new_thresholds);
    PriceValidityThresholdsUpdated.emit(old_thresholds, new_thresholds);

    return ();
}

@external
func set_oracle_address{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(oracle: address) {
    AccessControl.assert_has_role(EmpiricRoles.SET_ORACLE_ADDRESS);

    with_attr error_message("Empiric: address cannot be zero") {
        assert_not_zero(oracle);
    }

    let (old: address) = empiric_oracle.read();
    empiric_oracle.write(oracle);

    OracleAddressUpdated.emit(old, oracle);

    return ();
}

@external
func set_update_interval{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(new_interval: ufelt) {
    AccessControl.assert_has_role(EmpiricRoles.SET_UPDATE_INTERVAL);

    with_attr error_message("Empiric: update interval out of bounds") {
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
    with_attr error_message("Empiric: invalid values") {
        assert_not_zero(empiric_id);
        assert_not_zero(yang);
    }

    // doing a sanity check if Empiric actually offers a price feed
    // on the requested asset and if it's suitable for our needs
    let (oracle: address) = empiric_oracle.read();
    with_attr error_message("Empiric: problem fetching oracle price") {
        let (_, decimals: ufelt, _, _) = IEmpiricOracle.get_spot_median(oracle, empiric_id);
    }
    with_attr error_message("Empiric: feed with too many decimals") {
        assert_le(decimals, WAD_DECIMALS);
    }

    let settings: YangSettings = YangSettings(empiric_id, yang);
    let (index) = empiric_yangs_count.read();
    empiric_yang_settings.write(index, settings);
    empiric_yangs_count.write(index + 1);

    YangAdded.emit(index, settings);

    return ();
}

@external
func update_prices{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    alloc_locals;

    with_attr error_message("Empiric: too soon to update prices") {
        let (can_proceed_with_udpate: bool) = probeTask();
        assert can_proceed_with_udpate = TRUE;
    }
    // TODO: this func will be open to anyone, do we need any other asserts here?

    let (yangs_count: ufelt) = empiric_yangs_count.read();
    let (oracle: address) = empiric_oracle.read();
    let (shrine: address) = empiric_shrine.read();
    let (block_timestamp: ufelt) = get_block_timestamp();

    update_prices_loop(0, yangs_count, oracle, shrine, block_timestamp);

    // record update timestamp
    empiric_last_price_update.write(block_timestamp);

    PricesUpdated.emit(block_timestamp);

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
    let is_task_ready: bool = is_le_felt(update_interval, seconds_since_last_update);

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

func update_prices_loop{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    index: ufelt, count: ufelt, oracle: address, shrine: address, block_timestamp: ufelt
) {
    alloc_locals;

    if (index == count) {
        return ();
    }

    let (settings: YangSettings) = empiric_yang_settings.read(index);

    let (
        value: ufelt, decimals: ufelt, last_updated_ts: ufelt, num_sources: ufelt
    ) = IEmpiricOracle.get_spot_median(oracle, settings.empiric_id);

    // convert the price to wad
    let (mul: ufelt) = pow10(WAD_DECIMALS - decimals);
    let price: wad = value * mul;

    let (is_valid) = is_valid_price_update(block_timestamp, last_updated_ts, num_sources);
    if (is_valid == TRUE) {
        // TODO: once we have a single gate, this call to advance will have to be updated, see:
        //       https://github.com/lindy-labs/aura_contracts/pull/152#issuecomment-1282143697
        IShrine.advance(shrine, settings.yang, price);
    } else {
        InvalidPriceUpdate.emit(settings.yang, price, last_updated_ts, num_sources);
    }

    return update_prices_loop(index + 1, count, oracle, shrine, block_timestamp);
}

func is_valid_price_update{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    block_timestamp: ufelt, last_updated_ts: ufelt, num_sources: ufelt
) -> (is_valid: bool) {
    alloc_locals;

    let (required: PriceValidityThresholds) = empiric_price_validity_thresholds.read();

    // check if the update is from enough sources
    let has_enough_sources: bool = is_le(required.sources, num_sources);

    // check if the update is fresh enough
    let is_fresh: bool = is_le(block_timestamp - required.freshness, block_timestamp);

    // multiplication simulates boolean AND
    return (has_enough_sources * is_fresh,);
}
