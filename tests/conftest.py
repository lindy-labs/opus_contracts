import asyncio
from collections import namedtuple
from decimal import getcontext
from functools import cache
from pathlib import Path
from typing import Awaitable, Callable

import pytest
from cache import AsyncLRU
from filelock import FileLock
from starkware.starknet.testing.objects import StarknetTransactionExecutionInfo
from starkware.starknet.testing.starknet import Starknet, StarknetContract

from tests.account import Account
from tests.shrine.constants import DEBT_CEILING, FEED_LEN, MAX_PRICE_CHANGE, MULTIPLIER_FEED, TIME_INTERVAL, YANGS
from tests.utils import (
    RAY_SCALE,
    WAD_SCALE,
    Uint256,
    compile_contract,
    create_feed,
    estimate_gas,
    set_block_timestamp,
    str_to_felt,
    to_wad,
)

MRACParameters = namedtuple(
    "MRACParameters",
    ["u", "r", "y", "theta", "theta_underline", "theta_bar", "gamma", "T"],
)


DEFAULT_MRAC_PARAMETERS = MRACParameters(*[int(i * WAD_SCALE) for i in (0, 1.5, 0, 0, 0, 2, 0.1, 1)])

#
# General fixtures
#


@pytest.fixture(scope="session")
def collect_gas_cost():
    # Global variable
    # gas_info = []
    path = "tests/artifacts/gas.txt"

    # Adds a function call to gas_info
    def add_call(func_name: str, tx_info: StarknetTransactionExecutionInfo, num_storage_keys: int, num_contracts: int):
        gas = estimate_gas(tx_info, num_storage_keys, num_contracts)

        with FileLock(path + ".lock"):
            if Path(path).is_file():
                with open(path, "a") as f:
                    f.write(f"{func_name}: {gas}\n")
            else:
                with open(path, "w") as f:
                    f.write(f"{func_name}: {gas}\n")

    """
    def print_gas():
        print("\n======================================== GAS ESTIMATIONS ========================================")
        for tx in gas_info:
            print(f"{tx[0]}: {tx[1]}")
        print("=================================================================================================")


    request.addfinalizer(print_gas)
    """
    return add_call


@pytest.fixture(autouse=True, scope="session")
def setup():
    getcontext().prec = 18


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


@pytest.fixture
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

    async def create_token(
        name: str,
        symbol: str,
        decimals: int,
        initial_supply: tuple[int, int],
        recipient: int,
    ):
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


#
# Shrine fixtures
#

# Returns the deployed shrine module
@cache
@pytest.fixture
async def shrine_deploy(starknet, users) -> StarknetContract:

    shrine_owner = await users("shrine owner")
    shrine_contract = compile_contract("contracts/shrine/shrine.cairo")

    shrine = await starknet.deploy(
        contract_class=shrine_contract, constructor_calldata=[shrine_owner.address, RAY_SCALE]
    )

    return shrine


# Same as above but also comes with ready-to-use yangs and price feeds
@cache
@pytest.fixture
async def shrine_setup(starknet, users, shrine_deploy) -> StarknetContract:
    shrine = shrine_deploy
    shrine_owner = await users("shrine owner")

    # Set debt ceiling
    await shrine_owner.send_tx(shrine.contract_address, "set_ceiling", [DEBT_CEILING])

    # Creating the yangs
    for i in range(len(YANGS)):
        await shrine_owner.send_tx(
            shrine.contract_address,
            "add_yang",
            [YANGS[i]["address"], YANGS[i]["ceiling"], to_wad(YANGS[i]["start_price"])],
        )  # Add yang
        await shrine_owner.send_tx(
            shrine.contract_address, "set_threshold", [YANGS[i]["address"], YANGS[i]["threshold"]]
        )  # Adding the yang's threshold

    return shrine


@cache
@pytest.fixture
async def shrine(starknet, users, shrine_setup) -> StarknetContract:
    shrine = shrine_setup
    shrine_owner = await users("shrine owner")

    # Creating the price feeds
    feeds = [create_feed(g["start_price"], FEED_LEN, MAX_PRICE_CHANGE) for g in YANGS]

    # Putting the price feeds in the `series` storage variable
    for i in range(FEED_LEN):
        timestamp = i * TIME_INTERVAL
        set_block_timestamp(starknet.state, timestamp)
        for j in range(len(YANGS)):
            await shrine_owner.send_tx(
                shrine.contract_address,
                "advance",
                [YANGS[j]["address"], feeds[j][i]],
            )

        await shrine_owner.send_tx(
            shrine.contract_address,
            "update_multiplier",
            [MULTIPLIER_FEED[i]],
        )

    return shrine
