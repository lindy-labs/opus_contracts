import asyncio
import decimal
from collections import namedtuple
from typing import Awaitable, Callable

import pytest
from cache import AsyncLRU
from starkware.starknet.testing.starknet import Starknet, StarknetContract

from tests.account import Account
from tests.utils import Uint256, compile_contract, str_to_felt

MRACParameters = namedtuple("MRACParameters", ["u", "r", "y", "theta", "theta_underline", "theta_bar", "gamma", "T"])

SCALE = 10**18

DEFAULT_MRAC_PARAMETERS = MRACParameters(*[int(i * SCALE) for i in (0, 1.5, 0, 0, 0, 2, 0.1, 1)])


@pytest.fixture(autouse=True, scope="session")
def setup():
    decimal.getcontext().prec = 18


@pytest.fixture(scope="session")
def event_loop():
    return asyncio.new_event_loop()


@pytest.fixture(scope="session")
async def starknet() -> Starknet:
    starknet = await Starknet.empty()
    return starknet


# TODO: figure out a good way how not to use magic string constants for common users
@pytest.fixture(scope="session")
def users(starknet: Starknet) -> Callable[[str], Awaitable[Account]]:
    """
    A factory fixture that creates users.

    The returned factory function takes a single string as an argument,
    which it uses as an identifier of the user and also to generates their
    private key. The fixture is session-scoped and has an internal cache,
    so the same argument (user name) will return the same result.

    The return value is an instance of Account, useful for sending
    signed transactions, assigning ownership, etc.
    """

    @AsyncLRU()
    async def create_user(name):
        account = Account(name)
        await account.deploy(starknet)
        return account

    return create_user


@pytest.fixture(scope="session")
def tokens(
    starknet: Starknet,
) -> Callable[[str, str, int, Uint256, int], Awaitable[StarknetContract]]:
    """
    A factory fixture that creates a mock ERC20 token.

    The returned factory function requires 5 input arguments to deploy
    a new token: name (str), symbol (str), decimals (int),
    initial supply (Uint256) and recipient (int). It returns an instance
    of StarknetContract.
    """
    contract = compile_contract("tests/mocks/ERC20.cairo")

    async def create_token(name: str, symbol: str, decimals: int, initial_supply: tuple[int, int], recipient: int):
        name = str_to_felt(name)
        symbol = str_to_felt(symbol)
        token = await starknet.deploy(
            contract_class=contract,
            constructor_calldata=[name, symbol, decimals, *initial_supply, recipient],
        )
        return token

    return create_token


@pytest.fixture
async def usda(starknet, users) -> StarknetContract:
    owner = await users("usda owner")
    contract = compile_contract("contracts/USDa/USDa.cairo")
    return await starknet.deploy(contract_class=contract, constructor_calldata=[owner.address])


@pytest.fixture
async def mrac_controller(starknet) -> StarknetContract:
    contract = compile_contract("contracts/MRAC/controller.cairo")
    return await starknet.deploy(contract_class=contract, constructor_calldata=[*DEFAULT_MRAC_PARAMETERS])
