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
namespace WadRay:
    const BOUND = 2**125
    const WAD_SCALE = 10**18
    const WAD_ONE = WAD_SCALE

    struct Wad:
        member val : felt
    end

    func assert_wad(n : Wad):
        assert_le(n.val, BOUND)
        assert_le(-BOUND, n.val)
    end

    func assert_wad_unsigned(n : Wad):
        assert_le(n.val, BOUND)
        assert_le(0, n.val)
    end

    func floor {range_check_ptr} (n : Wad) -> (res : Wad):
        let (int_val, mod_val) = signed_div_rem(n.val, WAD_ONE, BOUND)
        let floored = n.val - mod_val
        assert_wad(floored)
        return ( res = Wad(floored) )
    end

    func ceil {range_check_ptr} (n : Wad) -> (res : Wad):
        let (int_val, mod_val) = signed_div_rem(x, WAD_ONE, BOUND)
        let ceiled = (int_val + 1) * WAD_ONE
        assert_wad(ceiled)
        return ( res = Wad(ceiled) )
    end

    func add {range_check_ptr} (a : Wad, b : Wad) -> (res : Wad):
        let sum = a.val + b.val
        assert_wad(sum)
        return ( res = Wad(sum) )
    end

    func add_unsigned {range_check_ptr} (a : Wad, b : Wad) -> (res : Wad):
        let sum = a.val + b.val
        assert_wad_unsigned(sum)
        return ( res = Wad(sum) )
    end

    func sub {range_check_ptr} (a : Wad, b : Wad) -> (res : Wad):
        let diff = a.val - b.val
        assert_wad(diff)
        return ( res = Wad(diff) )
    end

    func sub_unsigned {range_check_ptr} (a : Wad, b : Wad) -> (res : Wad):
        let diff = a.val - b.val
        assert_wad_unsigned(diff)
        return ( res = Wad(diff) )
    end

    func wmul {range_check_ptr} (a : Wad, b : Wad) -> (res : Wad):
        tempvar prod = a.val * b.val
        let (scaled_prod, _) = signed_div_rem(prod, SCALE, BOUND)
        assert_wad(scaled_prod)
        return ( res = Wad(scaled_prod)
    end

    func wmul_unchecked {range_check_ptr} (a : Wad, b : Wad) -> (res : Wad):
        tempvar prod = a.val * b.val
        let (scaled_prod, _) = signed_div_rem(prod, SCALE, BOUND)
        return ( res = Wad(scaled_prod)
    end

    func wsigned_div {range_check_ptr} (a : Wad, b : Wad) -> (res : Wad):
        alloc_locals
        let (div) = abs_value(b.val)
        let (div_sign) = sign(b.val)
        tempvar prod = a.val * SCALE
        let (res_u, _) = signed_div_rem(prod, div, BOUND)
        assert_wad_unsigned(res_u)
        return (res = Wad(res_u * div_sign))
    end

    # No overflow check - use only if the quotient of a and b is guaranteed not to overflow
    func wsigned_div_unchecked {range_check_ptr} (a : Wad, b : Wad) -> (res : Wad):
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
        assert_wad(q)
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
        assert_wad(n.low)

        return ( res = Wad(n.low))
    end

    func from_felt(n : felt) -> (res : Wad):
        let n_wad = n * SCALE
        assert_wad(n_wad)
        return ( res = Wad(n_wad) )
    end 

    # Truncates fractional component
    func to_felt(n : Wad) -> (res : felt):
        let (res, _) = signed_div_rem(n.val, SCALE, BOUND) # 2**127 is the maximum possible value of the bound parameter.
        return (res)
    end 

end
