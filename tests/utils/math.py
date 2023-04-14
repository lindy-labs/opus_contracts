from decimal import ROUND_DOWN, Decimal
from typing import Union

from tests.utils.types import Uint256, Uint256like

CAIRO_PRIME = 2**251 + 17 * 2**192 + 1

WAD_DECIMALS = 18
RAY_DECIMALS = 27
WAD_PERCENT = 10 ** (WAD_DECIMALS - 2)
RAY_PERCENT = 10 ** (RAY_DECIMALS - 2)
WAD_SCALE = 10**WAD_DECIMALS
RAY_SCALE = 10**RAY_DECIMALS
WAD_RAY_DIFF = RAY_SCALE // WAD_SCALE
WAD_RAY_BOUND = 2**125


#
# General
#


def signed_int_to_felt(a: int) -> int:
    """Takes in integer value, returns input if positive, otherwise return CAIRO_PRIME + input"""
    if a >= 0:
        return a
    return CAIRO_PRIME + a


def custom_error_margin(negative_exp: int) -> Decimal:
    return Decimal(f"1E-{negative_exp}")


def assert_equalish(a: Decimal, b: Decimal, error=custom_error_margin(10)):
    # Truncate inputs to the accepted error margin
    # For example, comparing 0.0001 and 0.00020123 should pass with an error margin of 1E-4.
    # Without rounding, it would not pass because 0.00010123 > 0.0001
    a = a.quantize(error, rounding=ROUND_DOWN)
    b = b.quantize(error, rounding=ROUND_DOWN)
    assert abs(a - b) <= error


def to_empiric(value: Union[int, float, Decimal]) -> int:
    """
    Empiric reports the pairs used in this test suite with 8 decimals.
    This function converts a "regular" numeric value to an Empiric native
    one, i.e. as if it was returned from Empiric.
    """
    return int(value * (10**8))


#
# Wadray functions
#


def to_uint(a: int) -> Uint256:
    """Takes in value, returns Uint256 tuple."""
    return Uint256(low=(a & ((1 << 128) - 1)), high=(a >> 128))


def from_uint(uint: Uint256like) -> int:
    """Takes in uint256-ish tuple, returns value."""
    return uint[0] + (uint[1] << 128)


def to_fixed_point(n: Union[int, float, Decimal], decimals: int) -> int:
    """
    Helper function to scale a number to its fixed point equivalent
    according to the given decimal precision.

    Arguments
    ---------
    n: int
        Amount in real terms.
    decimals: int
        Number of decimals to scale by.

    Returns
    -------
    Scaled amount.
    """
    return int(n * 10**decimals)


def from_fixed_point(n: int, decimals: int) -> Decimal:
    """
    Helper function to scale a fixed point number to real value
    according to the given decimal precision.

    Arguments
    ---------
    n: int
        Amount in fixed point.
    decimals: int
        Number of decimals to scale by.

    Returns
    -------
    Real value in Decimal.
    """
    return Decimal(n) / 10**decimals


def to_wad(n: Union[int, float, Decimal]) -> int:
    return to_fixed_point(n, WAD_DECIMALS)


def to_ray(n: Union[int, float, Decimal]) -> int:
    return to_fixed_point(n, RAY_DECIMALS)


def from_wad(n: int) -> Decimal:
    return from_fixed_point(n, WAD_DECIMALS)


def wad_to_ray(n: int) -> int:
    return to_fixed_point(n, RAY_DECIMALS - WAD_DECIMALS)


def ray_to_wad(n: int) -> int:
    return n // 10 ** (RAY_DECIMALS - WAD_DECIMALS)


def from_ray(n: int) -> Decimal:
    return from_fixed_point(n, RAY_DECIMALS)
