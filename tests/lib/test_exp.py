from decimal import Decimal
from math import exp

import pytest
from starkware.starkware_utils.error_handling import StarkException

from tests.utils import assert_equalish, compile_contract, from_wad, signed_int_to_felt, to_wad

TEST_CASES = [
    -40,
    -20.15156,
    -13.1413435,
    -5,
    -0.5,
    -0.00000124431,
    0.00000124431,
    0.00001,
    0,
    1,
    2,
    3,
    3.14159265359,
    13,
]


@pytest.fixture(scope="session")
async def deploy_test_contract(starknet):
    test_contract = compile_contract("tests/lib/exp_contract.cairo")

    contract = await starknet.deploy(contract_class=test_contract)

    return contract


@pytest.mark.parametrize("case", TEST_CASES)
@pytest.mark.asyncio
async def test_exp_pass(deploy_test_contract, case):
    contract = deploy_test_contract

    # Python's exponential function starts to diverge significantly from the Cairo implementation
    # for exponents larger than around 25-26.
    # Interestingly enough, when checking against high-precision online calculators,
    # it seems that the Cairo version is actually significantly
    # more precise than the python version for large numbers, whereas they tend to
    # be extremely close to each other for smaller numbers.

    tx = await contract.get_exp(signed_int_to_felt(to_wad(case))).invoke()

    result = Decimal(from_wad(tx.result.res))
    expected_result = Decimal(exp(case))
    assert_equalish(result, expected_result, Decimal("0.00001"))


@pytest.mark.parametrize("case", [-40.1, 40.1, -40.0000001, 40.0000001])
@pytest.mark.asyncio
async def test_exp_fail(deploy_test_contract, case):
    contract = deploy_test_contract

    with pytest.raises(StarkException):
        await contract.get_exp(signed_int_to_felt(to_wad(case))).invoke()


# This tests that exp(-x) = 1/exp(x)
@pytest.mark.parametrize("case", TEST_CASES)
@pytest.mark.asyncio
async def test_exp_inversions(deploy_test_contract, case):
    contract = deploy_test_contract

    result = Decimal(from_wad((await contract.get_exp(signed_int_to_felt(to_wad(case))).invoke()).result.res))
    inverse_result = Decimal(from_wad((await contract.get_exp(signed_int_to_felt(to_wad(-case))).invoke()).result.res))

    # Precision starts getting pretty bad with all these multiplications and divisions
    assert_equalish(result * inverse_result, Decimal(1), Decimal("0.06"))


# This tests that exp(x+y) = exp(x)*exp(y)
@pytest.mark.parametrize(
    "case",
    [
        [4.1235, 6.514326],
        [4.9619238457, 0.251235],
        [20.111111111, 1.333333],
        [6.1234512, 0.9123],
        [-2.1, 5.1820935],
    ],
)
@pytest.mark.asyncio
async def test_exponent_sum(deploy_test_contract, case):
    contract = deploy_test_contract

    result1 = Decimal(from_wad((await contract.get_exp(signed_int_to_felt(to_wad(case[0]))).invoke()).result.res))
    result2 = Decimal(from_wad((await contract.get_exp(signed_int_to_felt(to_wad(case[1]))).invoke()).result.res))
    result_sum = Decimal(
        from_wad((await contract.get_exp(signed_int_to_felt(to_wad(case[0] + case[1]))).invoke()).result.res)
    )

    assert_equalish(result1 * result2, result_sum, Decimal("0.00001"))
