%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_contract_address

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
from contracts.lib.auth import Auth
from contracts.lib.auth_external import authorize, revoke, get_auth
from contracts.interfaces import IShrine
from contracts.shared.interfaces import IERC20
from contracts.shared.wad_ray import WadRay

#
# Interface
#

@contract_interface
namespace MockRebasingToken:
    func mint(recipient : felt, amount : Uint256):
    end
end

#
# Constant
#

const REBASE_RATIO = 10 * WadRay.RAY_PERCENT  # 10%

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
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    authed, shrine_address, asset_address, tax, tax_collector_address
):
    Auth.authorize(authed)
    Gate.initializer(shrine_address, asset_address)
    GateTax.initializer(tax, tax_collector_address)
    gate_live_storage.write(TRUE)
    return ()
end

# Setters

@external
func set_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(tax):
    Auth.assert_caller_authed()
    GateTax.set_tax(tax)
    return ()
end

@external
func set_tax_collector{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
    Auth.assert_caller_authed()
    GateTax.set_tax_collector(address)
    return ()
end

#
# External
#

@external
func kill{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    Auth.assert_caller_authed()
    gate_live_storage.write(FALSE)
    Killed.emit()
    return ()
end

@external
func deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, assets_wad
) -> (wad):
    alloc_locals
    # TODO: Revisit whether reentrancy guard should be added here

    # Assert live
    assert_live()

    # Only Abbot can call
    Auth.assert_caller_authed()

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
        amount=yang_wad,
        trove_id=trove_id,
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
func withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, yang_wad
) -> (wad):
    alloc_locals
    # TODO: Revisit whether reentrancy guard should be added here

    # Only Abbot can call
    Auth.assert_caller_authed()

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
        amount=yang_wad,
        trove_id=trove_id,
    )

    # Transfer asset from Gate to `user_address`
    let (assets_uint : Uint256) = WadRay.to_uint(assets_wad)
    with_attr error_message("Gate: Transfer of asset failed"):
        let (success) = IERC20.transfer(
            contract_address=asset_address, recipient=user_address, amount=assets_uint
        )
        assert success = TRUE
    end

    # Emit event
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

# Function to simulate compounding by minting the underlying token
func compound{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    # Get asset and gate addresses
    let (asset_address) = Gate.get_asset()
    let (gate_address) = get_contract_address()

    # Calculate rebase amount based on 10% of current gate's balance
    let (current_assets_wad) = get_total_assets()
    let (rebase_amount) = WadRay.rmul(current_assets_wad, REBASE_RATIO)
    let (rebase_amount_uint) = WadRay.to_uint(rebase_amount)

    # Minting tokens
    MockRebasingToken.mint(
        contract_address=asset_address, recipient=gate_address, amount=rebase_amount_uint
    )

    return ()
end
