%lang starknet

from contracts.shared.exp import exp
from starkware.cairo.common.cairo_builtins import HashBuiltin
from contracts.shared.aliases import wad
@view
func get_exp{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(x: wad) -> (
    res: wad
) {
    let res: wad = exp(x);
    return (res,);
}
