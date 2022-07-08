import math
from decimal import Decimal

import pytest
from hypothesis import example, given, settings
from hypothesis import strategies as st
from starkware.starknet.testing.starknet import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.utils import RAY_SCALE, WAD_SCALE, compile_contract, from_ray, from_uint, from_wad, to_uint, to_wad

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
@given(val=st.integers(min_value=-(2**251), max_value=2**251 - 1))
@example(val=to_wad(RANGE_CHECK_BOUND) + 1)
@example(val=to_wad(RANGE_CHECK_BOUND))
@example(val=to_wad(BOUND + 1))
@example(val=to_wad(BOUND))
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
    expected_py = to_wad(math.floor(val // WAD_SCALE))
    expected_cairo = expected_py

    if val < 0:
        # For negative integers, input value to contract call is PRIME - abs(value)
        input_val = PRIME + val
        expected_cairo = PRIME + expected_py

    if abs(expected_py) > RANGE_CHECK_BOUND:
        # Exception raised by Cairo's builtin `signed_div_rem`
        with pytest.raises(StarkException):
            await wad_ray.test_floor(val).invoke()
    elif abs(expected_py) > BOUND:
        with pytest.raises(StarkException, match="WadRay: Result is out of bounds"):
            await wad_ray.test_floor(val).invoke()
    else:
        res = (await wad_ray.test_floor(val).invoke()).result.wad
        assert res == expected_cairo
