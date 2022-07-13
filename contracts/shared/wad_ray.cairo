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

        with_attr error_message("WadRay: Result is out of bounds"):
            assert_valid(floored)
        end

        return (wad=floored)
    end

    func ceil{range_check_ptr}(n) -> (wad):
        let (int_val, mod_val) = signed_div_rem(n, WAD_ONE, BOUND)

        if mod_val == 0:
            tempvar ceiled = n
            tempvar range_check_ptr = range_check_ptr
        else:
            tempvar ceiled = (int_val + 1) * WAD_ONE
            tempvar range_check_ptr = range_check_ptr
        end

        with_attr error_message("WadRay: Result is out of bounds"):
            assert_valid(ceiled)
        end

        return (wad=ceiled)
    end

    func add{range_check_ptr}(a, b) -> (wad):
        let sum = a + b

        with_attr error_message("WadRay: Result is out of bounds"):
            assert_valid(sum)
        end

        return (wad=sum)
    end

    func add_unsigned{range_check_ptr}(a, b) -> (wad):
        let sum = a + b

        with_attr error_message("WadRay: Result is out of bounds"):
            assert_valid_unsigned(sum)
        end

        return (wad=sum)
    end

    func sub{range_check_ptr}(a, b) -> (wad):
        let diff = a - b

        with_attr error_message("WadRay: Result is out of bounds"):
            assert_valid(diff)
        end

        return (wad=diff)
    end

    func sub_unsigned{range_check_ptr}(a, b) -> (wad):
        let diff = a - b

        with_attr error_message("WadRay: Result is out of bounds"):
            assert_valid_unsigned(diff)
        end

        return (wad=diff)
    end

    func wmul{range_check_ptr}(a, b) -> (wad):
        tempvar prod = a * b
        # `signed_div_rem` asserts -BOUND <= `scaled_prod` < BOUND
        let (scaled_prod, _) = signed_div_rem(prod, WAD_SCALE, BOUND)
        return (wad=scaled_prod)
    end

    func wsigned_div{range_check_ptr}(a, b) -> (wad):
        alloc_locals
        # `signed_div_rem` assumes 0 < div <= PRIME / rc_bound
        let (div) = abs_value(b)
        # `sign` assumes -rc_bound < value < rc_bound
        let (div_sign) = sign(b)
        tempvar prod = a * WAD_SCALE
        # `signed_div_rem` asserts -BOUND <= `wad_u` < BOUND
        let (wad_u, _) = signed_div_rem(prod, div, BOUND)
        return (wad=wad_u * div_sign)
    end

    # Assumes both a and b are positive integers
    func wunsigned_div{range_check_ptr}(a, b) -> (wad):
        tempvar product = a * WAD_SCALE
        let (q, _) = unsigned_div_rem(product, b)

        with_attr error_message("WadRay: Result is out of bounds"):
            assert_valid(q)
        end

        return (wad=q)
    end

    # Assumes both a and b are unsigned
    # No overflow check - use only if the quotient of a and b is guaranteed not to overflow
    func wunsigned_div_unchecked{range_check_ptr}(a, b) -> (wad):
        tempvar product = a * WAD_SCALE
        let (q, _) = unsigned_div_rem(product, b)
        return (wad=q)
    end

    # Operations with rays
    func rmul{range_check_ptr}(a, b) -> (ray):
        tempvar prod = a * b
        # `signed_div_rem` asserts -BOUND <= `scaled_prod` < BOUND
        let (scaled_prod, _) = signed_div_rem(prod, RAY_SCALE, BOUND)
        return (ray=scaled_prod)
    end

    func rsigned_div{range_check_ptr}(a, b) -> (ray):
        alloc_locals
        let (div) = abs_value(b)
        let (div_sign) = sign(b)
        tempvar prod = a * RAY_SCALE
        # `signed_div_rem` asserts -BOUND <= `ray_u` < BOUND
        let (ray_u, _) = signed_div_rem(prod, div, BOUND)
        return (ray=ray_u * div_sign)
    end

    # Assumes both a and b are positive integers
    func runsigned_div{range_check_ptr}(a, b) -> (ray):
        tempvar product = a * RAY_SCALE
        let (q, _) = unsigned_div_rem(product, b)

        with_attr error_message("WadRay: Result is out of bounds"):
            assert_valid(q)
        end

        return (ray=q)
    end

    # Assumes both a and b are unsigned
    # No overflow check - use only if the quotient of a and b is guaranteed not to overflow
    func runsigned_div_unchecked{range_check_ptr}(a, b) -> (ray):
        tempvar product = a * RAY_SCALE
        let (q, _) = unsigned_div_rem(product, b)
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

        with_attr error_message("WadRay: Uint256.low is out of bounds"):
            assert_valid(n.low)
        end

        return (wad=n.low)
    end

    func to_wad{range_check_ptr}(n) -> (wad):
        let n_wad = n * WAD_SCALE

        with_attr error_message("WadRay: Result is out of bounds"):
            assert_valid(n_wad)
        end

        return (wad=n_wad)
    end

    # Truncates fractional component
    func to_felt{range_check_ptr}(n) -> (wad):
        let (wad, _) = signed_div_rem(n, WAD_SCALE, BOUND)  # 2**127 is the maximum possible value of the bound parameter.
        return (wad)
    end

    func wad_to_ray{range_check_ptr}(n) -> (ray):
        let ray = n * DIFF

        with_attr error_message("WadRay: Result is out of bounds"):
            assert_valid(ray)
        end

        return (ray)
    end

    func wad_to_ray_unchecked(n) -> (ray):
        return (ray=n * DIFF)
    end
end
