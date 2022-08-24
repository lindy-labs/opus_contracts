%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, HashBuiltin
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_contract_address

from contracts.gate.gate_tax import GateTax
from contracts.gate.gate_tax_external import get_tax, get_tax_collector
from contracts.gate.rebasing_yang.gate_accesscontrol import GateAccessControl
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
from contracts.interfaces import IShrine
# these imported public functions are part of the contract's interface
from contracts.lib.acl import AccessControl
from contracts.lib.acl_external import (
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

#
# Events
#

@event
func Deposit(user, trove_id, assets_wad, yang_wad):
end

@event
func Withdraw(user, trove_id, assets_wad, yang_wad):
end

@event
func Killed():
end

#
# Storage
#

@storage_var
func gate_live_storage() -> (bool):
end

#
# Getters
#

@view
func get_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (bool):
    return gate_live_storage.read()
end

#
# Constructor
#

@constructor
func constructor{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(authed, shrine_address, asset_address, tax, tax_collector_address):
    alloc_locals

    AccessControl.initializer(authed)

    # Grant permission
    AccessControl._grant_role(GateAccessControl.KILL, authed)
    AccessControl._grant_role(GateAccessControl.SET_TAX, authed)
    AccessControl._grant_role(GateAccessControl.SET_TAX_COLLECTOR, authed)

    Gate.initializer(shrine_address, asset_address)
    GateTax.initializer(tax, tax_collector_address)
    gate_live_storage.write(TRUE)
    return ()
end

# Setters

@external
func set_tax{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(tax_ray):
    AccessControl.assert_has_role(GateAccessControl.SET_TAX)
    GateTax.set_tax(tax_ray)
    return ()
end

@external
func set_tax_collector{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(address):
    AccessControl.assert_has_role(GateAccessControl.SET_TAX_COLLECTOR)
    GateTax.set_tax_collector(address)
    return ()
end

#
# External
#

@external
func kill{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}():
    AccessControl.assert_has_role(GateAccessControl.KILL)
    gate_live_storage.write(FALSE)
    Killed.emit()
    return ()
end

@external
func deposit{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(user_address, trove_id, assets_wad) -> (wad):
    alloc_locals
    # TODO: Revisit whether reentrancy guard should be added here

    # Assert live
    assert_live()

    # Only Abbot can call
    AccessControl.assert_has_role(GateAccessControl.DEPOSIT)

    let (yang_wad) = Gate.convert_to_yang(assets_wad)
    if yang_wad == 0:
        return (0)
    end

    # Get asset and gate addresses
    let (asset_address) = get_asset()
    let (gate_address) = get_contract_address()

    # Update Shrine
    let (shrine_address) = get_shrine()
    IShrine.deposit(
        contract_address=shrine_address,
        yang_address=asset_address,
        trove_id=trove_id,
        amount=yang_wad,
    )

    # Transfer asset from `user_address` to Gate
    let (assets_uint) = WadRay.to_uint(assets_wad)
    with_attr error_message("Gate: Transfer of asset failed"):
        let (success) = IERC20.transferFrom(
            contract_address=asset_address,
            sender=user_address,
            recipient=gate_address,
            amount=assets_uint,
        )
        assert success = TRUE
    end

    # Emit event
    Deposit.emit(user=user_address, trove_id=trove_id, assets_wad=assets_wad, yang_wad=yang_wad)

    return (yang_wad)
end

@external
func withdraw{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*
}(user_address, trove_id, yang_wad) -> (wad):
    alloc_locals
    # TODO: Revisit whether reentrancy guard should be added here

    # Only Abbot can call
    AccessControl.assert_has_role(GateAccessControl.WITHDRAW)

    let (assets_wad) = Gate.convert_to_assets(yang_wad)
    if assets_wad == 0:
        return (0)
    end

    # Get asset address
    let (asset_address) = get_asset()

    # Update Shrine
    let (shrine_address) = get_shrine()
    IShrine.withdraw(
        contract_address=shrine_address,
        yang_address=asset_address,
        trove_id=trove_id,
        amount=yang_wad,
    )

    # Transfer asset from Gate to `user_address`
    let (assets_uint : Uint256) = WadRay.to_uint(assets_wad)
    with_attr error_message("Gate: Transfer of asset failed"):
        let (success) = IERC20.transfer(
            contract_address=asset_address, recipient=user_address, amount=assets_uint
        )
        assert success = TRUE
    end

    # Emit events
    Withdraw.emit(user=user_address, trove_id=trove_id, assets_wad=assets_wad, yang_wad=yang_wad)

    return (assets_wad)
end

# Autocompound and charge the admin fee.
@external
func levy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    alloc_locals

    # Get asset balance before compound
    let (before_balance_wad) = Gate.get_total_assets()

    # Autocompound
    compound()

    # Get asset balance after compound
    let (after_balance_wad) = Gate.get_total_assets()

    # Assumption: Balance cannot decrease without any user action
    let (unincremented) = is_le(after_balance_wad, before_balance_wad)
    if unincremented == TRUE:
        return ()
    end

    # Get asset address
    let (asset_address) = Gate.get_asset()

    # Charge tax on the taxable amount
    let taxable_wad = after_balance_wad - before_balance_wad
    GateTax.levy(asset_address, taxable_wad)

    return ()
end

#
# Internal
#

func assert_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    # Check system is live
    let (live) = gate_live_storage.read()
    with_attr error_message("Gate: Gate is not live"):
        assert live = TRUE
    end
    return ()
end

# Stub function for compounding by selling token rewards for underlying asset
func compound{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    return ()
end
