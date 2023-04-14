# A note on precision
# ----------------------------
# The larger the exponent, the less precise the cairo `exp` function becomes.
# This is because calculating the result for larger exponents involves more fixed-point multiplications,
# each of create additional precision loss.
# As a result, most of the tests have been split into two: one checking the upper range with larger error margins,
# and one checking the lower range with a smaller error margin.

from decimal import Decimal

import pytest
from hypothesis import assume, example, given, settings
from hypothesis import strategies as st
from numpy import exp
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

from tests.utils.math import assert_equalish, from_wad, signed_int_to_felt, to_wad
from tests.utils.utils import compile_contract

# Lower bound of the upper range
UPPER_RANGE_LB = 10
st_upper_range = st.integers(min_value=-to_wad(UPPER_RANGE_LB), max_value=to_wad(40))
st_lower_range = st.integers(min_value=-to_wad(40), max_value=to_wad(UPPER_RANGE_LB))

st_invalid_range1 = st.integers(min_value=-(2**125), max_value=-to_wad(40) - 1)
st_invalid_range2 = st.integers(min_value=to_wad(40) + 1, max_value=2**125)


@pytest.fixture(scope="session")
async def deploy_test_contract(starknet_session: Starknet):
    test_contract = compile_contract("tests/lib/test_exp.cairo")

    contract = await starknet_session.deploy(contract_class=test_contract)

    return contract


@settings(max_examples=10, deadline=None)
@given(val_r1=st_invalid_range1, val_r2=st_invalid_range2)
@example(val_r1=-to_wad(40) - 1, val_r2=to_wad(40) + 1)
@pytest.mark.asyncio
async def test_exp_fail(deploy_test_contract, val_r1, val_r2):
    contract = deploy_test_contract

    with pytest.raises(StarkException):
        await contract.get_exp(signed_int_to_felt(val_r1)).execute()

    with pytest.raises(StarkException):
        await contract.get_exp(signed_int_to_felt(val_r2)).execute()


#
# Lower range
#


@settings(max_examples=50, deadline=None)
@given(val=st_lower_range)
@example(val=to_wad(25))
@example(val=-to_wad(40))
@pytest.mark.asyncio
async def test_exp_pass_lower(deploy_test_contract, val):
    contract = deploy_test_contract

    tx = await contract.get_exp(signed_int_to_felt(val)).execute()

    result = Decimal(from_wad(tx.result.res))
    expected_result = Decimal(exp(from_wad(val)))
    assert_equalish(result, expected_result, Decimal("0.0001"))


# This tests that exp(-x) = 1/exp(x)
@settings(max_examples=50, deadline=None)
@given(val=st_lower_range)
@example(val=to_wad(25))
@example(val=-to_wad(40))
@example(val=-39654772204664767312)
@pytest.mark.asyncio
async def test_exp_inversions_lower(deploy_test_contract, val):
    contract = deploy_test_contract

    result = Decimal(from_wad((await contract.get_exp(signed_int_to_felt(val)).execute()).result.res))
    inverse_result = Decimal(from_wad((await contract.get_exp(signed_int_to_felt(-val)).execute()).result.res))

    # Precision starts getting pretty bad with all these multiplications and divisions
    if val < -to_wad(39):
        error_margin = Decimal("0.17")
    else:
        error_margin = Decimal("0.06")

    assert_equalish(result * inverse_result, Decimal(1), error_margin)


# This tests that exp(x+y) = exp(x)*exp(y)
@settings(max_examples=50, deadline=None)
@given(val1=st_lower_range, val2=st_lower_range)
@pytest.mark.asyncio
async def test_exp_sum_lower(deploy_test_contract, val1, val2):

    # Skip if the sum of the two values is greater than 40 or less than -40
    # (the maximum and minimum possible values respectively)
    assume(val1 + val2 <= to_wad(40) and val1 + val2 >= -to_wad(40))

    contract = deploy_test_contract

    result1 = Decimal(from_wad((await contract.get_exp(signed_int_to_felt(val1)).execute()).result.res))
    result2 = Decimal(from_wad((await contract.get_exp(signed_int_to_felt(val2)).execute()).result.res))
    result_sum = Decimal(from_wad((await contract.get_exp(signed_int_to_felt(val1 + val2)).execute()).result.res))

    assert_equalish(result1 * result2, result_sum, Decimal("0.001"))


#
# Upper range
#


@settings(max_examples=50, deadline=None)
@given(val=st_upper_range)
@example(val=to_wad(25))
@example(val=-to_wad(40))
@pytest.mark.asyncio
async def test_exp_pass_upper(deploy_test_contract, val):
    contract = deploy_test_contract

    tx = await contract.get_exp(signed_int_to_felt(val)).execute()

    result = Decimal(from_wad(tx.result.res))
    expected_result = Decimal(exp(from_wad(val)))
    assert_equalish(result, expected_result, Decimal("1"))


# This tests that exp(-x) * exp(x) = 1
@settings(max_examples=50, deadline=None)
@given(val=st_upper_range)
@example(val=to_wad(40))
@example(val=-to_wad(40))
@pytest.mark.asyncio
async def test_exp_inversions_upper(deploy_test_contract, val):
    contract = deploy_test_contract

    result = Decimal(from_wad((await contract.get_exp(signed_int_to_felt(val)).execute()).result.res))
    inverse_result = Decimal(from_wad((await contract.get_exp(signed_int_to_felt(-val)).execute()).result.res))

    # Precision starts getting pretty bad with all these multiplications and divisions
    assert_equalish(result * inverse_result, Decimal(1), Decimal("0.3"))


# This tests that exp(x+y) = exp(x)*exp(y)
@settings(max_examples=50, deadline=None)
@given(val1=st_upper_range, val2=st_upper_range)
@pytest.mark.asyncio
async def test_exp_sum_upper(deploy_test_contract, val1, val2):

    # Skip if the sum of the two values is greater than 40 or less than -40
    # (the maximum and minimum possible values respectively)
    assume(val1 + val2 <= to_wad(40) and val1 + val2 >= -to_wad(40))

    contract = deploy_test_contract

    result1 = Decimal(from_wad((await contract.get_exp(signed_int_to_felt(val1)).execute()).result.res))
    result2 = Decimal(from_wad((await contract.get_exp(signed_int_to_felt(val2)).execute()).result.res))
    result_sum = Decimal(from_wad((await contract.get_exp(signed_int_to_felt(val1 + val2)).execute()).result.res))

    assert_equalish(result1 * result2, result_sum, Decimal("1"))
