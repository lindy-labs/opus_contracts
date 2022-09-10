%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_contract_address

from contracts.gate.rebasing_yang.roles import GateRoles
from contracts.gate.gate_tax import GateTax
from contracts.gate.gate_tax_external import get_tax, get_tax_collector
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
// Interface
//

@contract_interface
namespace MockRebasingToken {
    func mint(recipient: felt, amount: Uint256) {
    }
}

//
// Constant
//

const REBASE_RATIO = 10 * WadRay.RAY_PERCENT;  // 10%

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
}(authed, shrine_address, asset_address, tax, tax_collector_address) {
    alloc_locals;

    AccessControl.initializer(authed);

    // Grant permission
    AccessControl._grant_role(GateRoles.DEFAULT_GATE_TAXABLE_ADMIN_ROLE, authed);

    Gate.initializer(shrine_address, asset_address);
    GateTax.initializer(tax, tax_collector_address);
    gate_live.write(TRUE);
    return ();
}

// Setters

@external
func set_tax{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(tax) {
    AccessControl.assert_has_role(GateRoles.SET_TAX);
    GateTax.set_tax(tax);
    return ();
}

@external
func set_tax_collector{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(address) {
    AccessControl.assert_has_role(GateRoles.SET_TAX_COLLECTOR);
    GateTax.set_tax_collector(address);
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
    let asset: address = get_asset();
    let gate: address = get_contract_address();

    // Update Shrine
    let shrine: address = get_shrine();
    IShrine.deposit(contract_address=shrine, yang=asset, trove_id=trove_id, amount=yang);

    // Transfer asset from `user_address` to Gate
    let (assets_uint) = WadRay.to_uint(assets);
    with_attr error_message("Gate: Transfer of asset failed") {
        let (success) = IERC20.transferFrom(
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

    IShrine.withdraw(contract_address=shrine, yang=asset, trove_id=trove_id, amount=yang);

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

// Autocompound and charge the admin fee.
@external
func levy{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    alloc_locals;

    // Get asset balance before compound
    let before_balance: wad = Gate.get_total_assets();

    // Autocompound
    compound();

    // Get asset balance after compound
    let after_balance: wad = Gate.get_total_assets();

    // Assumption: Balance cannot decrease without any user action
    if (is_le(after_balance, before_balance) == TRUE) {
        return ();
    }

    // Get asset address
    let asset: address = Gate.get_asset();

    // Charge tax on the taxable amount
    let taxable: wad = after_balance - before_balance;
    GateTax.levy(asset, taxable);

    return ();
}

//
// Internal
//

func assert_live{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    // Check system is live
    let (live) = gate_live.read();
    with_attr error_message("Gate: Gate is not live") {
        assert live = TRUE;
    }
    return ();
}

// Function to simulate compounding by minting the underlying token
func compound{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    // Get asset and gate addresses
    let asset: address = Gate.get_asset();
    let gate: address = get_contract_address();

    // Calculate rebase amount based on 10% of current gate's balance
    let current_assets: wad = Gate.get_total_assets();
    let rebase_amount: wad = WadRay.rmul(current_assets, REBASE_RATIO);
    let (rebase_amount_uint) = WadRay.to_uint(rebase_amount);

    // Minting tokens
    MockRebasingToken.mint(contract_address=asset, recipient=gate, amount=rebase_amount_uint);

    return ();
}
