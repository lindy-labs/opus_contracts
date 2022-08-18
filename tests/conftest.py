import asyncio
from collections import namedtuple
from decimal import getcontext
from typing import Awaitable, Callable

import pytest
from filelock import FileLock
from starkware.starknet.testing.objects import StarknetTransactionExecutionInfo
from starkware.starknet.testing.starknet import Starknet, StarknetContract

from tests.gate.rebasing_yang.constants import INITIAL_AMT
from tests.shrine.constants import (
    DEBT_CEILING,
    FEED_LEN,
    FORGE_AMT,
    INITIAL_DEPOSIT,
    MAX_PRICE_CHANGE,
    MULTIPLIER_FEED,
    SHRINE_OWNER,
    TIME_INTERVAL,
    TROVE_1,
    USER_1,
    YANG_0_ADDRESS,
    YANGS,
)
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
async def starknet_session() -> Starknet:
    starknet = await Starknet.empty()
    return starknet


@pytest.fixture
async def starknet() -> Starknet:
    starknet = await Starknet.empty()
    return starknet


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
async def usda(starknet: Starknet) -> StarknetContract:
    owner = str_to_felt("usda owner")
    contract = compile_contract("contracts/USDa/USDa.cairo")
    return await starknet.deploy(contract_class=contract, constructor_calldata=[owner])


@pytest.fixture
async def mrac_controller(starknet: Starknet) -> StarknetContract:
    contract = compile_contract("contracts/MRAC/controller.cairo")
    return await starknet.deploy(contract_class=contract, constructor_calldata=[*DEFAULT_MRAC_PARAMETERS])


#
# Shrine fixtures
#

# Returns the deployed shrine module
@pytest.fixture
async def shrine_deploy(starknet: Starknet) -> StarknetContract:
    shrine_contract = compile_contract("contracts/shrine/shrine.cairo")

    shrine = await starknet.deploy(contract_class=shrine_contract, constructor_calldata=[SHRINE_OWNER])

    return shrine


# Same as above but also comes with ready-to-use yangs and price feeds
@pytest.fixture
async def shrine_setup(shrine_deploy) -> StarknetContract:
    shrine = shrine_deploy

    # Set debt ceiling
    await shrine.set_ceiling(DEBT_CEILING).invoke(caller_address=SHRINE_OWNER)
    # Creating the yangs
    for i in range(len(YANGS)):
        await shrine.add_yang(
            YANGS[i]["address"], YANGS[i]["ceiling"], YANGS[i]["threshold"], to_wad(YANGS[i]["start_price"])
        ).invoke(caller_address=SHRINE_OWNER)

    return shrine


@pytest.fixture
async def shrine_with_feeds(starknet: Starknet, shrine_setup) -> StarknetContract:
    shrine = shrine_setup

    # Creating the price feeds
    feeds = [create_feed(g["start_price"], FEED_LEN, MAX_PRICE_CHANGE) for g in YANGS]

    # Putting the price feeds in the `shrine_yang_price_storage` storage variable
    # Skipping over the first element in `feeds` since the start price is set in `add_yang`
    for i in range(1, FEED_LEN):
        timestamp = i * TIME_INTERVAL
        set_block_timestamp(starknet.state, timestamp)

        for j in range(len(YANGS)):
            await shrine.advance(YANGS[j]["address"], feeds[j][i]).invoke(caller_address=SHRINE_OWNER)

        await shrine.update_multiplier(MULTIPLIER_FEED[i]).invoke(caller_address=SHRINE_OWNER)

    return shrine, feeds


@pytest.fixture
async def shrine(shrine_with_feeds) -> StarknetContract:
    shrine, feeds = shrine_with_feeds
    return shrine


@pytest.fixture
async def shrine_deposit(shrine) -> StarknetTransactionExecutionInfo:
    deposit = await shrine.deposit(YANG_0_ADDRESS, to_wad(INITIAL_DEPOSIT), TROVE_1).invoke(caller_address=SHRINE_OWNER)
    return deposit


@pytest.fixture
async def shrine_forge(shrine, shrine_deposit) -> StarknetTransactionExecutionInfo:
    forge = await shrine.forge(FORGE_AMT, TROVE_1, USER_1).invoke(caller_address=SHRINE_OWNER)
    return forge


#
# Collateral
#


@pytest.fixture
async def rebasing_token(tokens) -> StarknetContract:
    user1 = str_to_felt("trove 1 owner")
    rebasing_token = await tokens("Rebasing Token", "RT", 18, (INITIAL_AMT, 0), user1)

    user2 = str_to_felt("trove 2 owner")
    await rebasing_token.mint(user2, (INITIAL_AMT, 0)).invoke(caller_address=user2)

    return rebasing_token
