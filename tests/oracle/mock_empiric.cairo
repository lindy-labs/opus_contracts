%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin

@storage_var
func value(pair_id: felt) -> (res: felt) {
}

@storage_var
func decimals(pair_id: felt) -> (res: felt) {
}

@storage_var
func last_updated_ts(pair_id: felt) -> (res: felt) {
}

@storage_var
func num_sources(pair_id: felt) -> (res: felt) {
}

@external
func next_get_spot_median{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    pair_id: felt,
    next_value: felt,
    next_decimals: felt,
    next_last_updated_ts: felt,
    next_num_sources: felt,
) {
    value.write(pair_id, next_value);
    decimals.write(pair_id, next_decimals);
    last_updated_ts.write(pair_id, next_last_updated_ts);
    num_sources.write(pair_id, next_num_sources);

    return ();
}

//
// IEmpiric
//

@view
func get_spot_median{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    pair_id: felt
) -> (value: felt, decimals: felt, last_updated_ts: felt, num_sources: felt) {
    let (v) = value.read(pair_id);
    let (d) = decimals.read(pair_id);
    let (ts) = last_updated_ts.read(pair_id);
    let (ns) = num_sources.read(pair_id);

    return (v, d, ts, ns);
}
