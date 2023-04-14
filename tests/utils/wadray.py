from decimal import Decimal
from typing import Union

from tests.utils.types import Uint256, Uint256like

WAD_DECIMALS = 18
RAY_DECIMALS = 27
WAD_PERCENT = 10 ** (WAD_DECIMALS - 2)
RAY_PERCENT = 10 ** (RAY_DECIMALS - 2)
WAD_SCALE = 10**WAD_DECIMALS
RAY_SCALE = 10**RAY_DECIMALS
WAD_RAY_DIFF = RAY_SCALE // WAD_SCALE
WAD_RAY_BOUND = 2**125


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
