%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin

from contracts.gate.rebasing_yang.library import Gate

from contracts.lib.aliases import address, ufelt, wad

//
// Getters
//

@view
func get_shrine{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    shrine: address
) {
    return (Gate.get_shrine(),);
}

@view
func get_asset{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    asset: address
) {
    return (Gate.get_asset(),);
}

@view
func get_total_assets{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    total: ufelt
) {
    return (Gate.get_total_assets(),);
}

@view
func get_total_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    total: wad
) {
    return (Gate.get_total_yang(),);
}

// Returns the amount of underlying assets in wad represented by one wad of yang in the Gate
@view
func get_asset_amt_per_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    amt: wad
) {
    let rate: wad = Gate.get_asset_amt_per_yang();
    return (rate,);
}

@view
func preview_enter{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    asset_amt: ufelt
) -> (yang_amt: wad) {
    let yang_amt: wad = Gate.convert_to_yang(asset_amt);
    return (yang_amt,);
}

@view
func preview_exit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang_amt: wad
) -> (asset_amt: ufelt) {
    let asset_amt: ufelt = Gate.convert_to_assets(yang_amt);
    return (asset_amt,);
}