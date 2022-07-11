import math

import pytest
from hypothesis import example, given, settings
from hypothesis import strategies as st
from starkware.starknet.testing.starknet import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.utils import RANGE_CHECK_BOUND, WAD_SCALE, compile_contract, signed_int_to_felt, to_wad

BOUND = 2**125


st_int = st.integers(min_value=-(2**200), max_value=2**200)
st_uint = st.integers(min_value=0, max_value=2 * 200)


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
@given(val=st_int)
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
    input_val = signed_int_to_felt(val)

    # Perform integer division
    q = val // WAD_SCALE
    expected_py = to_wad(math.floor(q))
    expected_cairo = signed_int_to_felt(expected_py)

    if q < (-BOUND) or q >= BOUND:
        # Exception raised by Cairo's builtin `signed_div_rem`
        # -bound <= q < bound
        with pytest.raises(StarkException):
            await wad_ray.test_floor(input_val).invoke()
    elif abs(expected_py) > BOUND:
        with pytest.raises(StarkException, match="WadRay: Result is out of bounds"):
            await wad_ray.test_floor(input_val).invoke()
    else:
        res = (await wad_ray.test_floor(input_val).invoke()).result.wad
        assert res == expected_cairo


@settings(max_examples=50, deadline=None)
@given(val=st_int)
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
    input_val = signed_int_to_felt(val)

    # Perform integer division
    q = val // WAD_SCALE
    r = val % WAD_SCALE
    expected_py = to_wad(math.floor(q))

    if r == 0:
        # If exact multiple of wad (i.e. no remainder), input value should be returned.
        expected_cairo = val
    else:
        # Otherwise, round up by adding one wad
        expected_cairo = signed_int_to_felt(expected_py + WAD_SCALE)

    if q < (-BOUND) or q >= BOUND:
        # Exception raised by Cairo's builtin `signed_div_rem`
        # -bound <= q < bound
        with pytest.raises(StarkException):
            await wad_ray.test_ceil(input_val).invoke()
    elif abs(expected_py) > BOUND:
        with pytest.raises(StarkException, match="WadRay: Result is out of bounds"):
            await wad_ray.test_ceil(input_val).invoke()
    else:
        res = (await wad_ray.test_ceil(input_val).invoke()).result.wad
        assert res == expected_cairo


@settings(max_examples=50, deadline=None)
@given(left=st_int, right=st_int)
@pytest.mark.asyncio
async def test_add_sub(wad_ray, left, right):
    left_input_val = signed_int_to_felt(left)
    right_input_val = signed_int_to_felt(right)

    expected_py = left + right
    expected_cairo = signed_int_to_felt(expected_py)

    if abs(expected_py) > BOUND:
        with pytest.raises(StarkException, match="WadRay: Result is out of bounds"):
            await wad_ray.test_add(left_input_val, right_input_val).invoke()

    else:
        res = (await wad_ray.test_add(left_input_val, right_input_val).invoke()).result.wad
        assert res == expected_cairo

    expected_py = left - right
    expected_cairo = signed_int_to_felt(expected_py)

    if abs(expected_py) > BOUND:
        with pytest.raises(StarkException, match="WadRay: Result is out of bounds"):
            await wad_ray.test_sub(left_input_val, right_input_val).invoke()

    else:
        res = (await wad_ray.test_sub(left_input_val, right_input_val).invoke()).result.wad
        assert res == expected_cairo


@settings(max_examples=50, deadline=None)
@given(left=st_uint, right=st_uint)
@example(left=0, right=1)
@example(left=0, right=0)
@example(left=1, right=0)
@pytest.mark.asyncio
async def test_add_sub_unsigned(wad_ray, left, right):
    left_input_val = signed_int_to_felt(left)
    right_input_val = signed_int_to_felt(right)

    expected_py = left + right
    expected_cairo = signed_int_to_felt(expected_py)

    if expected_py < 0 or expected_py > BOUND:
        with pytest.raises(StarkException, match="WadRay: Result is out of bounds"):
            await wad_ray.test_add_unsigned(left_input_val, right_input_val).invoke()

    else:
        res = (await wad_ray.test_add_unsigned(left_input_val, right_input_val).invoke()).result.wad
        assert res == expected_cairo

    expected_py = left - right
    expected_cairo = signed_int_to_felt(expected_py)

    if expected_py < 0 or expected_py > BOUND:
        with pytest.raises(StarkException, match="WadRay: Result is out of bounds"):
            await wad_ray.test_sub_unsigned(left_input_val, right_input_val).invoke()

    else:
        res = (await wad_ray.test_sub_unsigned(left_input_val, right_input_val).invoke()).result.wad
        assert res == expected_cairo
