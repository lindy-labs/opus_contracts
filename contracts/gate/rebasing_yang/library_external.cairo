%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin

from contracts.gate.rebasing_yang.library import Gate

#
# Getters
#

@view
func get_shrine{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (address):
    return Gate.get_shrine()
end

@view
func get_asset{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (address):
    return Gate.get_asset()
end

@view
func get_total_assets{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (wad):
    return Gate.get_total_assets()
end

@view
func get_total_yang{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (wad):
    return Gate.get_total_yang()
end

# Returns the amount of underlying assets represented by one share in the Gate
@view
func get_exchange_rate{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    wad
):
    return Gate.get_exchange_rate()
end

@view
func preview_deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    assets_wad
) -> (wad):
    return Gate.convert_to_shares(assets_wad)
end

@view
func preview_redeem{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shares_wad
) -> (wad):
    return Gate.convert_to_assets(shares_wad)
end
