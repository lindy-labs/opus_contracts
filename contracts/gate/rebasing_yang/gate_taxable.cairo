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
    preview_redeem,
)
from contracts.lib.auth import Auth
from contracts.lib.auth_external import authorize, revoke, get_auth

#
# Events
#

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
    user_address, trove_id, assets
) -> (wad):
    # Assert live
    assert_live()

    # Only Abbot can call
    Auth.assert_caller_authed()

    return Gate.deposit(user_address, trove_id, assets)
end

@external
func redeem{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, shares
) -> (wad):
    # Only Abbot can call
    Auth.assert_caller_authed()

    return Gate.redeem(user_address, trove_id, shares)
end

# Autocompound and charge the admin fee.
@external
func levy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    alloc_locals

    # Check last balance of underlying asset against latest balance
    let (before_balance_wad) = Gate.get_total_assets()

    # Autocompound
    compound()

    # Get latest asset balance
    let (after_balance_wad) = Gate.get_total_assets()

    # Assumption: Balance cannot decrease without any user action
    let (unincremented) = is_le(after_balance_wad, before_balance_wad)
    if unincremented == TRUE:
        return ()
    end

    # Get asset and gate addresses
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
