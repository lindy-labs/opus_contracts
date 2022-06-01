from starkware.cairo.common.math import (
    assert_le,
    sign,
    abs_value,
    signed_div_rem,
    unsigned_div_rem
)

from starkware.cairo.common.uint256 import Uint256

# Adapted from Influence's 64x61 fixed-point math library (https://github.com/influenceth/cairo-math-64x61/blob/master/contracts/Math64x61.cairo).

# Wad: signed felt scaled by 10**18 (meaning 10**18 = 1)
namespace Wad:
    const BOUND = 2**125
    const SCALE = 10**18
    const ONE = SCALE

    struct Wad:
        member val : felt
    end

    func assert_in_bounds(n : Wad):
        assert_le(n.val, BOUND)
        assert_le(-BOUND, n.val)
    end

    func assert_in_bounds(n : Fis):
        assert_le(n.val, BOUND)
        assert_le(-BOUND, n.val)
    end

    func floor {range_check_ptr} (n : Wad) -> (res : Wad):
        let (int_val, mod_val) = signed_div_rem(n.val, WAD_ONE, BOUND)
        let floored = n.val - mod_val
        assert_in_bounds(floored)
        return ( res = Wad(floored) )
    end

    func ceil {range_check_ptr} (n : Wad) -> (res : Wad):
        let (int_val, mod_val) = signed_div_rem(x, WAD_ONE, BOUND)
        let ceiled = (int_val + 1) * WAD_ONE
        assert_in_bounds(ceiled)
        return ( res = Wad(ceiled) )
    end

    func add {range_check_ptr} (a : Wad, b : Wad) -> (res : Wad):
        let sum = a.val + b.val
        assert_in_bounds(sum)
        return ( res = Wad(sum) )
    end

    func sub {range_check_ptr} (a : Wad, b : Wad) -> (res : Wad):
        let diff = a.val - b.val
        assert_in_bounds(diff)
        return ( res = Wad(diff) )
    end

    func mul {range_check_ptr} (a : Wad, b : Wad) -> (res : Wad):
        tempvar prod = a.val * b.val
        let (scaled_prod, _) = signed_div_rem(prod, SCALE, BOUND)
        assert_in_bounds(scaled_prod)
        return ( res = Wad(scaled_prod)
    end

    func mul_unchecked {range_check_ptr} (a : Wad, b : Wad) -> (res : Wad):
        tempvar prod = a.val * b.val
        let (scaled_prod, _) = signed_div_rem(prod, SCALE, BOUND)
        return ( res = Wad(scaled_prod)
    end

    func signed_div {range_check_ptr} (a : Wad, b : Wad) -> (res : Wad):
        alloc_locals
        let (div) = abs_value(b.val)
        let (div_sign) = sign(b.val)
        tempvar prod = a.val * SCALE
        let (res_u, _) = signed_div_rem(prod, div, BOUND)
        assert_in_bounds(res_u)
        return (res = Wad(res_u * div_sign))
    end

    # No overflow check - use only if the quotient of a and b is guaranteed not to overflow
    func signed_div_unchecked {range_check_ptr} (a : Wad, b : Wad) -> (res : Wad):
        alloc_locals
        let (div) = abs_value(b.val)
        let (div_sign) = sign(b.val)
        tempvar prod = a.val * SCALE
        let (res_u, _) = signed_div_rem(prod, div, BOUND)
        return (res = Wad(res_u * div_sign))
    end


    # Assumes both a and b are positive integers
    func unsigned_div {range_check_ptr} (a : Wad, b : Wad) -> (res : Wad):
        tempvar product = a.val * SCALE
        let (q, _) = signed_div_rem(product, b.val, BOUND)
        assert_in_bounds(q)
        return (res = Fis(q) )
    end

    # Assumes both a and b are unsigned
    # No overflow check - use only if the quotient of a and b is guaranteed not to overflow
    func unsigned_div_unchecked {range_check_ptr} (a : Wad, b : Wad) -> (res : Wad):
        tempvar product = a.val * SCALE
        let (q, _) = signed_div_rem(product, b.val, BOUND)
        return (res = Fis(q) )
    end



    #
    # Conversions
    # 

    func wad_to_uint (n: Wad) -> (res: Uint256):
        let res = Uint256(low = n.val, high = 0)
        return (res)
    end

    func uint_to_wad {range_check_ptr} (n: Uint256) -> (res: Wad):
        assert n.high = 0
        assert_in_bounds(n.low)

        return ( res = Wad(n.low))
    end

    func from_felt(n : felt) -> (res : Wad):
        let n_wad = n * SCALE
        assert_in_bounds(n_wad)
        return ( res = Wad(n_wad) )
    end 

    # Truncates fractional component
    func to_felt(n : Wad) -> (res : felt):
        let (res, _) = signed_div_rem(n.val, SCALE, BOUND) # 2**127 is the maximum possible value of the bound parameter.
        return (res)
    end 

end
