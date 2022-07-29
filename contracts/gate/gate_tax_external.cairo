%lang starknet

from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_le
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.uint256 import Uint256

from contracts.gate.gate_tax import GateTax
from contracts.shared.interfaces import IERC20
from contracts.shared.wad_ray import WadRay

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
