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
    get_role,
    has_role,
    get_admin,
    grant_role,
    revoke_role,
    renounce_role,
    change_admin,
)
from contracts.shared.interfaces import IERC20
from contracts.shared.wad_ray import WadRay

//
// Events
//

@event
func Deposit(user, trove_id, assets_wad) {
}

@event
func Withdraw(user, trove_id, assets_wad) {
}

@event
func Killed() {
}

//
// Storage
//

@storage_var
func gate_live_storage() -> (bool: felt) {
}

//
// Getters
//

@view
func get_live{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (bool: felt) {
    return gate_live_storage.read();
}

//
// Constructor
//

@constructor
func constructor{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(authed, shrine_address, asset_address) {
    AccessControl.initializer(authed);

    // Grant permission
    AccessControl._grant_role(GateRoles.DEFAULT_GATE_ADMIN_ROLE, authed);

    Gate.initializer(shrine_address, asset_address);
    gate_live_storage.write(TRUE);
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
    gate_live_storage.write(FALSE);
    Killed.emit();
    return ();
}

@external
func deposit{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(user_address, trove_id, assets_wad) {
    alloc_locals;
    // TODO: Revisit whether reentrancy guard should be added here

    // Assert live
    assert_live();

    // Only Abbot can call
    AccessControl.assert_has_role(GateRoles.DEPOSIT);

    // Get asset and gate addresses
    let (asset_address) = get_asset();
    let (gate_address) = get_contract_address();

    // Transfer asset from `user_address` to Gate
    let (assets_uint) = WadRay.to_uint(assets_wad);
    with_attr error_message("Gate: Transfer of asset failed") {
        let (success) = IERC20.transferFrom(
            contract_address=asset_address,
            sender=user_address,
            recipient=gate_address,
            amount=assets_uint,
        );
        assert success = TRUE;
    }

    // Emit event
    Deposit.emit(user=user_address, trove_id=trove_id, assets_wad=assets_wad);

    return ();
}

@external
func withdraw{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(user_address, trove_id, assets_wad) {
    alloc_locals;
    // TODO: Revisit whether reentrancy guard should be added here

    // Only Abbot can call
    AccessControl.assert_has_role(GateRoles.WITHDRAW);

    // Get asset address
    let (asset_address) = get_asset();

    // Transfer asset from Gate to `user_address`
    let (assets_uint: Uint256) = WadRay.to_uint(assets_wad);
    with_attr error_message("Gate: Transfer of asset failed") {
        let (success) = IERC20.transfer(
            contract_address=asset_address, recipient=user_address, amount=assets_uint
        );
        assert success = TRUE;
    }

    // Emit event
    Withdraw.emit(user=user_address, trove_id=trove_id, assets_wad=assets_wad);

    return ();
}

//
// Internal
//

func assert_live{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    // Check system is live
    let (live) = gate_live_storage.read();
    with_attr error_message("Gate: Gate is not live") {
        assert live = TRUE;
    }
    return ();
}
