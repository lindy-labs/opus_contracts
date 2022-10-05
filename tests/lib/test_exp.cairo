%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin

from contracts.lib.aliases import wad
from contracts.lib.exp import exp

@view
func get_exp{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(x: wad) -> (
    res: wad
) {
    let res: wad = exp(x);
    return (res,);
}
