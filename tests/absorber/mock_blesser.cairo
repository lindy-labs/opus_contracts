%lang starknet

from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math_cmp import is_nn_le
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_contract_address

from contracts.absorber.roles import BlesserRoles

// these imported public functions are part of the contract's interface
from contracts.lib.accesscontrol.accesscontrol_external import (
    change_admin,
    get_admin,
    get_roles,
    grant_role,
    has_role,
    renounce_role,
    revoke_role,
)
from contracts.lib.accesscontrol.library import AccessControl
from contracts.lib.aliases import address, bool, ufelt
from contracts.lib.interfaces import IERC20
from contracts.lib.wad_ray import WadRay

//
// Constants
//

const BLESS_AMT_WAD = 1000 * WadRay.WAD_SCALE;

//
// Storage
//

@storage_var
func blesser_asset() -> (asset: address) {
}

@storage_var
func blesser_absorber() -> (absorber: address) {
}

//
// Constructor
//

@constructor
func constructor{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(admin: address, asset: address, absorber: address) {
    AccessControl.initializer(admin);
    AccessControl._grant_role(BlesserRoles.BLESS, absorber);

    blesser_asset.write(asset);
    blesser_absorber.write(absorber);

    return ();
}

//
// View
//

@external
func preview_bless{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}() -> (amount: ufelt) {
    alloc_locals;

    let asset: address = blesser_asset.read();
    let amount: ufelt = preview_bless_internal(asset);
    return (amount,);
}

//
// External
//

// Transfers a fixed number of tokens to the absorber
@external
func bless{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}() -> (amount: ufelt) {
    alloc_locals;

    AccessControl.assert_has_role(BlesserRoles.BLESS);

    let asset: address = blesser_asset.read();
    let bless_amt: ufelt = preview_bless_internal(asset);
    let bless_amt_uint: Uint256 = WadRay.to_uint(bless_amt);
    let absorber: address = blesser_absorber.read();
    IERC20.transfer(asset, absorber, bless_amt_uint);

    return (bless_amt,);
}

//
// Internal
//

func preview_bless_internal{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(asset: address) -> ufelt {
    let blesser: address = get_contract_address();

    let bal_uint: Uint256 = IERC20.balanceOf(asset, blesser);
    let bal: ufelt = WadRay.from_uint(bal_uint);

    let is_depleted: bool = is_nn_le(bal, BLESS_AMT_WAD);
    if (is_depleted == TRUE) {
        return 0;
    }

    return BLESS_AMT_WAD;
}
