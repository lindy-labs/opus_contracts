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

    // @notice Check if number is a valid signed value within BOUNDs.
    //         Reverts if `n` overflows or underflows.
    // @param n A value to assert.
    func assert_valid{range_check_ptr}(n) {
        with_attr error_message("WadRay: Out of bounds") {
            assert_le(n, BOUND);
            assert_le(-BOUND, n);
        }
        return ();
    }

    // @notice Check if number is a valid unsigned value within BOUNDs.
    //         Reverts if `n` overflows.
    // @param n A value to assert.
    func assert_valid_unsigned{range_check_ptr}(n) {
        with_attr error_message("WadRay: Out of bounds") {
            assert_nn_le(n, BOUND);
        }
        return ();
    }

    // @notice Select the smaller numerical value. Reverts if either
    //         argument is not valid.
    // @param a A valid, unsigned WadRay value.
    // @param b A valid, unsigned WadRay value.
    // @return `a` if it's less than or equal to `b`, otherwise `b`.
    func unsigned_min{range_check_ptr}(a, b) -> ufelt {
        assert_valid_unsigned(a);
        assert_valid_unsigned(b);

        let le = is_le(a, b);
        if (le == TRUE) {
            return a;
        }
        return b;
    }

    // @notice Select the greater numerical value. Reverts if either
    //         argument is not valid.
    // @param a A valid, unsigned WadRay value.
    // @param b A valid, unsigned WadRay value.
    // @return `b` if it's greater than `a`, otherwise `a`.
    func unsigned_max{range_check_ptr}(a, b) -> ufelt {
        assert_valid_unsigned(a);
        assert_valid_unsigned(b);

        let le = is_le(a, b);
        if (le == TRUE) {
            return b;
        }
        return a;
    }

    // @notice Round down the argument to its nearest Wad value. Round down
    //         away from zero for negative numbers. Reverts if resulting
    //         value is not within BOUNDs.
    // @param n A numeric value.
    // @return Rounded valid Wad value.
    func floor{range_check_ptr}(n) -> wad {
        let (int_val, mod_val) = signed_div_rem(n, WAD_ONE, BOUND);
        let floored = n - mod_val;
        assert_valid(floored);
        return floored;
    }

    // @notice Round up the argument towards its nearest Wad value. Round up
    //         to zero for negative numbers. Reverts if resulting value is
    //         not within BOUNDs.
    // @param A numeric value.
    // @return Rounded valid Wad value.
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

    // @notice Safely add two numbers. Reverts if arguments are invalid
    //         or if the resulting value overflows BOUNDs.
    // @param a A valid, signed WadRay value.
    // @param b A valid, signed WadRay value.
    // @return The sum of the passed in arguments. A valid, signed WadRay.
    func add{range_check_ptr}(a, b) -> felt {
        assert_valid(a);
        assert_valid(b);

        let sum = a + b;
        assert_valid(sum);
        return sum;
    }

    // @notice Safely add two unsigned numbers. Reverts if arguments are invalid
    //         or if the resulting value overflows BOUNDs.
    // @param a A valid, unsigned WadRay value.
    // @param b A valid, unsigned WadRay value.
    // @return The sum of the passed in arguments. A valid unsigned WadRay.
    func unsigned_add{range_check_ptr}(a, b) -> ufelt {
        assert_valid_unsigned(a);
        assert_valid_unsigned(b);

        let sum = a + b;
        assert_valid_unsigned(sum);
        return sum;
    }

    // @notice Safely subtract two numbers. Reverts if arguments are invalid
    //         or if the resulting value underflows BOUNDs.
    // @param a A valid, signed WadRay value.
    // @param b A valid, signed WadRay value.
    // @return The difference of a and b. A valid, signed WadRay value.
    func sub{range_check_ptr}(a, b) -> felt {
        assert_valid(a);
        assert_valid(b);

        let diff = a - b;
        assert_valid(diff);
        return diff;
    }

    // @noticer Safely subtract two unsigned numbers. Reverts if arguments are invalid
    //          or if the resulting value underflows BOUNDs.
    // @param a A valid, unsigned WadRay value.
    // @param b A valid, unsigned WadRay value.
    // @return The difference of a and b. A valid, unsigned WadRay value.
    func unsigned_sub{range_check_ptr}(a, b) -> ufelt {
        assert_valid_unsigned(a);
        assert_valid_unsigned(b);

        let diff = a - b;
        assert_valid_unsigned(diff);
        return diff;
    }

    // @notice Safely multiply two Wads. Reverts if arguments are invalid
    //         or if the resulting value is out of BOUNDs.
    // @param a A valid, signed Wad value.
    // @param b A valid, signed Wad value.
    // @return The product of passed in arguments.
    func wmul{range_check_ptr}(a: wad, b: wad) -> wad {
        assert_valid(a);
        assert_valid(b);

        tempvar prod = a * b;
        // `signed_div_rem` asserts -BOUND <= `scaled_prod` < BOUND
        let (scaled_prod, _) = signed_div_rem(prod, WAD_SCALE, BOUND);
        return scaled_prod;
    }

    // @notice Calculate integer division of signed WadRay values. Fractional
    //         values are rounded down to smallest integer. Reverts if arguments are
    //         invalid or if the resulting value is out ouf BOUNDs.
    // @param a A valid, signed WadRay value.
    // @param b A valid, signed WadRay value.
    // @return Wad integer as a result of the division of a by b (`a//b`).
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

    // @notice Calculate integer division of unsigned WadRay values. Reverts if
    //         arguments are invalid or if the resulting value is out ouf BOUNDs.
    // @param a A valid, unsigned WadRay value.
    // @param b A valid, unsigned WadRay value.
    // @return Wad integer as a result of the division of a by b (`a//b`).
    func wunsigned_div{range_check_ptr}(a, b) -> wad {
        assert_valid_unsigned(a);
        assert_valid_unsigned(b);

        tempvar product = a * WAD_SCALE;
        let (q, _) = unsigned_div_rem(product, b);
        assert_valid(q);
        return q;
    }

    // @notice Unchecked version of `wunsigned_div`. Does not do any argument or result
    //         value checks, use only if the quotient of a and b is guaranteed not to overflow.
    // @param a An unsigned WadRay value.
    // @param b An unsigned WadRay value.
    // @return Wad integer as a result of teh division of a by b (`a//b`).
    func wunsigned_div_unchecked{range_check_ptr}(a, b) -> wad {
        tempvar product = a * WAD_SCALE;
        let (q, _) = unsigned_div_rem(product, b);
        return q;
    }

    // @notice Safely multiply to Rays. Reverts if arguments are invalid
    //         or if the resulting value is out of BOUNDs.
    // @param a A avlid, signed Ray value.
    // @param b A valid, signed Ray value.
    // @return The product of passed in arguments.
    func rmul{range_check_ptr}(a: ray, b: ray) -> ray {
        assert_valid(a);
        assert_valid(b);

        tempvar prod = a * b;
        // `signed_div_rem` asserts -BOUND <= `scaled_prod` < BOUND
        let (scaled_prod, _) = signed_div_rem(prod, RAY_SCALE, BOUND);
        return scaled_prod;
    }

    // @notice Calculate integer division of signed WadRay values. Fractional
    //         values are rounded down to smallest integer. Reverts if arguments are
    //         invalid or if the resulting value is out ouf BOUNDs.
    // @param a A valid, signed WadRay value.
    // @param b A valid, signed WadRay value.
    // @return Ray integer as a result of the division of a by b (`a//b`).
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

    // @notice Calculate integer division of unsigned WadRay values. Reverts if
    //         arguments are invalid or if the resulting value is out ouf BOUNDs.
    // @param a A valid, unsigned WadRay value.
    // @param b A valid, unsigned WadRay value.
    // @return Ray integer as a result of the division of a by b (`a//b`).
    func runsigned_div{range_check_ptr}(a, b) -> ray {
        assert_valid_unsigned(a);
        assert_valid_unsigned(b);

        tempvar product = a * RAY_SCALE;
        let (q, _) = unsigned_div_rem(product, b);
        assert_valid_unsigned(q);
        return q;
    }

    // @notice Unchecked version of `runsigned_div`. Does not do any argument or result
    //         value checks, use only if the quotient of a and b is guaranteed not to overflow.
    // @param a An unsigned WadRay value.
    // @param b An unsigned WadRay value.
    // @return Ray integer as a result of teh division of a by b (`a//b`).
    func runsigned_div_unchecked{range_check_ptr}(a, b) -> ray {
        tempvar product = a * RAY_SCALE;
        let (q, _) = unsigned_div_rem(product, b);
        return q;
    }

    //
    // Conversions
    //

    // @notice Convert a valid WadRay value to a Uint256 struct. Reverts
    //         if the argument is out of BOUNDs.
    // @param n A valid, unsigned WadRay value.
    // @return A Uint256 struct representing the same value as `n`.
    func to_uint{range_check_ptr}(n) -> (uint: Uint256) {
        assert_valid_unsigned(n);
        let uint = Uint256(low=n, high=0);
        return (uint,);
    }

    // @notice Convert a Uint256 struct to a numeric value. Reverts
    //         if the argument is out of BOUNDs.
    // @param n A Uint256 struct representing a number.
    // @return An unsigned WadRay value.
    func from_uint{range_check_ptr}(n: Uint256) -> ufelt {
        assert n.high = 0;
        assert_valid_unsigned(n.low);
        return n.low;
    }

    // @notice Convert an integer to Wad. Reverts if the resulting value
    //         is out of BOUNDs.
    // @param n A numerical value.
    // @return A Wad value.
    func to_wad{range_check_ptr}(n) -> wad {
        let n_wad = n * WAD_SCALE;
        assert_valid(n_wad);
        return n_wad;
    }

    // @notice Convert Wad to an integer. Reverts if the argument is not valid.
    // @param n A valid, signed Wad value.
    // @return Descaled integer value of the Wad with fractional component truncated.
    func wad_to_felt{range_check_ptr}(n: wad) -> felt {
        assert_valid(n);
        let (converted, _) = signed_div_rem(n, WAD_SCALE, BOUND);
        return converted;
    }

    // @notice Upscale Wad to Ray. Reverts if the resulting value is out of BOUNDs.
    // @param n A valid, signed Wad.
    // @return A valid Ray value.
    func wad_to_ray{range_check_ptr}(n: wad) -> ray {
        assert_valid(n);
        let converted = n * DIFF;
        assert_valid(converted);
        return converted;
    }

    // @notice Truncate a Ray to Wad. Reverts if the argument is not valid.
    // @param n A signed, valid Ray value.
    // @return Descaled Wad value of the Ray with fractional component truncated.
    func ray_to_wad{range_check_ptr}(n: ray) -> wad {
        assert_valid(n);
        let (converted, _) = unsigned_div_rem(n, DIFF);
        return converted;
    }

    // Scales a fixed point number
    // @notice Scale a fixed point number with less than 18 decimals of precision to Wad.
    //         Reverts if resulting value is not within BOUNDs.
    // @param n Value to scale.
    // @param decimals Number of decimals to scale by. Has to be less than 18 (Wad decimals).
    // @return Value `n` scaled to Wad.
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
