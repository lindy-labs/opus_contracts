%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin

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
    authed, shrine_address, asset_address
):
    Auth.authorize(authed)
    Gate.initializer(shrine_address, asset_address)
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
