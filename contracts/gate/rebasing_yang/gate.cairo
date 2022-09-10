%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_contract_address

from contracts.gate.rebasing_yang.roles import GateRoles
from contracts.gate.rebasing_yang.library import Gate
from contracts.gate.rebasing_yang.library_external import (
    get_shrine,
    get_asset,
    get_total_assets,
    get_total_yang,
    get_exchange_rate,
    preview_deposit,
    preview_withdraw,
)
from contracts.lib.accesscontrol.library import AccessControl
// these imported public functions are part of the contract's interface
from contracts.lib.accesscontrol.accesscontrol_external import (
    get_roles,
    has_role,
    get_admin,
    grant_role,
    revoke_role,
    renounce_role,
    change_admin,
)
from contracts.interfaces import IShrine
from contracts.shared.interfaces import IERC20
from contracts.shared.wad_ray import WadRay
from contracts.shared.aliases import wad, ray, bool, address, ufelt

//
// Events
//

@event
func Deposit(user: address, trove_id: ufelt, assets: wad, yang: wad) {
}

@event
func Withdraw(user: address, trove_id: ufelt, assets: wad, yang: wad) {
}

@event
func Killed() {
}

//
// Storage
//

@storage_var
func gate_live() -> (is_live: bool) {
}

//
// Getters
//

@view
func get_live{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    is_live: bool
) {
    return gate_live.read();
}

//
// Constructor
//

@constructor
func constructor{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(admin: address, shrine: address, asset: address) {
    AccessControl.initializer(admin);

    // Grant permission
    AccessControl._grant_role(GateRoles.DEFAULT_GATE_ADMIN_ROLE, admin);

    Gate.initializer(shrine, asset);
    gate_live.write(TRUE);
    return ();
}

//
// External
//

@external
func kill{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}() {
    AccessControl.assert_has_role(GateRoles.KILL);
    gate_live.write(FALSE);
    Killed.emit();
    return ();
}

@external
func deposit{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(user: address, trove_id: ufelt, assets: wad) -> (yang: wad) {
    alloc_locals;
    // TODO: Revisit whether reentrancy guard should be added here

    // Assert live
    assert_live();

    // Only Abbot can call
    AccessControl.assert_has_role(GateRoles.DEPOSIT);

    let yang: wad = Gate.convert_to_yang(assets);
    if (yang == 0) {
        return (0,);
    }

    // Get asset and gate addresses
    let asset: address = Gate.get_asset();
    let gate: address = get_contract_address();

    // Update Shrine
    let shrine: address = Gate.get_shrine();
    IShrine.deposit(contract_address=shrine, yang_address=asset, trove_id=trove_id, amount=yang);

    // Transfer asset from `user_address` to Gate
    let (assets_uint) = WadRay.to_uint(assets);
    with_attr error_message("Gate: Transfer of asset failed") {
        let (success: bool) = IERC20.transferFrom(
            contract_address=asset, sender=user, recipient=gate, amount=assets_uint
        );
        assert success = TRUE;
    }

    // Emit event
    Deposit.emit(user=user, trove_id=trove_id, assets=assets, yang=yang);

    return (yang,);
}

@external
func withdraw{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(user: address, trove_id: ufelt, yang: wad) -> (assets: wad) {
    alloc_locals;
    // TODO: Revisit whether reentrancy guard should be added here

    // Only Abbot can call
    AccessControl.assert_has_role(GateRoles.WITHDRAW);

    let assets: wad = Gate.convert_to_assets(yang);
    if (assets == 0) {
        return (0,);
    }

    // Get asset address
    let asset: address = Gate.get_asset();

    // Update Shrine
    let shrine: address = Gate.get_shrine();
    IShrine.withdraw(contract_address=shrine, yang_address=asset, trove_id=trove_id, amount=yang);

    // Transfer asset from Gate to `user_address`
    let (assets_uint: Uint256) = WadRay.to_uint(assets);
    with_attr error_message("Gate: Transfer of asset failed") {
        let (success: bool) = IERC20.transfer(
            contract_address=asset, recipient=user, amount=assets_uint
        );
        assert success = TRUE;
    }

    // Emit event
    Withdraw.emit(user=user, trove_id=trove_id, assets=assets, yang=yang);

    return (assets,);
}

//
// Internal
//

func assert_live{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    // Check system is live
    let (is_live: bool) = gate_live.read();
    with_attr error_message("Gate: Gate is not live") {
        assert is_live = TRUE;
    }
    return ();
}
