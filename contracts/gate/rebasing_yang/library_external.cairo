%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin

from contracts.gate.rebasing_yang.library import Gate

//
// Getters
//

@view
func get_shrine{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    address: felt
) {
    return Gate.get_shrine();
}

@view
func get_asset{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    address: felt
) {
    return Gate.get_asset();
}

@view
func get_total_assets{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    wad: felt
) {
    return Gate.get_total_assets();
}

@view
func get_total_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    wad: felt
) {
    return Gate.get_total_yang();
}

// Returns the amount of underlying assets represented by one share in the Gate
@view
func get_exchange_rate{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    wad: felt
) {
    return Gate.get_exchange_rate();
}

@view
func preview_deposit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    assets_wad
) -> (wad: felt) {
    return Gate.convert_to_yang(assets_wad);
}

@view
func preview_withdraw{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang_wad
) -> (wad: felt) {
    return Gate.convert_to_assets(yang_wad);
}
