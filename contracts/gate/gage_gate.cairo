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
from contracts.shared.interfaces import IERC20, IERC4626, IShrine
from contracts.shared.convert import uint_to_felt_unchecked
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

# Address of Shrine instance for given synthetic
@storage_var
func gate_shrine_address() -> (address):
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
func get_shrine{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (address):
    return gate_shrine_address.read()
end

@view
func get_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (tax):
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
    authed, shrine_address, name, symbol, asset_address, tax, taxman_address
):
    ERC4626.initializer(name, symbol, asset_address)
    gate_auth.write(authed, TRUE)
    gate_live.write(TRUE)
    gate_shrine_address.write(shrine_address)
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
    # Assert live
    let (live) = gate_live.read()
    with_attr error_message("Gate: Gate is not live"):
        assert live = TRUE
    end
    let (shares : Uint256) = ERC4626.deposit(assets, receiver)

    # Read `shrine` address
    # let (shrine) = gate_shrine_address.read()

    # Convert amount from Uint256 to felt
    # let (shares_felt) = uint_to_felt_unchecked(shares)

    # Get gage ID
    # let (gage_address) = ERC4626.asset_addr.read()
    # let (gage_id) = IShrine.get_gage_id(contract_address=shrine, gage_address=gage_address)
    # assert_not_zero(gage_id)

    # Call `shrine.deposit`
    # IShrine.deposit(
    #    contract_address=shrine,
    #    gage_id=gage_id,
    #    amount=shares_felt,
    #    user_address=receiver,
    #    trove_id=trove_id,
    # )

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
    # Assert live
    let (live) = gate_live.read()
    with_attr error_message("Gate: Gate is not live"):
        assert live = TRUE
    end

    let (assets : Uint256) = ERC4626.mint(shares, receiver)
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
    let (shares : Uint256) = ERC4626.withdraw(assets, receiver, owner)
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
    let (assets : Uint256) = ERC4626.redeem(shares, receiver, owner)
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
