%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_contract_address

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
from contracts.interfaces import IShrine
from contracts.shared.interfaces import IERC20
from contracts.shared.wad_ray import WadRay

#
# Events
#

@event
func Deposit(user, trove_id, assets_wad, shares_wad):
end

@event
func Redeem(user, trove_id, assets_wad, shares_wad):
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
    authed, shrine_address, asset_address
):
    Auth.authorize(authed)
    Gate.initializer(shrine_address, asset_address)
    gate_live_storage.write(TRUE)
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

    # Assert live
    assert_live()

    # Only Abbot can call
    Auth.assert_caller_authed()

    let (shares_wad) = Gate.convert_to_shares(assets_wad)
    if shares_wad == 0:
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
        amount=shares_wad,
        trove_id=trove_id,
    )

    # Transfer asset from `user_address` to Gate
    let (assets_uint) = WadRay.to_uint(assets_wad)
    with_attr error_message("Gate: Transfer of asset failed"):
        # TODO: Revisit whether reentrancy guard should be added here
        let (success) = IERC20.transferFrom(
            contract_address=asset_address,
            sender=user_address,
            recipient=gate_address,
            amount=assets_uint,
        )
        assert success = TRUE
    end

    Deposit.emit(user=user_address, trove_id=trove_id, assets_wad=assets_wad, shares_wad=shares_wad)

    return (shares_wad)
end

@external
func redeem{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, shares_wad
) -> (wad):
    alloc_locals

    # Only Abbot can call
    Auth.assert_caller_authed()

    let (assets_wad) = Gate.convert_to_assets(shares_wad)
    if assets_wad == 0:
        return (0)
    end

    # Get asset and gate addresses
    let (asset_address) = get_asset()

    # Update Shrine
    let (shrine_address) = get_shrine()
    IShrine.withdraw(
        contract_address=shrine_address,
        yang_address=asset_address,
        amount=shares_wad,
        trove_id=trove_id,
    )

    let (assets_uint : Uint256) = WadRay.to_uint(assets_wad)

    with_attr error_message("Gate: Transfer of asset failed"):
        # TODO: Revisit whether reentrancy guard should be added here
        let (success) = IERC20.transfer(
            contract_address=asset_address, recipient=user_address, amount=assets_uint
        )
        assert success = TRUE
    end

    Redeem.emit(user=user_address, trove_id=trove_id, assets_wad=assets_wad, shares_wad=shares_wad)

    return (assets_wad)
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
