%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.uint256 import Uint256, uint256_le, uint256_sub
from starkware.starknet.common.syscalls import get_caller_address, get_contract_address

from contracts.lib.erc4626.library import ERC4626

from contracts.lib.openzeppelin.token.erc20.library import (
    ERC20_name,
    ERC20_symbol,
    ERC20_totalSupply,
    ERC20_decimals,
    ERC20_balanceOf,
    ERC20_allowance,
)
from contracts.shared.interfaces import IERC20
from contracts.shared.convert import felt_to_uint, uint_to_felt_unchecked
from contracts.shared.wad_ray import WadRay

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

#
# Storage
#

@storage_var
func gate_auth(address) -> (authorized):
end

@storage_var
func gate_live() -> (live):
end

# Admin fee charged on yield from underlying - ray
@storage_var
func gate_tax() -> (tax):
end

# Address to send admin fees to
@storage_var
func gate_taxman_address() -> (address):
end

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
end

#
# Getters
#

@view
func get_auth{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address) -> (
    authorized
):
    return gate_auth.read(address)
end

@view
func get_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (live):
    return gate_live.read()
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
>>>>>>> 81db9f5 (remove shrine interface)
    return gate_tax.read()
end

@view
func get_taxman_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    address
):
    return gate_taxman_address.read()
end

#
# Getters - ERC20
#

@view
func name{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (name):
    let (name) = ERC20_name()
    return (name)
end

@view
func symbol{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (symbol):
    let (symbol) = ERC20_symbol()
    return (symbol)
end

@view
func totalSupply{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    totalSupply : Uint256
):
    let (totalSupply : Uint256) = ERC20_totalSupply()
    return (totalSupply)
end

@view
func decimals{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (decimals):
    let (decimals) = ERC20_decimals()
    return (decimals)
end

@view
func balanceOf{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(account) -> (
    balance : Uint256
):
    let (balance : Uint256) = ERC20_balanceOf(account)
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
    authed, name, symbol, asset_address, tax, taxman_address
):
    ERC4626.initializer(name, symbol, asset_address)
    gate_auth.write(authed, TRUE)
    gate_live.write(TRUE)
    gate_tax.write(tax)
    gate_taxman_address.write(taxman_address)
    return ()
end

#
# External - Auth
#

@external
func authorize{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
    assert_auth()
    gate_auth.write(address, TRUE)
    Authorized.emit(address)
    return ()
end

@external
func revoke{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address):
    assert_auth()
    gate_auth.write(address, FALSE)
    Revoked.emit(address)
    return ()
end

@external
func kill{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    assert_auth()

    gate_live.write(FALSE)
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
    let (live) = gate_live.read()
    with_attr error_message("Gate: Gate is not live"):
        assert live = TRUE
    end

    # Sync
    sync_inner()

    let (shares : Uint256) = ERC4626.deposit(assets, receiver)

    # Update
    update_underlying_balance()

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
    let (live) = gate_live.read()
    with_attr error_message("Gate: Gate is not live"):
        assert live = TRUE
    end

    # Sync
    sync_inner()

    let (assets : Uint256) = ERC4626.mint(shares, receiver)

    # Update
    update_underlying_balance()

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

    # Sync
    sync_inner()

    let (shares : Uint256) = ERC4626.withdraw(assets, receiver, owner)

    # Update
    update_underlying_balance()

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

    # Sync
    sync_inner()

    let (assets : Uint256) = ERC4626.redeem(shares, receiver, owner)

    # Update
    update_underlying_balance()

    return (assets)
end

#
# External - Others
#

#
# Internal
#

# Similar to onlyOwner
func assert_auth{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    let (c) = get_caller_address()
    let (is_authed) = gate_auth.read(c)
    assert is_authed = TRUE
    return ()
end

@external
func sync{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    sync_inner()
    return ()
end

# Helper function to check for balance updates for rebasing tokens, and charge the admin fee.
func sync_inner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    alloc_locals

    # TODO Look into repeated calls to asset and contract address

    let (asset) = ERC4626.asset()
    let (vault) = get_contract_address()

    # Check last balance of underlying asset against latest balance
    let (last_updated) = gate_underlying_balance.read()
    let (latest) = IERC20.balanceOf(contract_address=asset, account=vault)
    let (latest_felt) = uint_to_felt_unchecked(latest)
    let (unincremented) = is_le(latest_felt, last_updated)
    if unincremented == FALSE:
        # Get difference in shares
        let difference = latest_felt - last_updated

        # Calculate amount of underlying chargeable
        let (difference_ray) = WadRay.wad_to_ray_unchecked(difference)
        let (tax_rate) = gate_tax.read()
        let (chargeable) = WadRay.rmul_unchecked(difference_ray, tax_rate)
        let (chargeable_wad) = WadRay.ray_to_wad(chargeable)
        let (chargeable_uint256 : Uint256) = felt_to_uint(chargeable_wad)

        # Transfer fees
        let (taxman) = gate_taxman_address.read()
        IERC20.transfer(contract_address=asset, recipient=taxman, amount=chargeable_uint256)

        let (updated_balance : Uint256) = IERC20.balanceOf(contract_address=asset, account=vault)
        let (updated_balance_felt) = uint_to_felt_unchecked(updated_balance)
        gate_underlying_balance.write(updated_balance_felt)

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
func update_underlying_balance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    # TODO Look into repeated calls to asset and contract address
    let (asset) = ERC4626.asset()
    let (vault) = get_contract_address()
    let (balance : Uint256) = IERC20.balanceOf(contract_address=asset, account=vault)
    let (balance_felt) = uint_to_felt_unchecked(balance)
    gate_underlying_balance.write(balance_felt)
    return ()
end
