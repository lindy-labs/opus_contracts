import math

import pytest
from hypothesis import example, given, settings
from hypothesis import strategies as st
from starkware.starknet.testing.starknet import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.utils import WAD_SCALE, compile_contract, to_wad

BOUND = 2**125
RANGE_CHECK_BOUND = 2**128
PRIME = 2**251 + 17 * 2**192 + 1


st_int = st.integers(min_value=0, max_value=2**251 - 1)


@pytest.fixture(scope="session")
async def wad_ray(starknet, users) -> StarknetContract:
    contract = compile_contract("tests/shared/test_wad_ray.cairo")
    wad_ray = await starknet.deploy(contract_class=contract, constructor_calldata=[])
    return wad_ray


BOUND_TEST_CASES = [-(BOUND + 1), -BOUND, -1, 0, 1, BOUND - 1, BOUND, BOUND + 1]


@pytest.mark.parametrize("val", BOUND_TEST_CASES)
@pytest.mark.asyncio
async def test_assert_valid(wad_ray, val):
    if abs(val) > BOUND:
        with pytest.raises(StarkException):
            await wad_ray.test_assert_valid(val).invoke()
    else:
        await wad_ray.test_assert_valid(val).invoke()


@pytest.mark.parametrize("val", BOUND_TEST_CASES)
@pytest.mark.asyncio
async def test_assert_valid_unsigned(wad_ray, val):
    if val < 0 or val > BOUND:
        with pytest.raises(StarkException):
            await wad_ray.test_assert_valid_unsigned(val).invoke()
    else:
        await wad_ray.test_assert_valid_unsigned(val).invoke()


@settings(max_examples=50, deadline=None)
@given(val=st.integers(min_value=-(2**200), max_value=2**200))
@example(val=to_wad(RANGE_CHECK_BOUND) + 1)
@example(val=to_wad(RANGE_CHECK_BOUND))
@example(val=to_wad(BOUND + 1))
@example(val=to_wad(BOUND))
@example(val=to_wad(to_wad(25)))  # Test exact multiple of wad - should return same value
@example(val=0)
@example(val=-to_wad(BOUND + 1))
@example(val=-to_wad(BOUND))
@example(val=to_wad(-RANGE_CHECK_BOUND))
@example(val=to_wad(-(RANGE_CHECK_BOUND + 1)))
@pytest.mark.asyncio
async def test_floor(wad_ray, val):
    # For positive integers, input value to contract call is same as value
    input_val = val

    # Perform integer division
    q = val // WAD_SCALE
    expected_py = to_wad(math.floor(q))
    expected_cairo = expected_py

    if val < 0:
        # For negative integers, input value to contract call is PRIME - abs(value)
        input_val = PRIME + val
        expected_cairo = PRIME + expected_py

    if q < (-BOUND) or q >= BOUND:
        # Exception raised by Cairo's builtin `signed_div_rem`
        # -bound <= q < bound
        with pytest.raises(StarkException):
            await wad_ray.test_floor(input_val).invoke()
    elif expected_py < (-BOUND) or expected_py > BOUND:
        with pytest.raises(StarkException, match="WadRay: Result is out of bounds"):
            await wad_ray.test_floor(input_val).invoke()
    else:
        res = (await wad_ray.test_floor(input_val).invoke()).result.wad
        assert res == expected_cairo


@settings(max_examples=50, deadline=None)
@given(val=st.integers(min_value=-(2**200), max_value=2**200))
@example(val=to_wad(RANGE_CHECK_BOUND) + 1)
@example(val=to_wad(RANGE_CHECK_BOUND))
@example(val=to_wad(BOUND + 1))
@example(val=to_wad(BOUND))
@example(val=to_wad(to_wad(25)))  # Test exact multiple of wad - should return same value
@example(val=0)
@example(val=-to_wad(BOUND + 1))
@example(val=-to_wad(BOUND))
@example(val=to_wad(-RANGE_CHECK_BOUND))
@example(val=to_wad(-(RANGE_CHECK_BOUND + 1)))
@pytest.mark.asyncio
async def test_ceil(wad_ray, val):
    # For positive integers, input value to contract call is same as value
    input_val = val

    # Perform integer division
    q = val // WAD_SCALE
    r = val % WAD_SCALE
    expected_py = to_wad(math.floor(q))

    if r == 0:
        # If exact multiple of wad (i.e. no remainder), input value should be returned.
        expected_cairo = val
    else:
        # Otherwise, round up by adding one wad
        expected_cairo = expected_py + WAD_SCALE

    if val < 0:
        # For negative integers, input value to contract call is PRIME - abs(value)
        input_val = PRIME + val
        expected_cairo = PRIME + expected_cairo

        # Negative integers below one wad are rounded to 0
        if expected_cairo == PRIME:
            expected_cairo = 0

    if q < (-BOUND) or q >= BOUND:
        # Exception raised by Cairo's builtin `signed_div_rem`
        # -bound <= q < bound
        with pytest.raises(StarkException):
            await wad_ray.test_ceil(input_val).invoke()
    elif expected_py < (-BOUND) or expected_py > BOUND:
        with pytest.raises(StarkException, match="WadRay: Result is out of bounds"):
            await wad_ray.test_ceil(input_val).invoke()
    else:
        res = (await wad_ray.test_ceil(input_val).invoke()).result.wad
        assert res == expected_cairo
