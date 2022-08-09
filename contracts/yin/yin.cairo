%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.starknet.common.syscalls import get_caller_address
from starkware.cairo.common.math import assert_not_zero, assert_lt
from starkware.cairo.common.cairo_builtins import HashBuiltin

from contracts.interfaces import IShrine
from contracts.shared.wad_ray import WadRay
# Yin-ERC20
# -------------------------------
# This is a modified OpenZeppelin ERC20 contract that allows users to interact with Yin as a standard ERC20 token.
# Yin has an internal representation inside shrine.cairo (in the storage variable `shrine_yin_storage`), together
# with minting (`forge`), burning (`melt`), and transfer (`move_yin`) functions.
#
# However, this functionality is not enough to make yin usable as a fully-fledged token, and so this modified ERC-20 contract serves
# as a wrapper for "raw" yin, enabling its use in the broader DeFi ecosystem.

#
# Constants
#

const INFINITE_ALLOWANCE = 2 ** 125
const UINT8_MAX = 256
#
# Events
#

@event
func Transfer(from_, to, value):
end

@event
func Approval(owner, spender, value):
end

#
# Storage
#

@storage_var
func yin_name_storage() -> (name):
end

@storage_var
func yin_symbol_storage() -> (symbol):
end

@storage_var
func yin_decimals_storage() -> (decimals):
end

@storage_var
func yin_shrine_address_storage() -> (address):
end

@storage_var
func yin_allowances_storage(owner, spender) -> (allowance):
end

#
# Constructor
#

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    name, symbol, decimals, shrine_address
):
    yin_name_storage.write(name)
    yin_symbol_storage.write(symbol)
    yin_shrine_address_storage.write(shrine_address)

    with_attr error_message("ERC20: decimals exceed 2^8"):
        assert_lt(decimals, UINT8_MAX)
    end

    yin_decimals_storage.write(decimals)

    return ()
end

#
# View functions
#

@view
func name{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (name):
    let (name) = yin_name_storage.read()
    return (name)
end

@view
func symbol{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (symbol):
    let (symbol) = yin_symbol_storage.read()
    return (symbol)
end

@view
func totalSupply{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    total_supply
):
    let (shrine_address) = yin_shrine_address_storage.read()
    let (total_supply) = IShrine.get_total_yin(contract_address=shrine_address)
    return (total_supply)
end

@view
func decimals{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (decimals):
    let (decimals) = yin_decimals_storage.read()
    return (decimals)
end

@view
func balanceOf{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(account) -> (
    balance
):
    let (shrine_address) = yin_shrine_address_storage.read()
    let (balance) = IShrine.get_yin(contract_address=shrine_address, user_address=account)
    return (balance)
end

@view
func allowance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    owner, spender
) -> (remaining):
    let (remaining) = yin_allowances_storage.read(owner, spender)
    return (remaining)
end

#
# External functions
#
@external
func transfer{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    recipient, amount
) -> (success):
    let (sender) = get_caller_address()
    _transfer(sender, recipient, amount)
    return (TRUE)
end

@external
func transferFrom{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    sender, recipient, amount
) -> (success):
    let (caller) = get_caller_address()
    _spend_allowance(sender, caller, amount)
    _transfer(sender, recipient, amount)
    return (TRUE)
end

@external
func approve{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    spender, amount
) -> (success):
    let (caller) = get_caller_address()
    _approve(caller, spender, amount)
    return (TRUE)
end

#
# Private functions
#

# Difference from OZ: Allows transfers to zero-address as "burning"
func _transfer{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    sender, recipient, amount
):
    with_attr error_message("Yin: amount is not in the valid range [0, 2**125]"):
        WadRay.assert_result_valid_unsigned(amount)  # Valid range: [0, 2**125]
    end

    with_attr error_message("Yin: cannot transfer from the zero address"):
        assert_not_zero(sender)
    end

    let (shrine_address) = yin_shrine_address_storage.read()

    # Calling shrine's `move_yin` function, which handles the rest of the transfer logic
    IShrine.move_yin(
        contract_address=shrine_address, src_address=sender, dst_address=recipient, amount=amount
    )

    Transfer.emit(sender, recipient, amount)
    return ()
end

func _approve{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    owner, spender, amount
):
    with_attr error_message("Yin: amount is not in the valid range [0, 2**125]"):
        WadRay.assert_result_valid_unsigned(amount)  # Valid range: [0, 2**125]
    end

    with_attr error_message("ERC20: cannot approve from the zero address"):
        assert_not_zero(owner)
    end

    with_attr error_message("ERC20: cannot approve to the zero address"):
        assert_not_zero(spender)
    end

    yin_allowances_storage.write(owner, spender, amount)
    Approval.emit(owner, spender, amount)
    return ()
end

func _spend_allowance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    owner, spender, amount
):
    alloc_locals

    # This check here is probably unnecessary
    with_attr error_message("Yin: amount is not in the valid range [0, 2**125]"):
        WadRay.assert_result_valid_unsigned(amount)  # Valid range: [0, 2**125]
    end

    let (current_allowance) = yin_allowances_storage.read(owner, spender)
    if current_allowance != INFINITE_ALLOWANCE:
        with_attr error_message("Yin: insufficient allowance"):
            let (new_allowance) = WadRay.sub_unsigned(current_allowance, amount)  # Reverts if amount > current_allowance
        end

        _approve(owner, spender, new_allowance)
        return ()
    end

    return ()
end
