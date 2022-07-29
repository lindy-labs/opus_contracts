%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin

from contracts.gate.gate_tax import GateTax

#
# Getters
#

@view
func get_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (ray):
    return GateTax.get_tax()
end

@view
func get_tax_collector{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    address
):
    return GateTax.get_tax_collector()
end
