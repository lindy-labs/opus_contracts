%lang starknet

from starkware.cairo.common.bool import TRUE
from starkware.starknet.common.syscalls import get_caller_address
from starkware.cairo.common.math import assert_not_zero, assert_le
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

const INFINITE_ALLOWANCE = -1
const UINT8_MAX = 255

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
func yin_name_storage() -> (str):
end

@storage_var
func yin_symbol_storage() -> (str):
end

@storage_var
func yin_decimals_storage() -> (ufelt):
end

@storage_var
func yin_shrine_address_storage() -> (address):
end

@storage_var
func yin_allowances_storage(owner, spender) -> (wad):
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

    with_attr error_message("Yin: decimals exceed 2^8 - 1"):
        assert_le(decimals, UINT8_MAX)
    end

    yin_decimals_storage.write(decimals)

    return ()
end

#
# View functions
#

@view
func name{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (str):
    return yin_name_storage.read()
end

@view
func symbol{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (str):
    return yin_symbol_storage.read()
end

@view
func totalSupply{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (wad):
    let (shrine_address) = yin_shrine_address_storage.read()
    let (total_supply) = IShrine.get_total_yin(contract_address=shrine_address)
    return (total_supply)
end

@view
func decimals{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (ufelt):
    return yin_decimals_storage.read()
end

@view
func balanceOf{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(account) -> (wad):
    let (shrine_address) = yin_shrine_address_storage.read()
    let (balance) = IShrine.get_yin(contract_address=shrine_address, user_address=account)
    return (balance)
end

@view
func allowance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    owner, spender
) -> (wad):
    return yin_allowances_storage.read(owner, spender)
end

#
# External functions
#

@external
func transfer{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    recipient, amount
) -> (bool):
    with_attr error_message("Yin: amount is not in the valid range [0, 2**125]"):
        WadRay.assert_result_valid_unsigned(amount)  # Valid range: [0, 2**125]
    end

    let (sender) = get_caller_address()
    _transfer(sender, recipient, amount)
    return (TRUE)
end

@external
func transferFrom{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    sender, recipient, amount
) -> (bool):
    with_attr error_message("Yin: amount is not in the valid range [0, 2**125]"):
        WadRay.assert_result_valid_unsigned(amount)  # Valid range: [0, 2**125]
    end

    let (caller) = get_caller_address()
    _spend_allowance(sender, caller, amount)
    _transfer(sender, recipient, amount)
    return (TRUE)
end

@external
func approve{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    spender, amount
) -> (bool):
    alloc_locals
    if amount != INFINITE_ALLOWANCE:
        with_attr error_message("Yin: amount is not in the valid range [0, 2**125]"):
            WadRay.assert_result_valid_unsigned(amount)  # Valid range: [0, 2**125]
        end
        tempvar range_check_ptr = range_check_ptr
    else:
        tempvar range_check_ptr = range_check_ptr
    end

    let (caller) = get_caller_address()
    _approve(caller, spender, amount)
    return (TRUE)
end

#
# Private functions
#

func _transfer{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    sender, recipient, amount
):
    with_attr error_message("Yin: cannot transfer from the zero address"):
        assert_not_zero(sender)
    end

    with_attr error_message("Yin: cannot transfer to the zero address"):
        assert_not_zero(recipient)
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
    with_attr error_message("Yin: cannot approve from the zero address"):
        assert_not_zero(owner)
    end

    with_attr error_message("Yin: cannot approve to the zero address"):
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
