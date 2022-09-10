%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin

from contracts.gate.rebasing_yang.library import Gate

from contracts.shared.aliases import wad, address
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
    total: wad
) {
    return (Gate.get_total_assets(),);
}

@view
func get_total_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    total: wad
) {
    return (Gate.get_total_yang(),);
}

// Returns the amount of underlying assets represented by one share in the Gate
@view
func get_exchange_rate{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    rate: wad
) {
    let rate: wad = Gate.get_exchange_rate();
    return (rate,);
}

@view
func preview_deposit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    assets_wad
) -> (preview: wad) {
    let preview: wad = Gate.convert_to_yang(assets_wad);
    return (preview,);
}

@view
func preview_withdraw{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    yang_wad
) -> (preview: wad) {
    let preview: wad = Gate.convert_to_assets(yang_wad);
    return (preview,);
}
