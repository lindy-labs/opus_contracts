%lang starknet

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

from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.uint256 import Uint256, assert_uint256_le
from starkware.starknet.common.syscalls import get_caller_address

from contracts.shrine.interface import IShrine

from contracts.lib.aliases import address, bool, ufelt, wad
from contracts.lib.interfaces import IERC20, IFlashBorrower
from contracts.lib.openzeppelin.security.reentrancyguard.library import ReentrancyGuard
from contracts.lib.wad_ray import WadRay

// The value of keccak256("ERC3156FlashBorrower.onFlashLoan") as per EIP3156
// it is supposed to be returned from the onFlashLoan function by the receiver
// the raw value is 0x439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd9
// and here it's split into Uint256 parts
const ON_FLASH_MINT_SUCCESS_LOW = 302690805846553493147886643436372200921;
const ON_FLASH_MINT_SUCCESS_HIGH = 89812638168441061617712796123820912833;

// Percentage value of Yin's total supply that can be flash minted
const FLASH_MINT_AMOUNT_PCT = 5 * WadRay.WAD_PERCENT;

@storage_var
func flashmint_shrine() -> (shrine: address) {
}

@event
func FlashMint(initiator: address, receiver: address, token: address, amount: Uint256) {
}

@constructor
func constructor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(shrine: address) {
    flashmint_shrine.write(shrine);

    return ();
}

@view
func maxFlashLoan{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    token: address
) -> (amount: Uint256) {
    let (shrine: address) = flashmint_shrine.read();

    // can only flash mint our own synthetic
    if (token == shrine) {
        let (supply: Uint256) = IERC20.totalSupply(shrine);
        let yin_supply: wad = WadRay.from_uint(supply);
        let max: Uint256 = WadRay.to_uint(WadRay.wmul(yin_supply, FLASH_MINT_AMOUNT_PCT));
        return (max,);
    }

    // returning 0 for not supported tokens, as per EIP3156
    return (Uint256(0, 0),);
}

@view
func flashFee{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    token: felt, amount: Uint256
) -> (fee: Uint256) {
    // as per EIP3156, if a token is not supported, this function must revert
    // and we only support flash minting of own synthetic
    with_attr error_message("Flashmint: Unsupported token") {
        let (shrine: address) = flashmint_shrine.read();
        assert token = shrine;
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

    with_attr error_message("Flashmint: Amount exceeds maximum allowed mint limit") {
        let (max: Uint256) = maxFlashLoan(token);
        assert_uint256_le(amount, max);
    }

    let (shrine: address) = flashmint_shrine.read();
    let felt_amount: wad = WadRay.from_uint(amount);
    IShrine.forge_without_trove(shrine, receiver, felt_amount);

    let (initiator: address) = get_caller_address();

    let (borrower_resp: Uint256) = IFlashBorrower.onFlashLoan(
        receiver, initiator, token, amount, fee, calldata_len, calldata
    );

    with_attr error_message("Flashmint: onFlashLoan callback failed") {
        assert borrower_resp.low = ON_FLASH_MINT_SUCCESS_LOW;
        assert borrower_resp.high = ON_FLASH_MINT_SUCCESS_HIGH;
    }

    // this function in Shrine takes care of balance validation
    IShrine.melt_without_trove(shrine, receiver, felt_amount);

    FlashMint.emit(initiator, receiver, token, amount);

    ReentrancyGuard._end();

    return (TRUE,);
}
