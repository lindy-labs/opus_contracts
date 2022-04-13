import asyncio
from collections import namedtuple
from functools import cache
from typing import Callable, Tuple

from account import Account
from utils import compile_contract, str_to_felt, Uint256

import pytest
from starkware.starknet.testing.starknet import Starknet, StarknetContract


MRACParameters = namedtuple(
    "MRACParameters", ["u", "r", "y", "theta", "theta_underline", "theta_bar", "gamma", "T"]
)

SCALE = 10 ** 18

DEFAULT_MRAC_PARAMETERS = MRACParameters(*[int(i * SCALE) for i in (0, 1.5, 0, 0, 0, 2, 0.1, 1)])


@pytest.fixture(scope="session")
def event_loop():
    return asyncio.new_event_loop()


@pytest.fixture(scope="session")
async def starknet() -> Starknet:
    starknet = await Starknet.empty()
    return starknet


@pytest.fixture(scope="session")
def users(starknet: Starknet) -> Callable[[str], Account]:
    """
    A factory fixture that creates users.

    The returned factory function takes a single string as an argument,
    which it uses as an identifier of the user and also to generates their
    private key. The fixture is session-scoped and has an internal cache,
    so the same argument (user name) will return the same result.

    The return value is a tuple of (signer: Signer, contract: StarknetContract)
    useful for sending signed transactions, assigning ownership, etc.
    """

    @cache
    async def get_or_create_user(name):
        account = Account(name)
        await account.deploy(starknet)
        return account

    return get_or_create_user


@pytest.fixture
async def usda(starknet, users) -> StarknetContract:
    contract = compile_contract("contracts/USDa/USDa.cairo")
    owner = await users("usda owner")
    return await starknet.deploy(contract_def=contract, constructor_calldata=[owner.address])


@pytest.fixture
async def mrac_controller(starknet) -> StarknetContract:
    contract = compile_contract("contracts/MRAC/controller.cairo")
    return await starknet.deploy(
        contract_def=contract, constructor_calldata=[*DEFAULT_MRAC_PARAMETERS]
    )
