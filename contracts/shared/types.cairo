%lang starknet

from starkware.cairo.common.math import assert_in_range

const A_UPPER_BOUND = 2**128
const B_UPPER_BOUND = 2**123

struct Trove:
    member last : felt  # Time ID (timestamp // TIME_ID_INTERVAL) of last accumulated interest calculation
    member debt : felt  # Normalized debt
end

struct Gage:
    member total : felt  # Total amount of the Gage currently deposited
    member max : felt  # Maximum amount of the Gage that can be deposited
end

# Packs a into the first 128 bits, packs b into the last 123 bits
# Requires that 0 <= a < 2**128 and 0 <= b < 2**123
func pack_felt{range_check_ptr}(a : felt, b : felt) -> (packed : felt):
    [range_check_ptr] = a 
    let range_check_ptr = range_check_ptr + 1
    assert_in_range(b, 0, B_UPPER_BOUND)

    let packed = a + (b * A_UPPER_BOUND)
    return (packed)
end

