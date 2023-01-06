from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.math import (
    abs_value,
    assert_le,
    assert_nn_le,
    sign,
    signed_div_rem,
    unsigned_div_rem,
)
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.uint256 import Uint256

from contracts.lib.aliases import ray, ufelt, wad
from contracts.lib.pow import pow10

// Adapted from Influence's 64x61 fixed-point math library (https://github.com/influenceth/cairo-math-64x61/blob/master/contracts/Math64x61.cairo).

// Wad: signed felt scaled by 10**18 (meaning 10**18 = 1)
namespace WadRay {
    const WAD_DECIMALS = 18;
    const RAY_DECIMALS = 27;
    const BOUND = 2 ** 125;
    const WAD_SCALE = 10 ** 18;
    const RAY_SCALE = 10 ** 27;
    const WAD_PERCENT = 10 ** 16;
    const RAY_PERCENT = 10 ** 25;
    const DIFF = 10 ** 9;
    const RAY_ONE = RAY_SCALE;
    const WAD_ONE = WAD_SCALE;

    // @notice Check if number is a signed value between -BOUND and BOUND, both inclusive.
    // @dev Reverts if `n` overflows BOUND or underflows -BOUND.
    // @param n A value to assert.
    func assert_valid{range_check_ptr}(n) {
        with_attr error_message("WadRay: Out of bounds") {
            assert_le(n, BOUND);
            assert_le(-BOUND, n);
        }
        return ();
    }

    // @notice Check if number is an unsigned value between 0 and BOUND, both inclusive.
    //         Reverts if `n` overflows BOUND or underflows 0.
    // @param n A value to assert.
    func assert_valid_unsigned{range_check_ptr}(n) {
        with_attr error_message("WadRay: Out of bounds") {
            assert_nn_le(n, BOUND);
        }
        return ();
    }

    // @notice Returns the smaller numerical value of two unsigned values.
    // @dev Reverts if either arguments is not a value between 0 and BOUND, both inclusive.
    // @param a An unsigned value between 0 and BOUND, both inclusive.
    // @param b An unsigned value between 0 and BOUND, both inclusive.
    // @return `a` if it's less than or equal to `b`, otherwise `b`.
    //         An unsigned value between 0 and BOUND, both inclusive.
    func unsigned_min{range_check_ptr}(a, b) -> ufelt {
        assert_valid_unsigned(a);
        assert_valid_unsigned(b);

        let le = is_le(a, b);
        if (le == TRUE) {
            return a;
        }
        return b;
    }

    // @notice Returns the greater numerical value of two unsigned values.
    // @dev Reverts if either arguments is not a value between -BOUND and BOUND, both inclusive.
    // @param a An unsigned value between -BOUND and BOUND, both inclusive.
    // @param b An unsigned value between -BOUND and BOUND, both inclusive.
    // @return `b` if it's greater than `a`, otherwise `a`.
    //         An unsigned value between 0 and BOUND, both inclusive.
    func unsigned_max{range_check_ptr}(a, b) -> ufelt {
        assert_valid_unsigned(a);
        assert_valid_unsigned(b);

        let le = is_le(a, b);
        if (le == TRUE) {
            return b;
        }
        return a;
    }

    // @notice Round down the argument to its nearest Wad value.
    //         Round down away from zero for negative numbers.
    // @dev Reverts if resulting value is not a value between -BOUND and BOUND, both inclusive.
    // @param n A numeric value.
    // @return Rounded Wad value between -BOUND and BOUND, both inclusive.
    func floor{range_check_ptr}(n) -> wad {
        let (int_val, mod_val) = signed_div_rem(n, WAD_ONE, BOUND);
        let floored = n - mod_val;
        assert_valid(floored);
        return floored;
    }

    // @notice Round up the argument towards its nearest Wad value.
    //         Round up to zero for negative numbers.
    // @dev Reverts if resulting value is not a value between -BOUND and BOUND, both inclusive.
    // @param A numeric value.
    // @return Rounded Wad value between -BOUND and BOUND, both inclusive.
    func ceil{range_check_ptr}(n) -> wad {
        let (int_val, mod_val) = signed_div_rem(n, WAD_ONE, BOUND);

        if (mod_val == 0) {
            tempvar ceiled = n;
            tempvar range_check_ptr = range_check_ptr;
        } else {
            tempvar ceiled = (int_val + 1) * WAD_ONE;
            tempvar range_check_ptr = range_check_ptr;
        }
        assert_valid(ceiled);
        return ceiled;
    }

    // @notice Add two numbers with underflow and overflow checks.
    // @dev Reverts if either arguments or the resulting value
    //      is not a value between -BOUND and BOUND, both inclusive.
    // @param a A signed value between -BOUND and BOUND, both inclusive.
    // @param b A signed value between -BOUND and BOUND, both inclusive.
    // @return The sum of `a` and `b`.
    //         A signed value between -BOUND and BOUND, both inclusive.
    func add{range_check_ptr}(a, b) -> felt {
        assert_valid(a);
        assert_valid(b);

        let sum = a + b;
        assert_valid(sum);
        return sum;
    }

    // @notice Add two unsigned numbers with overflow checks.
    // @dev Reverts if either arguments or the resulting value
    //      is not a value between 0 and BOUND, both inclusive.
    // @param a An unsigned value between 0 and BOUND, both inclusive.
    // @param b An unsigned value between 0 and BOUND, both inclusive.
    // @return The sum of `a` and `b`.
    //         An unsigned value between 0 and BOUND, both inclusive.
    func unsigned_add{range_check_ptr}(a, b) -> ufelt {
        assert_valid_unsigned(a);
        assert_valid_unsigned(b);

        let sum = a + b;
        assert_valid_unsigned(sum);
        return sum;
    }

    // @notice Subtract two numbers with underflow and overflow checks.
    // @dev Reverts if either arguments or the resulting value
    //      is not a value between -BOUND and BOUND, both inclusive.
    // @param a A signed value between -BOUND and BOUND, both inclusive.
    // @param b A signed value between -BOUND and BOUND, both inclusive.
    // @return The difference of `a` and `b`.
    //         A signed value between -BOUND and BOUND, both inclusive.
    func sub{range_check_ptr}(a, b) -> felt {
        assert_valid(a);
        assert_valid(b);

        let diff = a - b;
        assert_valid(diff);
        return diff;
    }

    // @notice Subtract two unsigned numbers with underflow and overflow checks.
    // @dev Reverts if either argument or the resulting value
    //      is not a value between 0 and BOUND, both inclusive.
    // @param a An unsigned value between 0 and BOUND, both inclusive.
    // @param b An unsigned value between 0 and BOUND, both inclusive.
    // @return The difference of `a` and `b`.
    //         An unsigned value between 0 and BOUND, both inclusive.
    func unsigned_sub{range_check_ptr}(a, b) -> ufelt {
        assert_valid_unsigned(a);
        assert_valid_unsigned(b);

        let diff = a - b;
        assert_valid_unsigned(diff);
        return diff;
    }

    // @notice Multiply two signed Wads with underflow and overflow checks.
    // @dev Reverts if either arguments or the resulting value
    //      is not a value between -BOUND and BOUND, both inclusive.
    // @param a A signed Wad value between -BOUND and BOUND, both inclusive.
    // @param b A signed Wad value between -BOUND and BOUND, both inclusive.
    // @return The product of `a` and `b`.
    //         A signed Wad value between -BOUND and BOUND, both inclusive.
    func wmul{range_check_ptr}(a: wad, b: wad) -> wad {
        assert_valid(a);
        assert_valid(b);

        tempvar prod = a * b;
        // `signed_div_rem` asserts -BOUND <= `scaled_prod` < BOUND
        let (scaled_prod, _) = signed_div_rem(prod, WAD_SCALE, BOUND);
        return scaled_prod;
    }

    // @notice Integer division of signed Wad values with underflow and overflow checks.
    // @dev Fractional values are rounded down to smallest integer.
    //      Reverts if either arguments or the resulting value
    //      is not a value between -BOUND and BOUND, both inclusive.
    // @param a A signed Wad value between -BOUND and BOUND, both inclusive.
    // @param b A signed Wad value between -BOUND and BOUND, both inclusive.
    // @return The quotient of the division of `a` by `b` (`a // b`).
    //         A signed Wad value between -BOUND and BOUND, both inclusive.
    func wsigned_div{range_check_ptr}(a, b) -> wad {
        alloc_locals;

        assert_valid(a);
        assert_valid(b);

        // `signed_div_rem` assumes 0 < div <= CAIRO_PRIME / rc_bound
        let div = abs_value(b);
        // `sign` assumes -rc_bound < value < rc_bound
        let div_sign = sign(b);
        tempvar prod = a * WAD_SCALE;
        // `signed_div_rem` asserts -BOUND <= `wad_u` < BOUND
        let (wad_u, _) = signed_div_rem(prod, div, BOUND);
        return wad_u * div_sign;
    }

    // @notice Integer wad division of unsigned Wad values with underflow and overflow checks.
    // @dev Reverts if either arguments or the resulting value
    //      is not a value between 0 and BOUND, both inclusive.
    // @param a An unsigned Wad value between 0 and BOUND, both inclusive.
    // @param b An unsigned Wad value between 0 and BOUND, both inclusive.
    // @return The quotient of the division of `a` by `b` (`a // b`).
    //         An unsigned Wad value between 0 and BOUND, both inclusive.
    func wunsigned_div{range_check_ptr}(a, b) -> wad {
        assert_valid_unsigned(a);
        assert_valid_unsigned(b);

        tempvar product = a * WAD_SCALE;
        let (q, _) = unsigned_div_rem(product, b);
        assert_valid(q);
        return q;
    }

    // @notice Integer wad division of numeric values without underflow and overflow checks.
    // @dev Does not check if the arguments or result is a value between 0 and BOUND, both inclusive.
    //      Use only if the quotient of the integer wad division of `a` by `b`
    //      is guaranteed to be between 0 and BOUND, both inclusive.
    // @param a A numeric value.
    // @param b A numeric value.
    // @return The quotient of the integer wad division of `a` by `b` (`a // b`).
    //         A wad value.
    func wunsigned_div_unchecked{range_check_ptr}(a, b) -> wad {
        tempvar product = a * WAD_SCALE;
        let (q, _) = unsigned_div_rem(product, b);
        return q;
    }

    // @notice Multiply two signed Rays with overflow and underflow checks.
    // @dev Reverts if either arguments or the resulting value
    //      is not a value between -BOUND and BOUND, both inclusive.
    // @param a A signed Ray value between -BOUND and BOUND, both inclusive.
    // @param b A signed Ray value between -BOUND and BOUND, both inclusive.
    // @return The product of `a` and `b`.
    //         A signed Ray value between -BOUND and BOUND, both inclusive.
    func rmul{range_check_ptr}(a: ray, b: ray) -> ray {
        assert_valid(a);
        assert_valid(b);

        tempvar prod = a * b;
        // `signed_div_rem` asserts -BOUND <= `scaled_prod` < BOUND
        let (scaled_prod, _) = signed_div_rem(prod, RAY_SCALE, BOUND);
        return scaled_prod;
    }

    // @notice Integer ray division of signed Ray values with underflow and overflow checks.
    // @dev Fractional values are rounded down to smallest integer.
    //      Reverts if either arguments or the resulting value
    //      is not a value between -BOUND and BOUND, both inclusive.
    // @param a A signed Ray value between -BOUND and BOUND, both inclusive.
    // @param b A signed Ray value between -BOUND and BOUND, both inclusive.
    // @return The quotient of the division of `a` by `b` (`a // b`).
    //         A signed Ray value between -BOUND and BOUND, both inclusive.
    func rsigned_div{range_check_ptr}(a, b) -> ray {
        alloc_locals;

        assert_valid(a);
        assert_valid(b);

        let div = abs_value(b);
        let div_sign = sign(b);
        tempvar prod = a * RAY_SCALE;
        // `signed_div_rem` asserts -BOUND <= `ray_u` < BOUND
        let (ray_u, _) = signed_div_rem(prod, div, BOUND);
        return ray_u * div_sign;
    }

    // @notice Integer ray division of unsigned WadRay values with underflow and overflow checks.
    // @dev Reverts if either arguments or the resulting value
    //      is not a value between 0 and BOUND, both inclusive.
    // @param a An unsigned Ray value between 0 and BOUND, both inclusive.
    // @param b An unsigned Ray value between 0 and BOUND, both inclusive.
    // @return The quotient of the division of `a` by `b` (`a // b`).
    //         An unsigned Ray value between 0 and BOUND, both inclusive.
    func runsigned_div{range_check_ptr}(a, b) -> ray {
        assert_valid_unsigned(a);
        assert_valid_unsigned(b);

        tempvar product = a * RAY_SCALE;
        let (q, _) = unsigned_div_rem(product, b);
        assert_valid_unsigned(q);
        return q;
    }

    // @notice Integer ray division of numeric values without underflow and overflow checks.
    // @dev Does not check if the arguments or result is a value between 0 and BOUND, both inclusive.
    //      Use only if the quotient of the integer ray division of `a` by `b`
    //      is guaranteed to be between 0 and BOUND, both inclusive.
    // @param a A numeric value.
    // @param b A numeric value.
    // @return The quotient of the integer wad division of `a` by `b` (`a // b`).
    //         A ray value.
    func runsigned_div_unchecked{range_check_ptr}(a, b) -> ray {
        tempvar product = a * RAY_SCALE;
        let (q, _) = unsigned_div_rem(product, b);
        return q;
    }

    //
    // Conversions
    //

    // @notice Convert an unsigned WadRay value to a Uint256 struct.
    // @dev Reverts if the argument is not a value between 0 and BOUND, both inclusive.
    // @param n An unsigned WadRay value between 0 and BOUND, both inclusive.
    // @return A Uint256 struct representing the same value as `n`.
    func to_uint{range_check_ptr}(n) -> (uint: Uint256) {
        assert_valid_unsigned(n);
        let uint = Uint256(low=n, high=0);
        return (uint,);
    }

    // @notice Convert a Uint256 struct to a numeric value.
    // @dev Reverts if the result is not a value between 0 and BOUND, both inclusive.
    // @param n A Uint256 struct representing a number.
    // @return An unsigned WadRay value between 0 and BOUND, both inclusive.
    func from_uint{range_check_ptr}(n: Uint256) -> ufelt {
        assert n.high = 0;
        assert_valid_unsigned(n.low);
        return n.low;
    }

    // @notice Convert an integer to Wad.
    // @dev Reverts if the result is not a value between -BOUND and BOUND, both inclusive.
    // @param n A numerical value.
    // @return A signed Wad value between -BOUND and BOUND, both inclusive.
    func to_wad{range_check_ptr}(n) -> wad {
        let n_wad = n * WAD_SCALE;
        assert_valid(n_wad);
        return n_wad;
    }

    // @notice Convert Wad to an integer.
    // @dev Reverts if the argument is not a value between -BOUND and BOUND, both inclusive.
    // @param n A signed Wad value between -BOUND and BOUND, both inclusive.
    // @return Descaled integer value of the Wad with fractional component truncated.
    //         A numeric value between -BOUND and BOUND, both inclusive.
    func wad_to_felt{range_check_ptr}(n: wad) -> felt {
        assert_valid(n);
        let (converted, _) = signed_div_rem(n, WAD_SCALE, BOUND);
        return converted;
    }

    // @notice Upscale Wad to Ray.
    // @dev Reverts if the argument or result is not a value between -BOUND and BOUND, both inclusive.
    // @param n A signed Wad value between -BOUND and BOUND, both inclusive.
    // @return A signed Ray value between -BOUND and BOUND, both inclusive.
    func wad_to_ray{range_check_ptr}(n: wad) -> ray {
        assert_valid(n);
        let converted = n * DIFF;
        assert_valid(converted);
        return converted;
    }

    // @notice Truncate a Ray to Wad.
    // @dev Reverts if the argument is not a value between -BOUND and BOUND, both inclusive.
    // @param n A signed Ray value between -BOUND and BOUND, both inclusive.
    // @return Descaled Wad value of the Ray with fractional component truncated.
    //         A signed wad value between -BOUND and BOUND, both inclusive.
    func ray_to_wad{range_check_ptr}(n: ray) -> wad {
        assert_valid(n);
        let (converted, _) = unsigned_div_rem(n, DIFF);
        return converted;
    }

    // @notice Scale a fixed point number with less than 18 decimals of precision to Wad.
    // @dev Reverts if the number of decimals is greater than 18.
    //      Reverts if the result is not a value between -BOUND and BOUND, both inclusive.
    // @param n Value to scale.
    // @param decimals Number of decimals to scale by. Has to be less than 18 (Wad decimals).
    // @return Value `n` scaled to Wad.
    //         A signed Wad value between -BOUND and BOUND, both inclusive.
    func fixed_point_to_wad{range_check_ptr}(n: ufelt, decimals: ufelt) -> wad {
        with_attr error_message("WadRay: Decimals is greater than 18") {
            assert_nn_le(decimals, WAD_DECIMALS);
        }
        let (scale: ufelt) = pow10(WadRay.WAD_DECIMALS - decimals);
        let scaled_n: wad = n * scale;
        assert_valid(scaled_n);
        return scaled_n;
    }
}
