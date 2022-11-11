%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_le
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_contract_address

from contracts.yin.interface import IYin

from contracts.lib.aliases import address, bool, ufelt
from contracts.lib.interfaces import IFlashLender

//
// storage variables for holding `onFlashLoan` values
// so we can check them in the test suite
//

@storage_var
func got_initiator() -> (initiator: address) {
}

@storage_var
func got_token() -> (token: address) {
}

@storage_var
func got_amount() -> (amount: Uint256) {
}

@storage_var
func got_fee() -> (fee: Uint256) {
}

@storage_var
func got_calldata_len() -> (calldata_len: ufelt) {
}

@storage_var
func got_calldata(index: ufelt) -> (value: ufelt) {
}

@external
func onFlashLoan{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    initiator: address,
    token: address,
    amount: Uint256,
    fee: Uint256,
    calldata_len: ufelt,
    calldata: ufelt*,
) -> (hash: Uint256) {
    alloc_locals;

    with_attr error_message("Flash mint amount not transferred to receiver") {
        let (self: address) = get_contract_address();
        let (balance: ufelt) = IYin.balanceOf(token, self);
        assert_le(amount.low, balance);
    }

    assert calldata_len = 3;
    let should_return_correct: bool = calldata[0];
    let attempt_to_steal: bool = calldata[1];
    let attempt_to_reenter: bool = calldata[2];

    if (attempt_to_steal == TRUE) {
        IYin.transfer(token, 0xbeef, amount.low);
        tempvar syscall_ptr = syscall_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar range_check_ptr = range_check_ptr;
    } else {
        if (attempt_to_reenter == TRUE) {
            IFlashLender.flashLoan(token, initiator, token, amount, calldata_len, calldata);
            tempvar syscall_ptr = syscall_ptr;
            tempvar pedersen_ptr = pedersen_ptr;
            tempvar range_check_ptr = range_check_ptr;
        } else {
            tempvar syscall_ptr = syscall_ptr;
            tempvar pedersen_ptr = pedersen_ptr;
            tempvar range_check_ptr = range_check_ptr;
        }
    }

    got_initiator.write(initiator);
    got_token.write(token);
    got_amount.write(amount);
    got_fee.write(fee);
    write_calldata(0, calldata_len, calldata);

    let (hash: Uint256) = get_callback_return_value(should_return_correct);
    return (hash,);
}

@view
func get_callback_values{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    initiator: address,
    token: address,
    amount: Uint256,
    fee: Uint256,
    calldata_len: ufelt,
    calldata: ufelt*,
) {
    alloc_locals;

    let (initiator) = got_initiator.read();
    let (token) = got_token.read();
    let (amount) = got_amount.read();
    let (fee) = got_fee.read();
    let (calldata_len) = got_calldata_len.read();
    let (calldata) = alloc();
    read_calldata(0, calldata_len, calldata);

    return (initiator, token, amount, fee, calldata_len, calldata);
}

func read_calldata{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    index: ufelt, calldata_len: ufelt, calldata: ufelt*
) {
    if (index == calldata_len) {
        return ();
    }
    let (value) = got_calldata.read(index);
    assert [calldata] = value;
    return read_calldata(index + 1, calldata_len, calldata + 1);
}

func write_calldata{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    index: ufelt, calldata_len: ufelt, calldata: ufelt*
) {
    if (index == calldata_len) {
        got_calldata_len.write(calldata_len);
        return ();
    }
    got_calldata.write(index, [calldata]);
    return write_calldata(index + 1, calldata_len, calldata + 1);
}

func get_callback_return_value{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    return_correct: bool
) -> (value: Uint256) {
    if (return_correct == TRUE) {
        // value of keccak256("ERC3156FlashBorrower.onFlashLoan")
        return (
            Uint256(low=302690805846553493147886643436372200921,
            high=89812638168441061617712796123820912833),
        );
    }

    return (Uint256(1, 1),);
}
