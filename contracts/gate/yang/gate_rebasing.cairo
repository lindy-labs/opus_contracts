%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_le
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_contract_address

from contracts.interfaces import IShrine
from contracts.lib.auth import Auth
from contracts.shared.interfaces import IERC20
from contracts.shared.types import Yang
from contracts.shared.wad_ray import WadRay

#
# Constants
#

# Maximum tax that can be set by an authorized address (ray)
const MAX_TAX = 5 * 10 ** 25

#
# Events
#

@event
func Killed():
end

@event
func Deposit(user, trove_id, assets_wad, shares_wad):
end

@event
func Redeem(user, trove_id, assets_wad, shares_wad):
end

@event
func TaxUpdated(prev_tax, new_tax):
end

@event
func TaxCollectorUpdated(prev_tax_collector, new_tax_collector):
end

@event
func Sync(prev_balance, new_balance, tax):
end

#
# Storage
#

@storage_var
func gate_shrine_storage() -> (address):
end

@storage_var
func gate_asset_storage() -> (address):
end

@storage_var
func gate_live_storage() -> (bool):
end

# Admin fee charged on yield from underlying - ray
@storage_var
func gate_tax_storage() -> (ray):
end

# Address to send admin fees to
@storage_var
func gate_tax_collector_storage() -> (address):
end

# Last updated total balance of underlying asset
# Used to detect changes in total balance due to rebasing
@storage_var
func gate_last_asset_balance_storage() -> (wad):
end

#
# Getters
#

@view
func get_auth{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address) -> (bool):
    return Auth.is_authorized(address)
end

@view
func get_shrine{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (address):
    return gate_shrine_storage.read()
end

@view
func get_asset{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (address):
    return gate_asset_storage.read()
end

@view
func get_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (bool):
    return gate_live_storage.read()
end

@view
func get_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (ray):
    return gate_tax_storage.read()
end

@view
func get_tax_collector_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    ) -> (address):
    return gate_tax_collector_storage.read()
end

@view
func get_last_asset_balance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    ) -> (wad):
    return gate_last_asset_balance_storage.read()
end

@view
func get_total_assets{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (wad):
    let (asset_address) = get_asset()
    let (gate_address) = get_contract_address()
    let (total_uint : Uint256) = IERC20.balanceOf(
        contract_address=asset_address, account=gate_address
    )
    let (total_wad) = WadRay.from_uint(total_uint)
    return (total_wad)
end

@view
func get_total_yang{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (wad):
    let (shrine_address) = get_shrine()
    let (asset_address) = get_asset()
    let (yang_info : Yang) = IShrine.get_yang(
        contract_address=shrine_address, yang_address=asset_address
    )
    return (yang_info.total)
end

# Returns the amount of underlying assets represented by one share in the pool
@view
func get_exchange_rate{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    wad
):
    let (total_supply_wad) = get_total_yang()
    let (total_balance) = get_last_asset_balance()

    # Catch division by zero errors
    if total_supply_wad == 0:
        return (0)
    end

    let (exchange_rate) = WadRay.wunsigned_div_unchecked(total_balance, total_supply_wad)
    return (exchange_rate)
end

@view
func preview_deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    assets_wad
) -> (wad):
    let (shares) = convert_to_shares(assets_wad)
    return (shares)
end

@view
func preview_redeem{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shares_wad
) -> (wad):
    let (assets_wad) = convert_to_assets(shares_wad)
    return (assets_wad)
end

#
# Constructor
#

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    authed, shrine_address, asset_address, tax, tax_collector_address
):
    Auth.authorize(authed)
    gate_shrine_storage.write(shrine_address)
    gate_asset_storage.write(asset_address)
    gate_live_storage.write(TRUE)

    with_attr error_message("Gate: Maximum tax exceeded"):
        assert_le(tax, MAX_TAX)
    end

    gate_tax_storage.write(tax)
    gate_tax_collector_storage.write(tax_collector_address)
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
    alloc_locals

    # Assert live
    assert_live()

    # Only Abbot can call
    Auth.assert_caller_authed()

    # Get asset and gate addresses
    let (asset_address) = get_asset()
    let (gate_address) = get_contract_address()

    # Sync
    sync_inner(asset_address, gate_address)

    let (shares) = deposit_internal(asset_address, gate_address, user_address, trove_id, assets)

    # Update
    update_last_asset_balance(asset_address, gate_address)

    return (shares)
end

@external
func redeem{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, shares
) -> (wad):
    alloc_locals

    # Only Abbot can call
    Auth.assert_caller_authed()

    # Get asset and gate addresses
    let (asset_address) = get_asset()
    let (gate_address) = get_contract_address()

    # Sync
    sync_inner(asset_address, gate_address)

    let (assets) = redeem_internal(asset_address, gate_address, user_address, trove_id, shares)

    # Update
    update_last_asset_balance(asset_address, gate_address)

    return (assets)
end

#
# External - Others
#

# Update the tax (ray)
@external
func set_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(tax):
    assert_live()

    Auth.assert_caller_authed()

    # Check that tax is lower than MAX_TAX
    with_attr error_message("Gate: Maximum tax exceeded"):
        assert_le(tax, MAX_TAX)
    end

    let (prev_tax) = gate_tax_storage.read()
    gate_tax_storage.write(tax)

    TaxUpdated.emit(prev_tax, tax)
    return ()
end

# Update the tax collector address
@external
func set_tax_collector{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
    Auth.assert_caller_authed()

    let (prev_tax_collector) = gate_tax_collector_storage.read()
    gate_tax_collector_storage.write(address)

    TaxCollectorUpdated.emit(prev_tax_collector, address)
    return ()
end

# Updates the asset balance of the Gate, and transfers a tax on the increment
# to the tax_collector address.
@external
func sync{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    alloc_locals

    # Get asset and gate addresses
    let (asset_address) = get_asset()
    let (gate_address) = get_contract_address()
    sync_inner(asset_address, gate_address)
    update_last_asset_balance(asset_address, gate_address)
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

func convert_to_assets{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shares
) -> (wad):
    alloc_locals

    let (total_supply_wad) = get_total_yang()

    if total_supply_wad == 0:
        return (shares)
    else:
        let (total_assets_wad) = get_total_assets()
        let (product) = WadRay.wmul(shares, total_assets_wad)
        let (assets_wad) = WadRay.wunsigned_div_unchecked(product, total_supply_wad)
        return (assets_wad)
    end
end

func convert_to_shares{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    assets_wad
) -> (wad):
    alloc_locals

    let (total_supply_wad) = get_total_yang()

    if total_supply_wad == 0:
        return (assets_wad)
    else:
        let (product) = WadRay.wmul(assets_wad, total_supply_wad)
        let (total_assets_wad) = get_total_assets()
        let (shares) = WadRay.wunsigned_div_unchecked(product, total_assets_wad)
        return (shares)
    end
end

func deposit_internal{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_address, gate_address, user_address, trove_id, assets_wad
) -> (wad):
    alloc_locals

    let (shares_wad) = convert_to_shares(assets_wad)
    if shares_wad == 0:
        return (0)
    end

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
    let (success : felt) = IERC20.transferFrom(
        contract_address=asset_address,
        sender=user_address,
        recipient=gate_address,
        amount=assets_uint,
    )
    with_attr error_message("Gate: Transfer failed"):
        assert success = TRUE
    end

    Deposit.emit(user=user_address, trove_id=trove_id, assets_wad=assets_wad, shares_wad=shares_wad)

    return (shares_wad)
end

func redeem_internal{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_address, gate_address, user_address, trove_id, shares
) -> (wad):
    alloc_locals

    let (assets_wad) = convert_to_assets(shares)
    if assets_wad == 0:
        return (0)
    end

    let (shrine_address) = get_shrine()

    IShrine.withdraw(
        contract_address=shrine_address,
        yang_address=asset_address,
        amount=shares,
        trove_id=trove_id,
    )

    let (assets_uint : Uint256) = WadRay.to_uint(assets_wad)
    let (success : felt) = IERC20.transfer(
        contract_address=asset_address, recipient=user_address, amount=assets_uint
    )
    with_attr error_message("Gate: Transfer failed"):
        assert success = TRUE
    end

    Redeem.emit(user=user_address, trove_id=trove_id, assets_wad=assets_wad, shares_wad=shares)

    return (assets_wad)
end

# Helper function to check for balance updates for rebasing tokens, and charge the admin fee.
func sync_inner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_address, gate_address
):
    alloc_locals

    # Check last balance of underlying asset against latest balance
    let (last_updated) = gate_last_asset_balance_storage.read()
    let (latest_uint : Uint256) = IERC20.balanceOf(
        contract_address=asset_address, account=gate_address
    )
    let (latest_wad) = WadRay.from_uint(latest_uint)
    # Assumption: Balance cannot decrease without any user action
    let (unincremented) = is_le(latest_wad, last_updated)
    if unincremented == TRUE:
        return ()
    end

    # Get difference in shares
    let difference = latest_wad - last_updated

    # Calculate amount of underlying chargeable
    let (tax_rate) = gate_tax_storage.read()
    # `rmul` on a wad and a ray returns a wad
    let (chargeable_wad) = WadRay.rmul(difference, tax_rate)
    let (chargeable_uint256 : Uint256) = WadRay.to_uint(chargeable_wad)

    # Transfer fees
    let (tax_collector) = gate_tax_collector_storage.read()
    IERC20.transfer(
        contract_address=asset_address, recipient=tax_collector, amount=chargeable_uint256
    )

    # Events
    let updated_balance_wad = latest_wad - chargeable_wad
    Sync.emit(last_updated, updated_balance_wad, chargeable_wad)

    return ()
end

# Helper function to update the underlying balance after a user action
func update_last_asset_balance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_address, gate_address
):
    let (balance_uint : Uint256) = IERC20.balanceOf(
        contract_address=asset_address, account=gate_address
    )
    let (balance_wad) = WadRay.from_uint(balance_uint)
    gate_last_asset_balance_storage.write(balance_wad)
    return ()
end
