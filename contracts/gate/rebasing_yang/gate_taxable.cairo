%lang starknet

from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_contract_address

from contracts.gate.gate_tax import GateTax
from contracts.gate.gate_tax_external import get_tax, get_tax_collector
from contracts.gate.rebasing_yang.library import Gate
from contracts.gate.rebasing_yang.library_external import (
    get_asset,
    get_asset_amt_per_yang,
    get_shrine,
    get_total_assets,
    get_total_yang,
    preview_enter,
    preview_exit,
)
from contracts.gate.rebasing_yang.roles import GateRoles

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
from contracts.lib.aliases import address, bool, ray, ufelt, wad
from contracts.lib.interfaces import IERC20
from contracts.lib.wad_ray import WadRay

//
// Events
//

@event
func Enter(user: address, trove_id: ufelt, asset_amt: ufelt, yang_amt: wad) {
}

@event
func Exit(user: address, trove_id: ufelt, asset_amt: ufelt, yang_amt: wad) {
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
}(admin: address, shrine: address, asset: address, tax: ray, tax_collector: address) {
    alloc_locals;

    AccessControl.initializer(admin);

    // Grant permission
    AccessControl._grant_role(GateRoles.DEFAULT_GATE_TAXABLE_ADMIN_ROLE, admin);

    Gate.initializer(shrine, asset);
    GateTax.initializer(tax, tax_collector);
    gate_live.write(TRUE);
    return ();
}

// Setters

@external
func set_tax{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(tax: ray) {
    AccessControl.assert_has_role(GateRoles.SET_TAX);
    GateTax.set_tax(tax);
    return ();
}

@external
func set_tax_collector{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(tax_collector: address) {
    AccessControl.assert_has_role(GateRoles.SET_TAX_COLLECTOR);
    GateTax.set_tax_collector(tax_collector);
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

// `assets` is denominated in the decimals of the asset
@external
func enter{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(user: address, trove_id: ufelt, asset_amt: ufelt) -> (yang_amt: wad) {
    alloc_locals;
    // TODO: Revisit whether reentrancy guard should be added here

    assert_live();

    AccessControl.assert_has_role(GateRoles.ENTER);

    let yang_amt: wad = Gate.convert_to_yang(asset_amt);
    if (yang_amt == 0) {
        return (0,);
    }

    let asset: address = get_asset();
    let gate: address = get_contract_address();

    let asset_amt_uint: Uint256 = WadRay.to_uint(asset_amt);
    with_attr error_message("Gate: Transfer of asset failed") {
        let (success: bool) = IERC20.transferFrom(
            contract_address=asset, sender=user, recipient=gate, amount=asset_amt_uint
        );
        assert success = TRUE;
    }

    Enter.emit(user, trove_id, asset_amt, yang_amt);

    return (yang_amt,);
}

// `assets` is denominated in the decimals of the asset
@external
func exit{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(user: address, trove_id: ufelt, yang_amt: wad) -> (asset_amt: ufelt) {
    alloc_locals;
    // TODO: Revisit whether reentrancy guard should be added here

    AccessControl.assert_has_role(GateRoles.EXIT);

    let asset_amt: ufelt = Gate.convert_to_assets(yang_amt);
    if (asset_amt == 0) {
        return (0,);
    }

    let asset: address = get_asset();
    let (asset_amt_uint: Uint256) = WadRay.to_uint(asset_amt);
    with_attr error_message("Gate: Transfer of asset failed") {
        let (success: bool) = IERC20.transfer(
            contract_address=asset, recipient=user, amount=asset_amt_uint
        );
        assert success = TRUE;
    }

    Exit.emit(user, trove_id, asset_amt, yang_amt);

    return (asset_amt,);
}

// Autocompound and charge the admin fee.
@external
func levy{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    alloc_locals;

    // Get asset balance before compound
    let before_balance: ufelt = Gate.get_total_assets();

    // Autocompound
    compound();

    // Get asset balance after compound
    let after_balance: ufelt = Gate.get_total_assets();

    // Assumption: Balance cannot decrease without any user action
    if (is_le(after_balance, before_balance) == TRUE) {
        return ();
    }

    // Get asset address
    let asset: address = Gate.get_asset();

    // Charge tax on the taxable amount
    // `taxable` is denominated in the decimals of the asset
    let taxable: ufelt = after_balance - before_balance;
    GateTax.levy(asset, taxable);

    return ();
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

// Stub function for compounding by selling token rewards for underlying asset
// TODO: To be implemented when AMMs are ready for integrations
func compound{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    return ();
}