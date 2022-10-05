%lang starknet

from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_le, assert_not_zero
from starkware.starknet.common.syscalls import get_caller_address

from contracts.shrine.interface import IShrine

from contracts.lib.aliases import address, bool, str, ufelt, wad
from contracts.lib.wad_ray import WadRay

// Yin-ERC20
// -------------------------------
// This is a modified OpenZeppelin ERC20 contract that allows users to interact with Yin as a standard ERC20 token.
// Yin has an internal representation inside shrine.cairo (in the storage variable `shrine_yin`), together
// with minting (`forge`), burning (`melt`), and transfer (`move_yin`) functions.
//
// However, this functionality is not enough to make yin usable as a fully-fledged token, and so this modified ERC-20 contract serves
// as a wrapper for "raw" yin, enabling its use in the broader DeFi ecosystem.

//
// Constants
//

const INFINITE_ALLOWANCE = -1;
const UINT8_MAX = 255;

//
// Events
//

@event
func Transfer(from_, to, value) {
}

@event
func Approval(owner, spender, value) {
}

//
// Storage
//

@storage_var
func yin_name() -> (name: str) {
}

@storage_var
func yin_symbol() -> (symbol: str) {
}

@storage_var
func yin_decimals() -> (decimals: ufelt) {
}

@storage_var
func yin_shrine_address() -> (addr: address) {
}

@storage_var
func yin_allowances(owner, spender) -> (allowance: wad) {
}

//
// Constructor
//

@constructor
func constructor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    name: str, symbol: str, decimals: wad, shrine: address
) {
    yin_name.write(name);
    yin_symbol.write(symbol);
    yin_shrine_address.write(shrine);

    with_attr error_message("Yin: decimals exceed 2^8 - 1") {
        assert_le(decimals, UINT8_MAX);
    }

    yin_decimals.write(decimals);

    return ();
}

//
// View functions
//

@view
func name{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (name: str) {
    return yin_name.read();
}

@view
func symbol{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (symbol: str) {
    return yin_symbol.read();
}

@view
func totalSupply{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    total_supply: wad
) {
    let (shrine: address) = yin_shrine_address.read();
    let (total_supply: wad) = IShrine.get_total_yin(shrine);
    return (total_supply,);
}

@view
func decimals{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    decimals: ufelt
) {
    return yin_decimals.read();
}

@view
func balanceOf{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(account) -> (
    balance: wad
) {
    let (shrine: address) = yin_shrine_address.read();
    let (balance: wad) = IShrine.get_yin(contract_address=shrine, user=account);
    return (balance,);
}

@view
func allowance{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(owner, spender) -> (
    allowance: wad
) {
    return yin_allowances.read(owner, spender);
}

//
// External functions
//

@external
func transfer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    recipient: address, amount: wad
) -> (success: bool) {
    with_attr error_message("Yin: amount is not in the valid range [0, 2**125]") {
        WadRay.assert_valid_unsigned(amount);  // Valid range: [0, 2**125]
    }

    let (sender: address) = get_caller_address();
    _transfer(sender, recipient, amount);
    return (TRUE,);
}

@external
func transferFrom{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    sender: address, recipient: address, amount: wad
) -> (success: bool) {
    with_attr error_message("Yin: amount is not in the valid range [0, 2**125]") {
        WadRay.assert_valid_unsigned(amount);  // Valid range: [0, 2**125]
    }

    let (caller: address) = get_caller_address();
    _spend_allowance(sender, caller, amount);
    _transfer(sender, recipient, amount);
    return (TRUE,);
}

@external
func approve{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    spender: address, amount: wad
) -> (success: bool) {
    alloc_locals;
    if (amount != INFINITE_ALLOWANCE) {
        with_attr error_message("Yin: amount is not in the valid range [0, 2**125]") {
            WadRay.assert_valid_unsigned(amount);  // Valid range: [0, 2**125]
        }
        tempvar range_check_ptr = range_check_ptr;
    } else {
        tempvar range_check_ptr = range_check_ptr;
    }

    let (caller: address) = get_caller_address();
    _approve(caller, spender, amount);
    return (TRUE,);
}

//
// Private functions
//

func _transfer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    sender: address, recipient: address, amount: wad
) {
    with_attr error_message("Yin: cannot transfer to the zero address") {
        assert_not_zero(recipient);
    }

    let (shrine: address) = yin_shrine_address.read();

    // Calling shrine's `move_yin` function, which handles the rest of the transfer logic
    IShrine.move_yin(contract_address=shrine, src=sender, dst=recipient, amount=amount);

    Transfer.emit(sender, recipient, amount);
    return ();
}

func _approve{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    owner: address, spender: address, amount: wad
) {
    with_attr error_message("Yin: cannot approve from the zero address") {
        assert_not_zero(owner);
    }

    with_attr error_message("Yin: cannot approve to the zero address") {
        assert_not_zero(spender);
    }

    yin_allowances.write(owner, spender, amount);
    Approval.emit(owner, spender, amount);
    return ();
}

func _spend_allowance{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    owner: address, spender: address, amount: wad
) {
    alloc_locals;

    let (current_allowance: wad) = yin_allowances.read(owner, spender);
    if (current_allowance != INFINITE_ALLOWANCE) {
        with_attr error_message("Yin: insufficient allowance") {
            _approve(owner, spender, WadRay.sub_unsigned(current_allowance, amount));  // Reverts if amount > current_allowance
        }

        return ();
    }

    return ();
}
