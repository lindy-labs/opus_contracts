%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_le, assert_not_zero
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.uint256 import Uint256, uint256_le, uint256_sub
from starkware.starknet.common.syscalls import get_caller_address, get_contract_address

from contracts.lib.erc4626.library import ERC4626

from contracts.lib.openzeppelin.token.erc20.library import ERC20
from contracts.shared.interfaces import IERC20
from contracts.shared.convert import felt_to_uint, uint_to_felt_unchecked
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
func Authorized(address):
end

@event
func Revoked(address):
end

@event
func Killed():
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
<<<<<<< HEAD
func gate_auth(address) -> (authorized):
end

@storage_var
func gate_live() -> (live):
=======
func gate_auth_storage(address) -> (bool):
end

@storage_var
func gate_live_storage() -> (bool):
>>>>>>> d5ded20 (dev(gate): rename storage variables)
end

# Admin fee charged on yield from underlying - ray
@storage_var
<<<<<<< HEAD
func gate_tax() -> (tax):
=======
func gate_tax_storage() -> (ray):
>>>>>>> d5ded20 (dev(gate): rename storage variables)
end

# Address to send admin fees to
@storage_var
func gate_tax_collector_storage() -> (address):
end

<<<<<<< HEAD
# Exchange rate of Gate share to underlying (wad)
@storage_var
func gate_exchange_rate() -> (rate):
end

# Last updated total balance of underlying
# Used to detect changes in total balance due to rebasing
@storage_var
func gate_underlying_balance() -> (balance):
end

# Total number of gage tokens held by contract (wad)
@storage_var
func gate_gage_total() -> (total):
end

# Timestamp of the last update of yield from underlying gage
@storage_var
func gate_gage_last_updated() -> (timestamp):
=======
# Last updated total balance of underlying asset
# Used to detect changes in total balance due to rebasing
@storage_var
func gate_last_asset_balance_storage() -> (wad):
>>>>>>> d5ded20 (dev(gate): rename storage variables)
end

#
# Getters
#

@view
<<<<<<< HEAD
func get_auth{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address) -> (
    authorized
):
    return gate_auth.read(address)
end

@view
func get_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (live):
    return gate_live.read()
=======
func get_auth{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address) -> (bool):
    return gate_auth_storage.read(address)
end

@view
func get_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (bool):
    return gate_live_storage.read()
>>>>>>> d5ded20 (dev(gate): rename storage variables)
end

@view
<<<<<<< HEAD
func get_shrine{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (address):
    return gate_shrine_address.read()
end

@view
func get_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (tax):
=======
func get_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (ray):
<<<<<<< HEAD
>>>>>>> 81db9f5 (remove shrine interface)
    return gate_tax.read()
=======
    return gate_tax_storage.read()
>>>>>>> d5ded20 (dev(gate): rename storage variables)
end

@view
func get_tax_collector_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    ) -> (address):
    return gate_tax_collector_storage.read()
end

@view
func get_last_underlying_balance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    ) -> (wad):
    return gate_last_asset_balance_storage.read()
end

# Returns the amount of assets represented by one share in the pool as currently constituted
@view
func get_exchange_rate{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    wad
):
    let (total_supply_uint : Uint256) = ERC20.total_supply()
    let (total_supply) = uint_to_felt_unchecked(total_supply_uint)
    let (total_balance) = get_last_underlying_balance()

    # Catch division by zero errors
    if total_supply == 0:
        return (0)
    end

    if total_balance == 0:
        return (0)
    end

    let (exchange_rate) = WadRay.wunsigned_div_unchecked(total_balance, total_supply)
    return (exchange_rate)
end

#
# Getters - ERC20
#

@view
func name{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (name):
    let (name) = ERC20.name()
    return (name)
end

@view
func symbol{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (symbol):
    let (symbol) = ERC20.symbol()
    return (symbol)
end

@view
func totalSupply{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    totalSupply : Uint256
):
    let (totalSupply : Uint256) = ERC20.total_supply()
    return (totalSupply)
end

@view
func decimals{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (decimals):
    let (decimals) = ERC20.decimals()
    return (decimals)
end

@view
func balanceOf{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(account) -> (
    balance : Uint256
):
    let (balance : Uint256) = ERC20.balance_of(account)
    return (balance)
end

# Non-transferable
@view
func allowance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    owner, spender
) -> (remaining : Uint256):
    return (Uint256(0, 0))
end

#
# Constructor
#

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    authed, name, symbol, asset_address, tax, tax_collector_address
):
    ERC4626.initializer(name, symbol, asset_address)
    gate_auth_storage.write(authed, TRUE)
    gate_live_storage.write(TRUE)

    with_attr error_message("Gate: Maximum tax exceeded"):
        assert_le(tax, MAX_TAX)
    end

    gate_tax_storage.write(tax)
    gate_tax_collector_storage.write(tax_collector_address)
    return ()
end

#
# External - Auth
#

@external
func authorize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
    assert_auth()
    gate_auth_storage.write(address, TRUE)
    Authorized.emit(address)
    return ()
end

@external
func revoke{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
    assert_auth()
    gate_auth_storage.write(address, FALSE)
    Revoked.emit(address)
    return ()
end

@external
func kill{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    assert_auth()

    gate_live_storage.write(FALSE)
    Killed.emit()
    return ()
end

#
# External - ERC20
#

@external
func transfer{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    recipient, amount : Uint256
) -> (success):
    return (FALSE)
end

@external
func transferFrom{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    sender, recipient, amount : Uint256
) -> (success):
    return (FALSE)
end

@external
func approve{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    spender, amount : Uint256
) -> (success):
    return (FALSE)
end

#
# External - ERC4626
#

@view
func asset{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    assetTokenAddress
):
    let (asset) = ERC4626.asset()
    return (asset)
end

@view
func totalAssets{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    totalManagedAssets : Uint256
):
    let (total : Uint256) = ERC4626.totalAssets()
    return (total)
end

@view
func convertToShares{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    assets : Uint256
) -> (shares : Uint256):
    let (shares : Uint256) = ERC4626.convertToShares(assets)
    return (shares)
end

@view
func convertToAssets{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shares : Uint256
) -> (assets : Uint256):
    let (assets : Uint256) = ERC4626.convertToAssets(shares)
    return (assets)
end

@view
func maxDeposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(receiver) -> (
    maxAssets : Uint256
):
    let (maxAssets : Uint256) = ERC4626.maxDeposit(receiver)
    return (maxAssets)
end

@view
func previewDeposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    assets : Uint256
) -> (shares : Uint256):
    let (shares : Uint256) = ERC4626.previewDeposit(assets)
    return (shares)
end

@external
func deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    assets : Uint256, receiver
) -> (shares : Uint256):
    alloc_locals

    # Assert live
    assert_live()

    # Get asset and vault addresses
    let (asset) = ERC4626.asset()
    let (vault) = get_contract_address()

    # Sync
    sync_inner(asset, vault)

    let (shares : Uint256) = ERC4626.deposit(assets, receiver)

    # Update
    update_last_asset_balance(asset, vault)

    return (shares)
end

@view
func maxMint{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    receiver : felt
) -> (maxShares : Uint256):
    let (maxShares : Uint256) = ERC4626.maxMint(receiver)
    return (maxShares)
end

@view
func previewMint{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shares : Uint256
) -> (assets : Uint256):
    let (assets : Uint256) = ERC4626.previewMint(shares)
    return (assets)
end

@external
func mint{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shares : Uint256, receiver : felt
) -> (assets : Uint256):
    alloc_locals

    # Assert live
    assert_live()

    # Get asset and vault addresses
    let (asset) = ERC4626.asset()
    let (vault) = get_contract_address()

    # Sync
    sync_inner(asset, vault)

    let (assets : Uint256) = ERC4626.mint(shares, receiver)

    # Update
    update_last_asset_balance(asset, vault)

    return (assets)
end

@view
func maxWithdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    owner : felt
) -> (maxAssets : Uint256):
    let (maxWithdraw : Uint256) = ERC4626.maxWithdraw(owner)
    return (maxWithdraw)
end

@view
func previewWithdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    assets : Uint256
) -> (shares : Uint256):
    let (shares : Uint256) = ERC4626.previewWithdraw(assets)
    return (shares)
end

@external
func withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    assets : Uint256, receiver : felt, owner : felt
) -> (shares : Uint256):
    alloc_locals

<<<<<<< HEAD
=======
    # Only Abbot can call
    assert_auth()

    # Get asset and vault addresses
    let (asset) = ERC4626.asset()
    let (vault) = get_contract_address()

>>>>>>> bfeb7ac (dev(gate): refactor sync functions)
    # Sync
    sync_inner(asset, vault)

    let (shares : Uint256) = ERC4626.withdraw(assets, receiver, owner)

    # Update
    update_last_asset_balance(asset, vault)

    return (shares)
end

@view
func maxRedeem{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(owner : felt) -> (
    maxShares : Uint256
):
    let (maxShares : Uint256) = ERC4626.maxRedeem(owner)
    return (maxShares)
end

@view
func previewRedeem{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shares : Uint256
) -> (assets : Uint256):
    let (assets : Uint256) = ERC4626.previewRedeem(shares)
    return (assets)
end

@external
func redeem{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shares : Uint256, receiver : felt, owner : felt
) -> (assets : Uint256):
    alloc_locals

<<<<<<< HEAD
=======
    # Only Abbot can call
    assert_auth()

    # Get asset and vault addresses
    let (asset) = ERC4626.asset()
    let (vault) = get_contract_address()

>>>>>>> bfeb7ac (dev(gate): refactor sync functions)
    # Sync
    sync_inner(asset, vault)

    let (assets : Uint256) = ERC4626.redeem(shares, receiver, owner)

    # Update
    update_last_asset_balance(asset, vault)

    return (assets)
end

#
# External - Others
#

# Update the tax (ray)
@external
func set_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(tax):
    assert_auth()

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
    assert_auth()

    let (prev_tax_collector) = gate_tax_collector_storage.read()
    gate_tax_collector_storage.write(address)

    TaxCollectorUpdated.emit(prev_tax_collector, address)
    return ()
end

# Updates the asset balance of the vault, and transfers a tax on the increment
# to the tax_collector address.
@external
func sync{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    # Get asset and vault addresses
    let (asset) = ERC4626.asset()
    let (vault) = get_contract_address()
    sync_inner(asset, vault)
    return ()
end

#
# Internal
#

# Similar to onlyOwner
func assert_auth{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    let (c) = get_caller_address()
    let (is_authed) = gate_auth_storage.read(c)
    assert is_authed = TRUE
    return ()
end

func assert_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    # Check system is live
    let (live) = gate_live_storage.read()
    with_attr error_message("Gate: Gate is not live"):
        assert live = TRUE
    end
    return ()
end

# Helper function to check for balance updates for rebasing tokens, and charge the admin fee.
func sync_inner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_address, vault_address
):
    alloc_locals

    # Check last balance of underlying asset against latest balance
<<<<<<< HEAD
    let (last_updated) = gate_underlying_balance.read()
    let (latest) = IERC20.balanceOf(contract_address=asset, account=vault)
=======
    let (last_updated) = gate_last_asset_balance_storage.read()
<<<<<<< HEAD
    let (latest : Uint256) = IERC20.balanceOf(contract_address=asset, account=vault)
>>>>>>> d5ded20 (dev(gate): rename storage variables)
=======
    let (latest : Uint256) = IERC20.balanceOf(contract_address=asset_address, account=vault_address)
>>>>>>> bfeb7ac (dev(gate): refactor sync functions)
    let (latest_felt) = uint_to_felt_unchecked(latest)
    let (unincremented) = is_le(latest_felt, last_updated)
    if unincremented == FALSE:
        # Get difference in shares
        let difference = latest_felt - last_updated

        # Calculate amount of underlying chargeable
        let (difference_ray) = WadRay.wad_to_ray_unchecked(difference)
        let (tax_rate) = gate_tax_storage.read()
        let (chargeable) = WadRay.rmul_unchecked(difference_ray, tax_rate)
        let (chargeable_wad) = WadRay.ray_to_wad(chargeable)
        let (chargeable_uint256 : Uint256) = felt_to_uint(chargeable_wad)

        # Transfer fees
        let (tax_collector) = gate_tax_collector_storage.read()
        IERC20.transfer(
            contract_address=asset_address, recipient=tax_collector, amount=chargeable_uint256
        )

        let (updated_balance : Uint256) = IERC20.balanceOf(
            contract_address=asset_address, account=vault_address
        )
        let (updated_balance_felt) = uint_to_felt_unchecked(updated_balance)
<<<<<<< HEAD
        gate_underlying_balance.write(updated_balance_felt)
=======
        gate_last_asset_balance_storage.write(updated_balance_felt)
>>>>>>> d5ded20 (dev(gate): rename storage variables)

        Sync.emit(last_updated, updated_balance_felt, chargeable_wad)

        tempvar syscall_ptr = syscall_ptr
        tempvar pedersen_ptr = pedersen_ptr
        tempvar range_check_ptr = range_check_ptr
    else:
        tempvar syscall_ptr = syscall_ptr
        tempvar pedersen_ptr = pedersen_ptr
        tempvar range_check_ptr = range_check_ptr
    end

    return ()
end

# Helper function to update the underlying balance after a user action
func update_last_asset_balance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    asset_address, vault_address
):
    let (balance : Uint256) = IERC20.balanceOf(
        contract_address=asset_address, account=vault_address
    )
    let (balance_felt) = uint_to_felt_unchecked(balance)
<<<<<<< HEAD
    gate_underlying_balance.write(balance_felt)
=======
    gate_last_asset_balance_storage.write(balance_felt)
>>>>>>> d5ded20 (dev(gate): rename storage variables)
    return ()
end
