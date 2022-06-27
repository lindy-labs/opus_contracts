%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero
from starkware.cairo.common.uint256 import Uint256, uint256_le, uint256_sub
from starkware.starknet.common.syscalls import get_caller_address, get_contract_address

from contracts.lib.erc4626.library import (
    ERC4626_initializer,
    ERC4626_asset,
    ERC4626_asset_addr,
    ERC4626_totalAssets,
    ERC4626_convertToShares,
    ERC4626_convertToAssets,
    ERC4626_maxDeposit,
    ERC4626_previewDeposit,
    ERC4626_deposit,
    ERC4626_maxMint,
    ERC4626_previewMint,
    ERC4626_mint,
    ERC4626_maxWithdraw,
    ERC4626_previewWithdraw,
    ERC4626_withdraw,
    ERC4626_maxRedeem,
    ERC4626_previewRedeem,
    ERC4626_redeem,
)

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

@event
func Pledged(user_address, trove_id, amt):
end

@event
func Recouped(user_address, trove_id, amt):
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

# Address of gage
@storage_var
func gate_gage_address() -> (address):
end

# Exchange rate of Gate share to underlying (wad)
@storage_var
func gate_exchange_rate() -> (rate):
end

# Total number of gage tokens held by contract (wad)
@storage_var
func gate_gage_total() -> (total):
end

@storage_var
func gate_gage_pledged(user_address, trove_id) -> (amount):
end

# Timestamp of the last update of yield from underlying gage
@storage_var
func gate_gage_last_updated() -> (timestamp):
end

#
# Getters
#

@view
func name{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (name : felt):
    let (name) = ERC20_name()
    return (name)
end

@view
func symbol{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (symbol : felt):
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
func decimals{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    decimals : felt
):
    let (decimals) = ERC20_decimals()
    return (decimals)
end

@view
func balanceOf{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    account : felt
) -> (balance : Uint256):
    let (balance : Uint256) = ERC20_balanceOf(account)
    return (balance)
end

# Non-transferable
@view
func allowance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    owner : felt, spender : felt
) -> (remaining : Uint256):
    return (Uint256(0, 0))
end

#
# Constructor
#

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    authed, shrine_address, name, symbol, gage_address
):
    ERC4626_initializer(name, symbol, gage_address)
    gate_auth.write(authed, TRUE)
    gate_live.write(TRUE)
    gate_shrine_address.write(shrine_address)
    gate_gage_address.write(gage_address)
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
    recipient : felt, amount : Uint256
) -> (success : felt):
    return (FALSE)
end

@external
func transferFrom{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    sender : felt, recipient : felt, amount : Uint256
) -> (success : felt):
    return (FALSE)
end

@external
func approve{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    spender : felt, amount : Uint256
) -> (success : felt):
    return (FALSE)
end

#
# External - ERC4626
#

@view
func asset{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    assetTokenAddress : felt
):
    let (asset : felt) = ERC4626_asset()
    return (asset)
end

@view
func totalAssets{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    totalManagedAssets : Uint256
):
    let (total : Uint256) = ERC4626_totalAssets()
    return (total)
end

@view
func convertToShares{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    assets : Uint256
) -> (shares : Uint256):
    let (shares : Uint256) = ERC4626_convertToShares(assets)
    return (shares)
end

@view
func convertToAssets{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shares : Uint256
) -> (assets : Uint256):
    let (assets : Uint256) = ERC4626_convertToAssets(shares)
    return (assets)
end

@view
func maxDeposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    receiver : felt
) -> (maxAssets : Uint256):
    let (maxAssets : Uint256) = ERC4626_maxDeposit(receiver)
    return (maxAssets)
end

@view
func previewDeposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    assets : Uint256
) -> (shares : Uint256):
    let (shares) = ERC4626_previewDeposit(assets)
    return (shares)
end

@external
func deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    assets : Uint256, receiver : felt
) -> (shares : Uint256):
    let (shares) = ERC4626_deposit(assets, receiver)
    return (shares)
end

@view
func maxMint{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    receiver : felt
) -> (maxShares : Uint256):
    let (maxShares : Uint256) = ERC4626_maxMint(receiver)
    return (maxShares)
end

@view
func previewMint{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shares : Uint256
) -> (assets : Uint256):
    let (assets) = ERC4626_previewMint(shares)
    return (assets)
end

@external
func mint{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shares : Uint256, receiver : felt
) -> (assets : Uint256):
    let (assets : Uint256) = ERC4626_mint(shares, receiver)
    return (assets)
end

@view
func maxWithdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    owner : felt
) -> (maxAssets : Uint256):
    let (maxWithdraw : Uint256) = ERC4626_maxWithdraw(owner)
    return (maxWithdraw)
end

@view
func previewWithdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    assets : Uint256
) -> (shares : Uint256):
    let (shares : Uint256) = ERC4626_previewWithdraw(assets)
    return (shares)
end

@external
func withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    assets : Uint256, receiver : felt, owner : felt
) -> (shares : Uint256):
    let (shares : Uint256) = ERC4626_withdraw(assets, receiver, owner)
    return (shares)
end

@view
func maxRedeem{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(owner : felt) -> (
    maxShares : Uint256
):
    let (maxShares : Uint256) = ERC4626_maxRedeem(owner)
    return (maxShares)
end

@view
func previewRedeem{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shares : Uint256
) -> (assets : Uint256):
    let (assets : Uint256) = ERC4626_previewRedeem(shares)
    return (assets)
end

@external
func redeem{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    shares : Uint256, receiver : felt, owner : felt
) -> (assets : Uint256):
    let (assets : Uint256) = ERC4626_redeem(shares, receiver, owner)
    return (assets)
end

#
# External - Others
#

@external
func pledge{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_address, trove_id, amt : Uint256
):
    alloc_locals

    # Assert live
    let (live) = gate_live.read()
    with_attr error_message("Gate: Gate is not live"):
        assert live = TRUE
    end

    # Check balance
    let (gage_address) = gate_gage_address.read()
    let before : Uint256 = IERC20.balanceOf(contract_address=gage_address, account=user_address)
    let (sufficient) = uint256_le(amt, before)
    with_attr error_message("Gate: Insufficient balance"):
        assert sufficient = TRUE
    end

    # Check allowance
    let (dst) = get_contract_address()
    let allowed : Uint256 = IERC20.allowance(
        contract_address=gage_address, owner=user_address, spender=dst
    )
    let (approved) = uint256_le(amt, allowed)
    with_attr error_message("Gate: Insufficient allowance"):
        assert approved = TRUE
    end

    # Transfer ERC20
    IERC20.transferFrom(
        contract_address=gage_address, sender=user_address, recipient=dst, amount=amt
    )

    # Assert successful transfer
    let after : Uint256 = IERC20.balanceOf(contract_address=gage_address, account=user_address)
    let (expected) = uint256_sub(before, amt)
    with_attr error_message("Gate: Unsuccessful transfer"):
        assert after = expected
    end

    # Convert amount from Uint256 to felt
    let (amt_felt) = uint_to_felt_unchecked(amt)

    # Add to Gate's system total
    let (current_total) = gate_gage_total.read()
    let new_total = current_total + amt_felt
    gate_gage_total.write(new_total)

    # Calculate amount of shares to mint
    let (exchange_rate) = gate_exchange_rate.read()
    let (shares) = WadRay.wunsigned_div(amt_felt, exchange_rate)
    let (existing_shares) = gate_gage_pledged.read(user_address, trove_id)
    let (new_shares) = WadRay.add_unsigned(shares, existing_shares)
    gate_gage_pledged.write(user_address, trove_id, new_shares)

    # Read `shrine` address
    let (shrine) = gate_shrine_address.read()

    # Get gage ID
    let (gage_id) = IShrine.get_gage_id(contract_address=shrine, gage_address=gage_address)
    assert_not_zero(gage_id)

    # Call `shrine.deposit`
    IShrine.deposit(
        contract_address=shrine,
        gage_id=gage_id,
        amount=amt_felt,
        user_address=user_address,
        trove_id=trove_id,
    )

    Pledged.emit(user_address, trove_id, amt_felt)

    return ()
end

@external
func recoup{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(gage_address, amt):
    # Call `shrine.withdraw`

    # Get underlying amount

    # Update total

    # Decrement shares

    # Transfer ERC20

    return ()
end

# Update exchange rate of shares to underlying
@external
func sync{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    return ()
end

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
