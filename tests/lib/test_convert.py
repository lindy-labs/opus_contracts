import pytest
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

from tests.utils.utils import compile_contract

A_UPPER_BOUND = 2**128


@pytest.fixture(scope="session")
async def convert(starknet_session: Starknet) -> StarknetContract:
    contract = compile_contract("tests/lib/test_convert.cairo")
    convert = await starknet_session.deploy(contract_class=contract, constructor_calldata=[])
    return convert


@pytest.mark.parametrize(
    "a,b",
    [
        (0, 0),
        (0, 1),
        (1, 0),
        (1, 1),
        (5, 5),
        (2**123 - 1, 2**128 - 2),
        (2**123 - 2, 2**128 - 1),
        (2**123 - 1, 2**128 - 1),
    ],
)
@pytest.mark.asyncio
async def test_pack_felt_pass(convert, a, b):
    res = (await convert.test_pack_felt(a, b).execute()).result.packed_felt
    assert res == b + (a * A_UPPER_BOUND)


@pytest.mark.parametrize(
    "a,b",
    [
        (-1, 0),
        (0, -1),
        (-1, -1),
        (2**128 - 1, 2**123),
        (2**128, 2**123 - 1),
        (2**128, 2**123),
    ],
)
@pytest.mark.asyncio
async def test_pack_felt_fail(convert, a, b):
    with pytest.raises(StarkException):
        (await convert.test_pack_felt(a, b).execute()).result.packed_felt
