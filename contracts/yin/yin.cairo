%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin

from contracts.interfaces import IShrine

# Yin-ERC20
# -------------------------------
# This is a modified OpenZeppelin ERC20 contract that allows users to interact with Yin as a standard ERC20 token.
# Yin has an internal representation inside shrine.cairo (in the storage variable `shrine_yin_storage`), together
# with minting (`forge`), burning (`melt`), and transfer (`move_yin`) functions.
#
# However, this functionality is not enough to make yin usable as a token, and so this modified ERC-20 contract serves
# as a wrapper for "raw" yin, enabling its use in the broader DeFi ecosystem.

#
# Events
#

@event
func Transfer(from_ : felt, to : felt, value : Uint256):
end

@event
func Approval(owner : felt, spender : felt, value : Uint256):
end

#
# Storage
#

@storage_var
func yin_name_storage() -> (name : felt):
end

@storage_var
func yin_symbol_storage() -> (symbol : felt):
end

@storage_var
func yin_decimals_storage() -> (decimals : felt):
end

@storage_var
func yin_shrine_address_storage() -> (address):
end

@storage_var
func yin_allowances_storage(owner : felt, spender : felt) -> (allowance : Uint256):
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
