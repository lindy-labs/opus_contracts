# TODO:
# * document
#   functions
# * from the WP "stablecoins deposited this way are lent out to trusted money market protocols in order to generate yield, driving the global collateralization ratio up"
#   as @CrisBRM said in Slack, these should be deposited to Aave and Sandclock, once they are available on StarkNet (Sandclock has priority, but Aave will prob launch sooner)
# * we should have deploy scripts; there are interdependencies between various modules, take that into account
# * is there a good way to assure that amount that's passed to deposit/withdraw is already scaled? do we need to check for it even?
# * internal functions could go to library.cairo, but then how to deal w/ @storage_vars (because internals need to r/w to them)?
#   explore a pattern where storage would be in a separate file and namespace maybe? with dedicated getters and setters for each @storage_var

%lang starknet

from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero, assert_le, unsigned_div_rem
from starkware.cairo.common.uint256 import (
    Uint256,
    uint256_eq,
    uint256_le,
    uint256_mul,
    uint256_sub,
    uint256_unsigned_div_rem,
)
from starkware.starknet.common.syscalls import get_caller_address, get_contract_address

from contracts.shared.interfaces import IERC20, IERC20Mintable, IERC20Burnable, IUSDa
from contracts.shared.convert import felt_to_uint, uint_to_felt_unchecked
from contracts.lib.openzeppelin.access.ownable import (
    Ownable_initializer,
    Ownable_get_owner,
    Ownable_only_owner,
    Ownable_transfer_ownership,
)

# Direct Deposit Stablecoin contract
# allows to mint USDa via depositing a stablecoin (DAI, USDC),
# there's one instance of this contract deployed per stablecoin

# 100% in basis points
const HUNDRED_PERCENT_BPS = 10000

#
# Events
#

@event
func ReserveAddressChange(old_value : felt, new_value : felt):
end

@event
func StabilityFeeChange(old_value : felt, new_value : felt):
end

@event
func TreasuryAddressChange(old_value : felt, new_value : felt):
end

#
# Storage
#

# address of Aura reserve
@storage_var
func reserve_address() -> (addr : felt):
end

# stability fee in basis points
@storage_var
func stability_fee() -> (fee : felt):
end

# address of underlying stablecoin that can be directly deposited to get USDa
@storage_var
func stablecoin_address() -> (addr : felt):
end

# address of Aura treasury
@storage_var
func treasury_address() -> (addr : felt):
end

# address of the USDa token contract
@storage_var
func usda_address() -> (addr : felt):
end

#
# Getters
#

@view
func get_owner_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    addr : felt
):
    let (addr) = Ownable_get_owner()
    return (addr)
end

@view
func get_reserve_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    addr : felt
):
    let (addr) = reserve_address.read()
    return (addr)
end

@view
func get_stability_fee{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    fee : felt
):
    let (fee) = stability_fee.read()
    return (fee)
end

@view
func get_stablecoin_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    ) -> (addr : felt):
    let (addr) = stablecoin_address.read()
    return (addr)
end

@view
func get_treasury_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    addr : felt
):
    let (addr) = treasury_address.read()
    return (addr)
end

@view
func get_usda_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    addr : felt
):
    let (addr) = usda_address.read()
    return (addr)
end

#
# Setters
#

@external
func set_owner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(addr : felt):
    # this function already does only owner and zero address checks internally
    # and also emits an event
    Ownable_transfer_ownership(addr)
    return ()
end

@external
func set_reserve_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    addr : felt
):
    Ownable_only_owner()
    with_attr error_message("DD: address cannot be zero"):
        assert_not_zero(addr)
    end

    let (old) = reserve_address.read()
    reserve_address.write(addr)

    ReserveAddressChange.emit(old, addr)

    return ()
end

@external
func set_stability_fee{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    fee : felt
):
    Ownable_only_owner()
    with_attr error_message("DD: invalid stability fee"):
        assert_le(fee, HUNDRED_PERCENT_BPS)
    end

    let (old) = stability_fee.read()
    stability_fee.write(fee)

    StabilityFeeChange.emit(old, fee)

    return ()
end

@external
func set_treasury_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    addr : felt
):
    Ownable_only_owner()
    with_attr error_message("DD: address cannot be zero"):
        assert_not_zero(addr)
    end

    let (old) = treasury_address.read()
    treasury_address.write(addr)

    TreasuryAddressChange.emit(old, addr)

    return ()
end

#
# Constructor
#

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    owner : felt,
    stablecoin_addr : felt,
    usda_addr : felt,
    reserve_addr : felt,
    treasury_addr : felt,
    stability_fee : felt,
):
    # TODO: assert not zeroes, assert conforming to ERC20s?
    #       use initializable from OZ lib?
    Ownable_initializer(owner)
    DDS_initializer(stablecoin_addr, usda_addr, reserve_addr, treasury_addr, stability_fee)
    return ()
end

#
# View functions
#

@view
func get_max_mint_amount{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    amount : Uint256
):
    # formula (11) in the whitepaper:
    # maxDirectMintAmount(t) = (collateralPool(t) / minDirectMintRatio) - totalUSDa(t)

    # let (usda_addr : felt) = usda_address.read()

    # TODO: getting the total collateral of USDa is done here via a call
    #       to the USDa contract, but it's just a placeholder and could (maybe even should)
    #       be changed; I just used it as a temporary solution during dev, don't
    #       be afraid to make it better -- milan
    # let (total_collateral : felt) = IUSDa.get_total_collateral(contract_address=usda_addr)

    # TODO: what unit is this in? based on that, do the +25% calculation below
    # correctly; currently assuming basis points
    # let (collateralization_ratio : felt) = IUSDa.get_collateralization_ratio(
    #     contract_address=usda_addr
    # )

    # from the WP:
    # "using the Direct Deposit method is reserved for periods where capital is not being
    # utilized efficiently, when USDa’s collateralization ratio is equal or greater than 25%
    # of the target collateralization ratio"
    # the 25% value should be configurable
    # the value is the threshold *above* the ideal rate of 150%, as such, it should fall into
    # a range, of 10-50; talk to Cris for details

    # rounding down here is ok
    # let (min_direct_mint_ratio : felt, _) = unsigned_div_rem(
    #     collateralization_ratio * (HUNDRED_PERCENT_BPS + 2500), HUNDRED_PERCENT_BPS
    # )

    # let (usda_balance_uint : Uint256) = IERC20.totalSupply(contract_address=usda_addr)
    # let (usda_balance : felt) = uint_to_felt_unchecked(usda_balance_uint)

    # TODO: finish this calc, return a Uint256
    # let (max_mint : felt) = (collateralization_ratio * min_direct_mint_ratio) - usda_balance

    # TODO: should there be a check to see what would be the result of this mint
    #       and if it the delta is too big, revert?

    return (Uint256(low=100000, high=0))
end

#
# Externals
#

# stablecoin -> USDa
# amount, should be scaled by 18 (USDa decimals)
@external
func deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(amount : Uint256):
    alloc_locals
    # TODO: inline comments

    # TODO: assert inputs

    # check if can mint:
    # max_mint_amount
    # collat ratio

    let (max_mint : Uint256) = get_max_mint_amount()
    with_attr error_message("DD: deposit amount exceeds mint limit"):
        let (is_in_limit) = uint256_le(amount, max_mint)
        assert is_in_limit = 1
    end

    let (caller : felt) = get_caller_address()
    let (recipient : felt) = get_contract_address()
    let (stablecoin : felt) = stablecoin_address.read()

    let (transfer_did_succeed : felt) = IERC20.transferFrom(
        contract_address=stablecoin, sender=caller, recipient=recipient, amount=amount
    )
    with_attr error_message("DD: transferFrom failed"):
        assert transfer_did_succeed = TRUE
    end

    let (usda : felt) = usda_address.read()
    let (reserve : felt) = reserve_address.read()
    let (treasury : felt) = treasury_address.read()
    let (caller_amount : Uint256, reserve_amount : Uint256,
        treasury_amount : Uint256) = calculate_mint_distribution(amount)

    IERC20Mintable.mint(contract_address=usda, recipient=caller, amount=caller_amount)
    IERC20Mintable.mint(contract_address=usda, recipient=reserve, amount=reserve_amount)
    IERC20Mintable.mint(contract_address=usda, recipient=treasury, amount=treasury_amount)

    # TODO: emit an event

    return ()
end

# USDa -> stablecoin
# amount, should be scaled by 18 (USDa decimals)
@external
func withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(amount : Uint256):
    alloc_locals

    let (caller : felt) = get_caller_address()
    let (usda : felt) = usda_address.read()
    let (stablecoin : felt) = stablecoin_address.read()

    IERC20Burnable.burn(contract_address=usda, owner=caller, amount=amount)
    IERC20.transfer(contract_address=stablecoin, recipient=caller, amount=amount)

    # TODO: emit an event

    return ()
end

#
# internal
#

func DDS_initializer{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    stablecoin_addr : felt,
    usda_addr : felt,
    reserve_addr : felt,
    treasury_addr : felt,
    _stability_fee : felt,
):
    with_attr error_message("DD: address cannot be zero"):
        assert_not_zero(stablecoin_addr)
        assert_not_zero(usda_addr)
        assert_not_zero(reserve_addr)
        assert_not_zero(treasury_addr)
    end

    with_attr error_message("DD: invalid stability fee"):
        assert_le(_stability_fee, HUNDRED_PERCENT_BPS)
    end

    # these two variables are only ever set once, here,
    # during the deployment of the contract
    stablecoin_address.write(stablecoin_addr)
    usda_address.write(usda_addr)

    # the rest is configurable via setters
    reserve_address.write(reserve_addr)
    treasury_address.write(treasury_addr)
    stability_fee.write(_stability_fee)

    return ()
end

func calculate_mint_distribution{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    mint_amount : Uint256
) -> (to_depositor : Uint256, to_reserve : Uint256, to_treasury : Uint256):
    alloc_locals

    let (stability_fee_ : felt) = stability_fee.read()
    let depositor_gets_bps : Uint256 = felt_to_uint(HUNDRED_PERCENT_BPS - stability_fee_)
    let (depositor_amount_mul : Uint256, carry : Uint256) = uint256_mul(
        mint_amount, depositor_gets_bps
    )
    with_attr error_message("DD: mint amount too high"):
        let (no_carry) = uint256_eq(Uint256(0, 0), carry)
        assert no_carry = TRUE
    end

    # we don't care about the reminder as that gets distributed
    # to the reserve and treasury
    let (depositor_amount : Uint256, _) = uint256_unsigned_div_rem(
        depositor_amount_mul, Uint256(low=HUNDRED_PERCENT_BPS, high=0)
    )

    # split the stability amount between reserve and treasury,
    # with the treasury getting the reminder in case of an uneven split
    let stability_amount : Uint256 = uint256_sub(mint_amount, depositor_amount)
    let (reserve_amount : Uint256, _) = uint256_unsigned_div_rem(
        stability_amount, Uint256(low=2, high=0)
    )
    let treasury_amount : Uint256 = uint256_sub(stability_amount, reserve_amount)

    return (depositor_amount, reserve_amount, treasury_amount)
end
