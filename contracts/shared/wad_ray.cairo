from starkware.cairo.common.math import assert_le, sign, abs_value, signed_div_rem, unsigned_div_rem

from starkware.cairo.common.uint256 import Uint256

# Adapted from Influence's 64x61 fixed-point math library (https://github.com/influenceth/cairo-math-64x61/blob/master/contracts/Math64x61.cairo).

# Wad: signed felt scaled by 10**18 (meaning 10**18 = 1)
namespace WadRay:
    const BOUND = 2 ** 125
    const WAD_SCALE = 10 ** 18
    const RAY_SCALE = 10 ** 27
    const DIFF = 10 ** 9
    const RAY_ONE = RAY_SCALE
    const WAD_ONE = WAD_SCALE

    # Reverts if `n` overflows or underflows
    func assert_valid{range_check_ptr}(n):
        assert_le(n, BOUND)
        assert_le(-BOUND, n)
        return ()
    end

    func assert_valid_unsigned{range_check_ptr}(n):
        assert_le(n, BOUND)
        assert_le(0, n)
        return ()
    end

    func floor{range_check_ptr}(n) -> (wad):
        let (int_val, mod_val) = signed_div_rem(n, WAD_ONE, BOUND)
        let floored = n - mod_val
        assert_valid(floored)
        return (wad=floored)
    end

    func ceil{range_check_ptr}(n) -> (wad):
        let (int_val, mod_val) = signed_div_rem(n, WAD_ONE, BOUND)
        let ceiled = (int_val + 1) * WAD_ONE
        assert_valid(ceiled)
        return (wad=ceiled)
    end

    func add{range_check_ptr}(a, b) -> (wad):
        let sum = a + b
        assert_valid(sum)
        return (wad=sum)
    end

    func add_unsigned{range_check_ptr}(a, b) -> (wad):
        let sum = a + b
        assert_valid_unsigned(sum)
        return (wad=sum)
    end

    func sub{range_check_ptr}(a, b) -> (wad):
        let diff = a - b
        assert_valid(diff)
        return (wad=diff)
    end

    func sub_unsigned{range_check_ptr}(a, b) -> (wad):
        let diff = a - b
        assert_valid_unsigned(diff)
        return (wad=diff)
    end

    func wmul{range_check_ptr}(a, b) -> (wad):
        tempvar prod = a * b
        let (scaled_prod, _) = signed_div_rem(prod, WAD_SCALE, BOUND)
        assert_valid(scaled_prod)
        return (wad=scaled_prod)
    end

    func wmul_unchecked{range_check_ptr}(a, b) -> (wad):
        tempvar prod = a * b
        let (scaled_prod, _) = signed_div_rem(prod, WAD_SCALE, BOUND)
        return (wad=scaled_prod)
    end

    func wsigned_div{range_check_ptr}(a, b) -> (wad):
        alloc_locals
        let (div) = abs_value(b)
        let (div_sign) = sign(b)
        tempvar prod = a * WAD_SCALE
        let (wad_u, _) = signed_div_rem(prod, div, BOUND)
        assert_valid_unsigned(wad_u)
        return (wad=wad_u * div_sign)
    end

    # No overflow check - use only if the quotient of a and b is guaranteed not to overflow
    func wsigned_div_unchecked{range_check_ptr}(a, b) -> (wad):
        alloc_locals
        let (div) = abs_value(b)
        let (div_sign) = sign(b)
        tempvar prod = a * WAD_SCALE
        let (wad_u, _) = signed_div_rem(prod, div, BOUND)
        return (wad=wad_u * div_sign)
    end

    # Assumes both a and b are positive integers
    func wunsigned_div{range_check_ptr}(a, b) -> (wad):
        tempvar product = a * WAD_SCALE
        let (q, _) = unsigned_div_rem(product, b)
        assert_valid(q)
        return (wad=q)
    end

    # Assumes both a and b are unsigned
    # No overflow check - use only if the quotient of a and b is guaranteed not to overflow
    func wunsigned_div_unchecked{range_check_ptr}(a, b) -> (wad):
        tempvar product = a * WAD_SCALE
        let (q, _) = signed_div_rem(product, b, BOUND)
        return (wad=q)
    end

    # Operations with rays
    func rmul{range_check_ptr}(a, b) -> (ray):
        tempvar prod = a * b
        let (scaled_prod, _) = signed_div_rem(prod, RAY_SCALE, BOUND)
        assert_valid(scaled_prod)
        return (ray=scaled_prod)
    end

    func rmul_unchecked{range_check_ptr}(a, b) -> (ray):
        tempvar prod = a * b
        let (scaled_prod, _) = signed_div_rem(prod, RAY_SCALE, BOUND)
        return (ray=scaled_prod)
    end

    func rsigned_div{range_check_ptr}(a, b) -> (ray):
        alloc_locals
        let (div) = abs_value(b)
        let (div_sign) = sign(b)
        tempvar prod = a * RAY_SCALE
        let (ray_u, _) = signed_div_rem(prod, div, BOUND)
        assert_valid_unsigned(ray_u)
        return (ray=ray_u * div_sign)
    end

    # No overflow check - use only if the quotient of a and b is guaranteed not to overflow
    func rsigned_div_unchecked{range_check_ptr}(a, b) -> (ray):
        alloc_locals
        let (div) = abs_value(b)
        let (div_sign) = sign(b)
        tempvar prod = a * RAY_SCALE
        let (ray_u, _) = signed_div_rem(prod, div, BOUND)
        return (ray=ray_u * div_sign)
    end

    # Assumes both a and b are positive integers
    func runsigned_div{range_check_ptr}(a, b) -> (ray):
        tempvar product = a * RAY_SCALE
        let (q, _) = signed_div_rem(product, b, BOUND)
        assert_valid(q)
        return (ray=q)
    end

    # Assumes both a and b are unsigned
    # No overflow check - use only if the quotient of a and b is guaranteed not to overflow
    func runsigned_div_unchecked{range_check_ptr}(a, b) -> (ray):
        tempvar product = a * RAY_SCALE
        let (q, _) = signed_div_rem(product, b, BOUND)
        return (ray=q)
    end
    #
    # Conversions
    #

    func to_uint(n) -> (uint : Uint256):
        let uint = Uint256(low=n, high=0)
        return (uint)
    end

    func from_uint{range_check_ptr}(n : Uint256) -> (wad):
        assert n.high = 0
        assert_valid(n.low)

        return (wad=n.low)
    end

    func to_wad{range_check_ptr}(n) -> (wad):
        let n_wad = n * WAD_SCALE
        assert_valid(n_wad)
        return (wad=n_wad)
    end

    # Truncates fractional component
    func to_felt{range_check_ptr}(n) -> (wad):
        let (wad, _) = signed_div_rem(n, WAD_SCALE, BOUND)  # 2**127 is the maximum possible value of the bound parameter.
        return (wad)
    end

    func wad_to_ray{range_check_ptr}(n) -> (ray):
        let ray = n * DIFF
        assert_valid(ray)
        return (ray)
    end

    func wad_to_ray_unchecked(n) -> (ray):
        return (ray=n * DIFF)
    end
end
