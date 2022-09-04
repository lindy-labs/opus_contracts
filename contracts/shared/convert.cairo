from starkware.cairo.common.math import split_felt, split_int, assert_in_range
from starkware.cairo.common.uint256 import Uint256
from starkware.cairo.common.alloc import alloc

const LOW_UPPER_BOUND = 2 ** 128;
const HIGH_UPPER_BOUND = 2 ** 123;

const PACKED_125_UPPER_BOUND = 2 ** 125;

func felt_to_uint{range_check_ptr}(value: felt) -> (value: Uint256) {
    let (high: felt, low: felt) = split_felt(value);
    return (Uint256(low=low, high=high),);
}

func uint_to_felt_unchecked(value: Uint256) -> (value: felt) {
    return (value.low + value.high * 2 ** 128,);
}

// Packs `low` into the first 128 bits, packs `high` into the last 123 bits
// Requires that 0 <= low < 2**128 and 0 <= high < 2**123
func pack_felt{range_check_ptr}(high, low) -> (packed: felt) {
    [range_check_ptr] = low;
    let range_check_ptr = range_check_ptr + 1;
    assert_in_range(high, 0, HIGH_UPPER_BOUND);

    let packed = low + (high * LOW_UPPER_BOUND);
    return (packed,);
}

func pack_125{range_check_ptr}(high, low) -> (packed: felt) {
    assert_in_range(high, 0, PACKED_125_UPPER_BOUND);
    assert_in_range(low, 0, PACKED_125_UPPER_BOUND);

    let packed = low + high * PACKED_125_UPPER_BOUND;
    return (packed,);
}

func unpack_125{range_check_ptr}(packed) -> (high: felt, low: felt) {
    alloc_locals;
    let (unpacked: felt*) = alloc();
    split_int(packed, 2, 2 ** 125, 2 ** 125, unpacked);

    return (high=unpacked[1], low=unpacked[0]);
}
