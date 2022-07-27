import asyncio
from collections import namedtuple
from decimal import getcontext
from typing import AsyncIterator, Awaitable, Callable, Tuple

import pytest
from cache import AsyncLRU
from filelock import FileLock
from starkware.starknet.testing.objects import StarknetTransactionExecutionInfo
from starkware.starknet.testing.starknet import Starknet, StarknetContract

from tests.account import Account
from tests.gate.yang.constants import INITIAL_AMT, TAX_RAY
from tests.shrine.constants import DEBT_CEILING, FEED_LEN, MAX_PRICE_CHANGE, MULTIPLIER_FEED, TIME_INTERVAL, YANGS
from tests.utils import (
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
    def add_call(
        func_name: str,
        tx_info: StarknetTransactionExecutionInfo,
        num_storage_keys: int,
        num_contracts: int,
    ):
        gas = estimate_gas(tx_info, num_storage_keys, num_contracts)

        with FileLock(path + ".lock"):
            with open(path, "a") as f:
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
    getcontext().prec = 38


@pytest.fixture(scope="session")
def event_loop():
    return asyncio.new_event_loop()


@pytest.fixture(scope="session")
async def starknet() -> Starknet:
    starknet = await Starknet.empty()
    return starknet


@pytest.fixture
async def starknet_func_scope() -> Starknet:
    starknet = await Starknet.empty()
    return starknet


# TODO: figure out a good way how not to use magic string constants for common users
@pytest.fixture
def users(starknet_func_scope: Starknet) -> Callable[[str], Awaitable[Account]]:
    starknet = starknet_func_scope
    """
    A factory fixture that creates users.

    The returned factory function takes a single string as an argument,
    which it uses as an identifier of the user and also to generates their
    private key. The fixture has an internal cache, so the same argument (user name)
    will return the same result within a given test.

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
    starknet_func_scope: Starknet,
) -> Callable[[str, str, int, Uint256, int], Awaitable[StarknetContract]]:
    starknet = starknet_func_scope
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
async def usda(starknet_func_scope, users) -> StarknetContract:
    starknet = starknet_func_scope
    owner = await users("usda owner")
    contract = compile_contract("contracts/USDa/USDa.cairo")
    return await starknet.deploy(contract_class=contract, constructor_calldata=[owner.address])


@pytest.fixture
async def mrac_controller(starknet_func_scope) -> StarknetContract:
    starknet = starknet_func_scope
    contract = compile_contract("contracts/MRAC/controller.cairo")
    return await starknet.deploy(contract_class=contract, constructor_calldata=[*DEFAULT_MRAC_PARAMETERS])


#
# Shrine fixtures
#

# Returns the deployed shrine module
@pytest.fixture
async def shrine_deploy(starknet_func_scope, users) -> StarknetContract:
    starknet = starknet_func_scope
    shrine_owner = await users("shrine owner")
    shrine_contract = compile_contract("contracts/shrine/shrine.cairo")

    shrine = await starknet.deploy(contract_class=shrine_contract, constructor_calldata=[shrine_owner.address])

    return shrine


# Same as above but also comes with ready-to-use yangs and price feeds
@pytest.fixture
async def shrine_setup(users, shrine_deploy) -> StarknetContract:
    shrine = shrine_deploy
    shrine_owner = await users("shrine owner")

    # Set debt ceiling
    await shrine_owner.send_tx(shrine.contract_address, "set_ceiling", [DEBT_CEILING])

    # Creating the yangs
    for i in range(len(YANGS)):
        await shrine_owner.send_tx(
            shrine.contract_address,
            "add_yang",
            [
                YANGS[i]["address"],
                YANGS[i]["ceiling"],
                YANGS[i]["threshold"],
                to_wad(YANGS[i]["start_price"]),
            ],
        )  # Add yang

    return shrine


@pytest.fixture
async def shrine_with_feeds(starknet_func_scope, users, shrine_setup) -> StarknetContract:
    starknet = starknet_func_scope
    shrine = shrine_setup
    shrine_owner = await users("shrine owner")

    # Creating the price feeds
    feeds = [create_feed(g["start_price"], FEED_LEN, MAX_PRICE_CHANGE) for g in YANGS]

    # Putting the price feeds in the `shrine_yang_price_storage` storage variable
    # Skipping over the first element in `feeds` since the start price is set in `add_yang`
    for i in range(1, FEED_LEN):
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

    return shrine, feeds


@pytest.fixture
async def shrine(shrine_with_feeds) -> StarknetContract:
    shrine, feeds = shrine_with_feeds
    return shrine


#
# Gate fixtures
#


@pytest.fixture
async def gate_rebasing(starknet, shrine, users, tokens) -> AsyncIterator[Tuple[StarknetContract, StarknetContract]]:
    """
    Fixture that deploys an ERC20 (representing a rebasing-type collateral) and
    a Gate for rebasing-type gollateral, and returns deployed instances of both
    `StarknetContract`s.
    """
    user = await users("shrine user")
    underlying = await tokens("Staked ETH", "stETH", 18, (INITIAL_AMT, 0), user.address)

    contract = compile_contract("contracts/gate/yang/gate_rebasing.cairo")
    abbot = await users("abbot")
    tax_collector = await users("tax collector")
    gate = await starknet.deploy(
        contract_class=contract,
        constructor_calldata=[
            abbot.address,
            shrine.contract_address,
            underlying.contract_address,
            TAX_RAY,
            tax_collector.address,
        ],
    )
    yield underlying, gate
