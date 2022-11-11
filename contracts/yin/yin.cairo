%lang starknet

from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_le, assert_not_zero, split_felt
from starkware.cairo.common.uint256 import (
    ALL_ONES,
    Uint256,
    assert_uint256_le,
    uint256_check,
    uint256_sub,
)
from starkware.starknet.common.syscalls import get_caller_address, get_contract_address

from contracts.shrine.interface import IShrine

from contracts.lib.aliases import address, bool, str, ufelt, wad
from contracts.lib.interfaces import IFlashBorrower
from contracts.lib.openzeppelin.security.reentrancyguard.library import ReentrancyGuard
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

const UINT8_MAX = 255;

//
// Events
//

@event
func Transfer(from_: address, to: address, value: Uint256) {
}

@event
func Approval(owner: address, spender: address, value: Uint256) {
}

@event
func FlashMint(initiator: address, receiver: address, token: address, amount: Uint256) {
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
func yin_allowances(owner, spender) -> (allowance: Uint256) {
}

//
// Constructor
//

@constructor
func constructor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    name: str, symbol: str, decimals: ufelt, shrine: address
) {
    yin_name.write(name);
    yin_symbol.write(symbol);
    yin_shrine_address.write(shrine);

    with_attr error_message("Yin: Decimals exceed 2^8 - 1") {
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
func decimals{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    decimals: ufelt
) {
    return yin_decimals.read();
}

@view
func totalSupply{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    total_supply: Uint256
) {
    let (shrine: address) = yin_shrine_address.read();
    let (total_yin: wad) = IShrine.get_total_yin(shrine);
    let (total_supply: Uint256) = WadRay.to_uint(total_yin);
    return (total_supply,);
}

@view
func balanceOf{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    account: address
) -> (balance: Uint256) {
    let (shrine: address) = yin_shrine_address.read();
    let (yin: wad) = IShrine.get_yin(shrine, account);
    let (balance: Uint256) = WadRay.to_uint(yin);
    return (balance,);
}

@view
func allowance{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    owner: address, spender: address
) -> (allowance: Uint256) {
    return yin_allowances.read(owner, spender);
}

//
// External functions
//

@external
func transfer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    recipient: address, amount: Uint256
) -> (success: bool) {
    %{ print(ids.amount) %}
    let (sender: address) = get_caller_address();
    _transfer(sender, recipient, amount);
    return (TRUE,);
}

@external
func transferFrom{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    sender: address, recipient: address, amount: Uint256
) -> (success: bool) {
    let (caller: address) = get_caller_address();
    _spend_allowance(sender, caller, amount);
    _transfer(sender, recipient, amount);
    return (TRUE,);
}

@external
func approve{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    spender: address, amount: Uint256
) -> (success: bool) {
    let (caller: address) = get_caller_address();
    _approve(caller, spender, amount);
    return (TRUE,);
}

//
// Private functions
//

func _transfer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    sender: address, recipient: address, amount: Uint256
) {
    with_attr error_message("Yin: Cannot transfer to the zero address") {
        assert_not_zero(recipient);
    }

    with_attr error_message("Yin: Amount not valid") {
        uint256_check(amount);
    }

    let (shrine: address) = yin_shrine_address.read();

    // Calling shrine's `move_yin` function, which handles the rest of the transfer logic
    IShrine.move_yin(shrine, sender, recipient, WadRay.from_uint(amount));

    Transfer.emit(sender, recipient, amount);
    return ();
}

func _approve{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    owner: address, spender: address, amount: Uint256
) {
    with_attr error_message("Yin: Cannot approve from the zero address") {
        assert_not_zero(owner);
    }

    with_attr error_message("Yin: Cannot approve to the zero address") {
        assert_not_zero(spender);
    }

    with_attr error_message("Yin: Amount not valid") {
        uint256_check(amount);
    }

    yin_allowances.write(owner, spender, amount);
    Approval.emit(owner, spender, amount);
    return ();
}

func _spend_allowance{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    owner: address, spender: address, amount: Uint256
) {
    alloc_locals;

    let (current_allowance: Uint256) = yin_allowances.read(owner, spender);
    if (current_allowance.low == ALL_ONES and current_allowance.high == ALL_ONES) {
        // infinite allowance 2**256 - 1
        return ();
    }

    with_attr error_message("Yin: Insufficient allowance") {
        assert_uint256_le(amount, current_allowance);
        let (new_allowance: Uint256) = uint256_sub(current_allowance, amount);
        _approve(owner, spender, new_allowance);
    }

    return ();
}

//
//
//   Flash minting
//
//         |
//        / \
//       / _ \
//      |.o '.|
//      |'._.'|
//      |     |
//    ,'| LFG |`.
//   /  |  |  |  \
//   |,-'--|--'-.|
//
//

// The value of keccak256("ERC3156FlashBorrower.onFlashLoan") as per EIP3156
// it is supposed to be returned from the onFlashLoan function by the receiver
// the raw value is 0x439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd9
// and here it's split into Uint256 parts
const ON_FLASH_MINT_SUCCESS_LOW = 302690805846553493147886643436372200921;
const ON_FLASH_MINT_SUCCESS_HIGH = 89812638168441061617712796123820912833;

// Percentage value of Yin's total supply that can be flash minted
const FLASH_MINT_AMOUNT_PCT = 5 * WadRay.WAD_PERCENT;

@view
func maxFlashLoan{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    token: address
) -> (amount: Uint256) {
    let (yin: address) = get_contract_address();
    // can only flash mint our own Yin synthetic
    if (token == yin) {
        // let (yin_balance: Uint256) = totalSupply();
        let (supply: Uint256) = totalSupply();
        let yin_balance: wad = WadRay.from_uint(supply);
        let max: Uint256 = WadRay.to_uint(WadRay.wmul(yin_balance, FLASH_MINT_AMOUNT_PCT));
        return (max,);
    }

    // returning 0 for not supported tokens, as per EIP3156
    return (Uint256(0, 0),);
}

@view
func flashFee{syscall_ptr: felt*}(token: felt, amount: Uint256) -> (fee: Uint256) {
    // as per EIP3156, if a token is not supported, this function must revert
    // and we only support flash minting of Yin
    with_attr error_message("Yin: Unsupported token") {
        let (yin: address) = get_contract_address();
        assert token = yin;
    }

    // feeless minting
    return (Uint256(0, 0),);
}

@external
func flashLoan{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    receiver: address, token: address, amount: Uint256, calldata_len: ufelt, calldata: ufelt*
) -> (success: bool) {
    alloc_locals;

    // prevents looping which would lead to excessive minting
    // we only allow a FLASH_MINT_AMOUNT_PCT percentage of total
    // yin to be minted, as per spec
    ReentrancyGuard._start();

    // reverts if token != yin, as per EIP3156
    let (fee: Uint256) = flashFee(token, amount);

    with_attr error_message("Yin: Flash mint amount exceeds maximum allowed mint amount") {
        let (max: Uint256) = maxFlashLoan(token);
        assert_uint256_le(amount, max);
    }

    let (shrine: address) = yin_shrine_address.read();
    let felt_amount: wad = WadRay.from_uint(amount);
    // updating Yin balance of the receiver by the requested amount
    IShrine.start_flash_mint(shrine, receiver, felt_amount);

    let (initiator: address) = get_caller_address();

    let (borrower_resp: Uint256) = IFlashBorrower.onFlashLoan(
        receiver, initiator, token, amount, fee, calldata_len, calldata
    );

    with_attr error_message("Yin: onFlashLoan callback failed") {
        assert borrower_resp.low = ON_FLASH_MINT_SUCCESS_LOW;
        assert borrower_resp.high = ON_FLASH_MINT_SUCCESS_HIGH;
    }

    // this function in Shrine takes care of the balance validation
    IShrine.end_flash_mint(shrine, receiver, felt_amount);

    FlashMint.emit(initiator, receiver, token, amount);

    ReentrancyGuard._end();

    return (TRUE,);
}
