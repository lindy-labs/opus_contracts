%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin

from contracts.gate.gate_tax import GateTax
from contracts.lib.aliases import address, ray

//
// Getters
//

@view
func get_tax{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (tax: ray) {
    return (GateTax.get_tax(),);
}

@view
func get_tax_collector{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    tax_collector: address
) {
    return (GateTax.get_tax_collector(),);
}
