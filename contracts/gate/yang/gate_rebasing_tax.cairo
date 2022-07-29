%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.starknet.common.syscalls import get_contract_address

from contracts.gate.gate_tax import GateTax
from contracts.gate.gate_tax_external import get_tax, get_tax_collector
from contracts.gate.yang.library import Gate
from contracts.gate.yang.library_external import (
    get_shrine,
    get_asset,
    get_live,
    get_last_asset_balance,
    get_total_assets,
    get_total_yang,
    get_exchange_rate,
    preview_deposit,
    preview_redeem,
)
from contracts.lib.auth import Auth
from contracts.lib.auth_external import authorize, revoke, get_auth

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
    Gate.kill()
    return ()
end

@external
func deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, assets
) -> (wad):
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

# Updates the asset balance of the Gate.
@external
func sync{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    Gate.sync()
    return ()
end

# Autocompound and charge the admin fee.
@external
func levy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    alloc_locals

    # Check last balance of underlying asset against latest balance
    let (last_updated_balance_wad) = Gate.get_last_asset_balance()

    # Autocompound
    compound()

    # Get asset and gate addresses
    let (asset_address) = Gate.get_asset()
    let (gate_address) = get_contract_address()

    # Charge tax
    GateTax.levy(asset_address, gate_address, last_updated_balance_wad)

    # Update balance
    Gate.update_last_asset_balance(asset_address, gate_address)

    return ()
end

# Stub function for compounding by selling token rewards for underlying asset
func compound{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    return ()
end
