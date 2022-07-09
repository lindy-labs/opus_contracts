from starkware.cairo.common.math import split_felt, assert_in_range, unsigned_div_rem
from starkware.cairo.common.uint256 import Uint256

const A_UPPER_BOUND = 2 ** 128
const B_UPPER_BOUND = 2 ** 123

const PACKED_125_UPPER_BOUND = 2**125

func felt_to_uint{range_check_ptr}(value : felt) -> (value : Uint256):
    let (high : felt, low : felt) = split_felt(value)
    return (Uint256(low=low, high=high))
end

func uint_to_felt_unchecked(value : Uint256) -> (value : felt):
    return (value.low + value.high * 2 ** 128)
end

# Packs `a` into the first 128 bits, packs `b` into the last 123 bits
# Requires that 0 <= a < 2**128 and 0 <= b < 2**123
func pack_felt{range_check_ptr}(a : felt, b : felt) -> (packed : felt):
    [range_check_ptr] = a
    let range_check_ptr = range_check_ptr + 1
    assert_in_range(b, 0, B_UPPER_BOUND)

    let packed = a + (b * A_UPPER_BOUND)
    return (packed)
end

# Packs `a` into the first 125 bits, and packs `b` into the next 125 bits 
# Requires that 0 <= a < 2**125 and 0 <= b < 2**125 
func pack_125{range_check_ptr}(high, low) -> (packed):
    assert_in_range(high, 0, PACKED_125_UPPER_BOUND)
    assert_in_range(low, 0, PACKED_125_UPPER_BOUND)
    let packed = low + (high * PACKED_125_UPPER_BOUND)
    return (packed)
end

# Unpacks a felt into the first- and next-125 bits. 
func unpack_125{range_check_ptr}(packed) -> (high, low):
    let (high, low) = unsigned_div_rem(packed, PACKED_125_UPPER_BOUND)
    return (high, low)
end
