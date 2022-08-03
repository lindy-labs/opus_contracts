%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin

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
