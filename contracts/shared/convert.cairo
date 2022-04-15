from starkware.cairo.common.math import split_felt
from starkware.cairo.common.uint256 import Uint256

func felt_to_uint{range_check_ptr}(value : felt) -> (value : Uint256):
    let (high : felt, low : felt) = split_felt(value)
    return (Uint256(low=low, high=high))
end

func uint_to_felt_unchecked{range_check_ptr}(value : Uint256) -> (value : felt):
    return (value.low + value.high * 2**128)
end
