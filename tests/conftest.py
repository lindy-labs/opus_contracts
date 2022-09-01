import asyncio
from collections import namedtuple
from decimal import getcontext
from typing import Awaitable, Callable

import pytest
from filelock import FileLock
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.objects import StarknetCallInfo
from starkware.starknet.testing.starknet import Starknet

from tests.gate.rebasing_yang.constants import INITIAL_AMT
from tests.roles import AbbotRoles, ShrineRoles
from tests.shrine.constants import (
    DEBT_CEILING,
    FEED_LEN,
    FORGE_AMT_WAD,
    INITIAL_DEPOSIT,
    MAX_PRICE_CHANGE,
    MULTIPLIER_FEED,
    SHRINE_FULL_ACCESS,
    TIME_INTERVAL,
    YANG_0_ADDRESS,
    YANGS,
)
from tests.utils import (
    ABBOT_OWNER,
    ABBOT_ROLE,
    AURA_USER,
    DOGE_OWNER,
    GATE_OWNER,
    RAY_PERCENT,
    SHRINE_OWNER,
    STETH_OWNER,
    TROVE1_OWNER,
    TROVE2_OWNER,
    TROVE_1,
    WAD_SCALE,
    Uint256,
    YangConfig,
    compile_contract,
    create_feed,
    estimate_gas,
    max_approve,
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
        tx_info: StarknetCallInfo,
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
    request,
    starknet: Starknet,
) -> Callable[[str, str, int, Uint256, int], Awaitable[StarknetContract]]:
    """
    A factory fixture that creates a mock ERC20 token.

    The returned factory function requires 5 input arguments to deploy
    a new token: name (str), symbol (str), decimals (int),
    initial supply (Uint256) and recipient (int). It returns an instance
    of StarknetContract.
    """
    contract = compile_contract("tests/mocks/ERC20.cairo", request)

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
async def usda(request, starknet: Starknet) -> StarknetContract:
    owner = str_to_felt("usda owner")
    contract = compile_contract("contracts/USDa/USDa.cairo", request)
    return await starknet.deploy(contract_class=contract, constructor_calldata=[owner])


@pytest.fixture
async def mrac_controller(request, starknet: Starknet) -> StarknetContract:
    contract = compile_contract("contracts/MRAC/controller.cairo", request)
    return await starknet.deploy(contract_class=contract, constructor_calldata=[*DEFAULT_MRAC_PARAMETERS])


#
# Shrine fixtures
#

# Returns the deployed shrine module
@pytest.fixture
async def shrine_deploy(request, starknet: Starknet) -> StarknetContract:
    shrine_contract = compile_contract("contracts/shrine/shrine.cairo", request)

    shrine = await starknet.deploy(contract_class=shrine_contract, constructor_calldata=[SHRINE_OWNER])

    # Grant shrine owner all roles
    await shrine.grant_role(SHRINE_FULL_ACCESS, SHRINE_OWNER).execute(caller_address=SHRINE_OWNER)

    return shrine


# Same as above but also comes with ready-to-use yangs and price feeds
@pytest.fixture
async def shrine_setup(shrine_deploy) -> StarknetContract:
    shrine = shrine_deploy
    # Set debt ceiling
    await shrine.set_ceiling(DEBT_CEILING).execute(caller_address=SHRINE_OWNER)
    # Creating the yangs
    for i in range(len(YANGS)):
        await shrine.add_yang(
            YANGS[i]["address"], YANGS[i]["ceiling"], YANGS[i]["threshold"], to_wad(YANGS[i]["start_price"])
        ).execute(caller_address=SHRINE_OWNER)

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
        set_block_timestamp(starknet, timestamp)

        for j in range(len(YANGS)):
            await shrine.advance(YANGS[j]["address"], feeds[j][i]).execute(caller_address=SHRINE_OWNER)

        await shrine.update_multiplier(MULTIPLIER_FEED[i]).execute(caller_address=SHRINE_OWNER)

    return shrine, feeds


@pytest.fixture
async def shrine(shrine_with_feeds) -> StarknetContract:
    shrine, feeds = shrine_with_feeds
    return shrine


@pytest.fixture
async def shrine_deposit(shrine) -> StarknetCallInfo:
    deposit = await shrine.deposit(YANG_0_ADDRESS, TROVE_1, to_wad(INITIAL_DEPOSIT)).execute(
        caller_address=SHRINE_OWNER
    )
    return deposit


@pytest.fixture
async def shrine_forge(shrine, shrine_deposit) -> StarknetCallInfo:
    forge = await shrine.forge(TROVE1_OWNER, TROVE_1, FORGE_AMT_WAD).execute(caller_address=SHRINE_OWNER)
    return forge


#
# Abbot
#


@pytest.fixture
async def abbot(request, starknet, shrine_deploy) -> StarknetContract:
    shrine = shrine_deploy
    abbot_contract = compile_contract("contracts/abbot/abbot.cairo", request)
    abbot = await starknet.deploy(
        contract_class=abbot_contract, constructor_calldata=[shrine.contract_address, ABBOT_OWNER]
    )

    # auth Abbot in Shrine
    # TODO: eventually remove ADD_YANG and SET_THRESHOLD from the Abbot
    #       https://github.com/lindy-labs/aura_contracts/issues/105
    roles = ShrineRoles.FORGE + ShrineRoles.MELT + ShrineRoles.ADD_YANG + ShrineRoles.SET_THRESHOLD
    await shrine.grant_role(roles, abbot.contract_address).execute(caller_address=SHRINE_OWNER)

    # allow ABBOT_OWNER to call add_yang
    await abbot.grant_role(AbbotRoles.ADD_YANG.value, ABBOT_OWNER).execute(caller_address=ABBOT_OWNER)

    return abbot


@pytest.fixture
async def abbot_with_yangs(abbot, steth_yang: YangConfig, doge_yang: YangConfig):
    for yang in (steth_yang, doge_yang):
        await abbot.add_yang(
            yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address
        ).execute(caller_address=ABBOT_OWNER)


#
# Collateral
#


@pytest.fixture
async def rebasing_token(tokens) -> StarknetContract:
    rebasing_token = await tokens("Rebasing Token", "RT", 18, (INITIAL_AMT, 0), TROVE1_OWNER)

    await rebasing_token.mint(TROVE2_OWNER, (INITIAL_AMT, 0)).execute(caller_address=TROVE2_OWNER)

    return rebasing_token


@pytest.fixture
async def steth_token(tokens) -> StarknetContract:
    return await tokens("Lido Staked ETH", "stETH", 18, (to_wad(100_000), 0), STETH_OWNER)


@pytest.fixture
async def doge_token(tokens) -> StarknetContract:
    return await tokens("Dogecoin", "DOGE", 18, (to_wad(10_000_000), 0), DOGE_OWNER)


#
# Yang
#


@pytest.fixture
def steth_yang(steth_token, steth_gate) -> YangConfig:
    ceiling = to_wad(1_000_000)
    threshold = 90 * RAY_PERCENT
    price_wad = to_wad(2000)
    return YangConfig(steth_token.contract_address, ceiling, threshold, price_wad, steth_gate.contract_address)


@pytest.fixture
def doge_yang(doge_token, doge_gate) -> YangConfig:
    ceiling = to_wad(100_000_000)
    threshold = 20 * RAY_PERCENT
    price_wad = to_wad(0.07)
    return YangConfig(doge_token.contract_address, ceiling, threshold, price_wad, doge_gate.contract_address)


#
# Gate
#


@pytest.fixture
async def steth_gate(request, starknet, abbot, shrine_deploy, steth_token) -> StarknetContract:
    """
    Deploys an instance of the Gate module, without any autocompounding or tax.
    """
    shrine = shrine_deploy

    contract = compile_contract("contracts/gate/rebasing_yang/gate.cairo", request)

    gate = await starknet.deploy(
        contract_class=contract,
        constructor_calldata=[
            GATE_OWNER,
            shrine.contract_address,
            steth_token.contract_address,
        ],
    )

    # auth Abbot in Gate
    await gate.grant_role(ABBOT_ROLE, abbot.contract_address).execute(caller_address=GATE_OWNER)

    # auth Gate in Shrine
    roles = ShrineRoles.DEPOSIT + ShrineRoles.WITHDRAW
    await shrine.grant_role(roles, gate.contract_address).execute(caller_address=SHRINE_OWNER)

    return gate


@pytest.fixture
async def doge_gate(request, starknet, abbot, shrine_deploy, doge_token) -> StarknetContract:
    """
    Deploys an instance of the Gate module, without any autocompounding or tax.
    """
    shrine = shrine_deploy

    contract = compile_contract("contracts/gate/rebasing_yang/gate.cairo", request)
    gate = await starknet.deploy(
        contract_class=contract,
        constructor_calldata=[
            GATE_OWNER,
            shrine.contract_address,
            doge_token.contract_address,
        ],
    )

    # auth Abbot in Gate
    await gate.grant_role(ABBOT_ROLE, abbot.contract_address).execute(caller_address=GATE_OWNER)

    # auth Gate in Shrine
    roles = ShrineRoles.DEPOSIT + ShrineRoles.WITHDRAW
    await shrine.grant_role(roles, gate.contract_address).execute(caller_address=SHRINE_OWNER)

    return gate


#
# Yin
#


@pytest.fixture
async def yin(request, starknet, shrine) -> StarknetContract:

    # Deploying the yin contract
    yin_contract = compile_contract("contracts/yin/yin.cairo", request)
    deployed_yin = await starknet.deploy(
        contract_class=yin_contract,
        constructor_calldata=[str_to_felt("USD Aura"), str_to_felt("USDa"), 18, shrine.contract_address],
    )

    # Authorizing the yin contract to call `move_yin` in shrine
    await shrine.grant_role(ShrineRoles.MOVE_YIN, deployed_yin.contract_address).execute(caller_address=SHRINE_OWNER)

    return deployed_yin


#
# Funded user account and trove (stETH and DOGE)
#


@pytest.fixture
async def funded_aura_user(steth_token, steth_yang: YangConfig, doge_token, doge_yang: YangConfig):
    # fund the user with bags
    await steth_token.transfer(AURA_USER, (to_wad(1_000), 0)).execute(caller_address=STETH_OWNER)
    await doge_token.transfer(AURA_USER, (to_wad(1_000_000), 0)).execute(caller_address=DOGE_OWNER)

    # user approves Aura gates to spend bags
    await max_approve(steth_token, AURA_USER, steth_yang.gate_address)
    await max_approve(doge_token, AURA_USER, doge_yang.gate_address)
