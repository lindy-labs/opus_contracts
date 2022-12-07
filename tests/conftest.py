import asyncio
from collections import namedtuple
from decimal import getcontext
from typing import Awaitable, Callable

import pytest
from filelock import FileLock
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.objects import StarknetCallInfo
from starkware.starknet.testing.starknet import Starknet

from tests.oracle.constants import (
    EMPIRIC_FRESHNESS_THRESHOLD,
    EMPIRIC_SOURCES_THRESHOLD,
    EMPIRIC_UPDATE_INTERVAL,
    INIT_BLOCK_TS,
)
from tests.roles import ShrineRoles
from tests.shrine.constants import (
    DEBT_CEILING,
    FEED_LEN,
    FORGE_AMT_WAD,
    INITIAL_DEPOSIT,
    MAX_PRICE_CHANGE,
    MULTIPLIER_FEED,
    SHRINE_FULL_ACCESS,
    YANG1_ADDRESS,
    YANGS,
    YIN_NAME,
    YIN_SYMBOL,
)
from tests.utils import (
    EMPIRIC_OWNER,
    GATE_OWNER,
    GATE_ROLE_FOR_SENTINEL,
    RAY_PERCENT,
    SENTINEL_OWNER,
    SENTINEL_ROLE_FOR_ABBOT,
    SHRINE_OWNER,
    TIME_INTERVAL,
    TROVE1_OWNER,
    TROVE2_OWNER,
    TROVE_1,
    WAD_DECIMALS,
    WAD_SCALE,
    WBTC_DECIMALS,
    Uint256,
    YangConfig,
    compile_code,
    compile_contract,
    create_feed,
    estimate_gas,
    get_contract_code_with_replacement,
    max_approve,
    set_block_timestamp,
    str_to_felt,
    to_fixed_point,
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
    ):
        name = str_to_felt(name)
        symbol = str_to_felt(symbol)
        token = await starknet.deploy(
            contract_class=contract,
            constructor_calldata=[name, symbol, decimals],
        )
        return token

    return create_token


@pytest.fixture
def gates(
    starknet: Starknet,
) -> Callable[[StarknetContract, StarknetContract], Awaitable[StarknetContract]]:
    """
    A factory fixture that creates a Gate (without tax and auto-compounding)
    for a given ERC20 token.

    The returned factory function requires 2 input arguments to deploy
    a new token:
        shrine (deployed StarknetContract instance of Shrine)
        token (deployed StarknetContract instance of token)

    It returns an instance of StarknetContract.
    """
    contract = compile_contract("contracts/gate/rebasing_yang/gate.cairo")

    async def create_gate(shrine: StarknetContract, token: StarknetContract):
        gate = await starknet.deploy(
            contract_class=contract,
            constructor_calldata=[GATE_OWNER, shrine.contract_address, token.contract_address],
        )
        return gate

    return create_gate


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
    shrine_code = get_contract_code_with_replacement(
        "contracts/shrine/shrine.cairo",
        # Append `@view` decorator to internal functions for testing
        {
            "func get_avg_price": "@view\nfunc get_avg_price",
            "func get_avg_multiplier": "@view\nfunc get_avg_multiplier",
            "func get_trove{": "@view\nfunc get_trove{",
        },
    )

    shrine_contract = compile_code(shrine_code)

    shrine = await starknet.deploy(
        contract_class=shrine_contract, constructor_calldata=[SHRINE_OWNER, YIN_NAME, YIN_SYMBOL]
    )

    # Grant shrine owner all roles
    await shrine.grant_role(SHRINE_FULL_ACCESS, SHRINE_OWNER).execute(caller_address=SHRINE_OWNER)

    return shrine


# Same as above but also comes with ready-to-use yangs and price feeds
@pytest.fixture
async def shrine_setup(starknet: Starknet, shrine_deploy) -> StarknetContract:
    shrine = shrine_deploy

    # Setting block timestamp to interval 1, because add_yang assigns the initial
    # price to current interval - 1 (i.e. 0 in this case)
    set_block_timestamp(starknet, TIME_INTERVAL)

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

        await shrine.set_multiplier(MULTIPLIER_FEED[i]).execute(caller_address=SHRINE_OWNER)

    return shrine, feeds


@pytest.fixture
async def shrine(shrine_with_feeds) -> StarknetContract:
    shrine, feeds = shrine_with_feeds
    return shrine


@pytest.fixture
async def shrine_deposit(shrine) -> StarknetCallInfo:
    deposit = await shrine.deposit(YANG1_ADDRESS, TROVE_1, to_wad(INITIAL_DEPOSIT)).execute(caller_address=SHRINE_OWNER)
    return deposit


@pytest.fixture
async def shrine_forge(shrine, shrine_deposit) -> StarknetCallInfo:
    forge = await shrine.forge(TROVE1_OWNER, TROVE_1, FORGE_AMT_WAD).execute(caller_address=SHRINE_OWNER)
    return forge


#
# Abbot
#


@pytest.fixture
async def abbot(starknet, shrine_deploy, sentinel) -> StarknetContract:
    shrine = shrine_deploy
    abbot_contract = compile_contract("contracts/abbot/abbot.cairo")
    abbot = await starknet.deploy(
        contract_class=abbot_contract,
        constructor_calldata=[shrine.contract_address, sentinel.contract_address],
    )

    # auth Abbot in Shrine
    roles = ShrineRoles.DEPOSIT + ShrineRoles.WITHDRAW + ShrineRoles.FORGE + ShrineRoles.MELT
    await shrine.grant_role(roles, abbot.contract_address).execute(caller_address=SHRINE_OWNER)

    # auth Abbot in Sentinel
    await sentinel.grant_role(SENTINEL_ROLE_FOR_ABBOT, abbot.contract_address).execute(caller_address=SENTINEL_OWNER)

    return abbot


#
# Collateral
#


@pytest.fixture
async def steth_token(tokens) -> StarknetContract:
    return await tokens("Lido Staked ETH", "stETH", WAD_DECIMALS)


@pytest.fixture
async def doge_token(tokens) -> StarknetContract:
    return await tokens("Dogecoin", "DOGE", WAD_DECIMALS)


@pytest.fixture
async def wbtc_token(tokens) -> StarknetContract:
    return await tokens("Wrapped BTC", "WBTC", WBTC_DECIMALS)


#
# Yang
#


@pytest.fixture
def steth_yang(steth_token, steth_gate) -> YangConfig:
    ceiling = to_wad(1_000_000)
    threshold = 80 * RAY_PERCENT
    price_wad = to_wad(2000)
    return YangConfig(
        steth_token.contract_address, WAD_DECIMALS, ceiling, threshold, price_wad, steth_gate.contract_address
    )


@pytest.fixture
def doge_yang(doge_token, doge_gate) -> YangConfig:
    ceiling = to_wad(100_000_000)
    threshold = 20 * RAY_PERCENT
    price_wad = to_wad(0.07)
    return YangConfig(
        doge_token.contract_address, WAD_DECIMALS, ceiling, threshold, price_wad, doge_gate.contract_address
    )


@pytest.fixture
def wbtc_yang(wbtc_token, wbtc_gate) -> YangConfig:
    ceiling = to_wad(1_000)
    threshold = 80 * RAY_PERCENT
    price_wad = to_wad(10_000)
    return YangConfig(
        wbtc_token.contract_address, WBTC_DECIMALS, ceiling, threshold, price_wad, wbtc_gate.contract_address
    )


#
# Gate
#


@pytest.fixture
async def steth_gate(starknet, abbot, sentinel, shrine_deploy, steth_token, gates) -> StarknetContract:
    gate = await gates(shrine_deploy, steth_token)

    # auth Sentinel in Gate
    await gate.grant_role(GATE_ROLE_FOR_SENTINEL, sentinel.contract_address).execute(caller_address=GATE_OWNER)

    return gate


@pytest.fixture
async def doge_gate(starknet, abbot, sentinel, shrine_deploy, doge_token, gates) -> StarknetContract:
    gate = await gates(shrine_deploy, doge_token)

    # auth Sentinel in Gate
    await gate.grant_role(GATE_ROLE_FOR_SENTINEL, sentinel.contract_address).execute(caller_address=GATE_OWNER)

    return gate


@pytest.fixture
async def wbtc_gate(starknet, abbot, sentinel, shrine_deploy, wbtc_token, gates) -> StarknetContract:
    gate = await gates(shrine_deploy, wbtc_token)

    # auth Sentinel in Gate
    await gate.grant_role(GATE_ROLE_FOR_SENTINEL, sentinel.contract_address).execute(caller_address=GATE_OWNER)

    return gate


#
# Yin
#


@pytest.fixture
async def yin(starknet, shrine) -> StarknetContract:

    # Deploying the yin contract
    yin_contract = compile_contract("contracts/yin/yin.cairo")
    deployed_yin = await starknet.deploy(
        contract_class=yin_contract,
        constructor_calldata=[str_to_felt("Cash"), str_to_felt("CASH"), 18, shrine.contract_address],
    )

    # Authorizing the yin contract to call `move_yin` and perform flash minting in Shrine
    roles = ShrineRoles.MOVE_YIN + ShrineRoles.FLASH_MINT
    await shrine.grant_role(roles, deployed_yin.contract_address).execute(caller_address=SHRINE_OWNER)

    return deployed_yin


#
# Empiric oracle
#


@pytest.fixture
async def mock_empiric_impl(starknet) -> StarknetContract:
    contract = compile_contract("tests/oracle/mock_empiric.cairo")
    return await starknet.deploy(contract_class=contract)


@pytest.fixture
async def empiric(starknet, shrine, sentinel, mock_empiric_impl) -> StarknetContract:
    set_block_timestamp(starknet, INIT_BLOCK_TS)
    contract = compile_contract("contracts/oracle/empiric.cairo")
    empiric = await starknet.deploy(
        contract_class=contract,
        constructor_calldata=[
            EMPIRIC_OWNER,
            mock_empiric_impl.contract_address,
            shrine.contract_address,
            sentinel.contract_address,
            EMPIRIC_UPDATE_INTERVAL,
            EMPIRIC_FRESHNESS_THRESHOLD,
            EMPIRIC_SOURCES_THRESHOLD,
        ],
    )

    await shrine.grant_role(ShrineRoles.ADVANCE, empiric.contract_address).execute(caller_address=SHRINE_OWNER)

    return empiric


#
# Funded user account and trove (stETH and DOGE)
#


@pytest.fixture
async def funded_trove1_owner(
    steth_token, steth_yang: YangConfig, doge_token, doge_yang: YangConfig, wbtc_token, wbtc_yang: YangConfig
):
    # fund the user with bags
    await steth_token.mint(TROVE1_OWNER, (to_wad(1_000), 0)).execute(caller_address=TROVE1_OWNER)
    await doge_token.mint(TROVE1_OWNER, (to_wad(1_000_000), 0)).execute(caller_address=TROVE1_OWNER)
    await wbtc_token.mint(TROVE1_OWNER, (to_fixed_point(10, WBTC_DECIMALS), 0)).execute(caller_address=TROVE1_OWNER)

    # user approves Aura gates to spend bags
    await max_approve(steth_token, TROVE1_OWNER, steth_yang.gate_address)
    await max_approve(doge_token, TROVE1_OWNER, doge_yang.gate_address)
    await max_approve(wbtc_token, TROVE1_OWNER, wbtc_yang.gate_address)


@pytest.fixture
async def funded_trove2_owner(
    steth_token, steth_yang: YangConfig, doge_token, doge_yang: YangConfig, wbtc_token, wbtc_yang: YangConfig
):
    # fund the user with bags
    await steth_token.mint(TROVE2_OWNER, (to_wad(1_000), 0)).execute(caller_address=TROVE2_OWNER)
    await doge_token.mint(TROVE2_OWNER, (to_wad(1_000_000), 0)).execute(caller_address=TROVE2_OWNER)
    await wbtc_token.mint(TROVE2_OWNER, (to_fixed_point(10, WBTC_DECIMALS), 0)).execute(caller_address=TROVE2_OWNER)

    # user approves Aura gates to spend bags
    await max_approve(steth_token, TROVE2_OWNER, steth_yang.gate_address)
    await max_approve(doge_token, TROVE2_OWNER, doge_yang.gate_address)
    await max_approve(wbtc_token, TROVE2_OWNER, wbtc_yang.gate_address)


@pytest.fixture
async def sentinel(starknet, shrine_deploy) -> StarknetContract:
    shrine = shrine_deploy
    contract = compile_contract("contracts/sentinel/sentinel.cairo")

    sentinel = await starknet.deploy(
        contract_class=contract, constructor_calldata=[SENTINEL_OWNER, shrine.contract_address]
    )

    # Authorize Sentinel in Shrine
    await shrine.grant_role(ShrineRoles.ADD_YANG + ShrineRoles.SET_THRESHOLD, sentinel.contract_address).execute(
        caller_address=SHRINE_OWNER
    )

    return sentinel


@pytest.fixture
async def sentinel_with_yangs(starknet, sentinel, steth_yang, doge_yang, wbtc_yang) -> StarknetContract:
    # Setting block timestamp to interval 1, because add_yang assigns the initial
    # price to current interval - 1 (i.e. 0 in this case)
    set_block_timestamp(starknet, TIME_INTERVAL)

    for yang in (steth_yang, doge_yang, wbtc_yang):
        await sentinel.add_yang(
            yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address
        ).execute(caller_address=SENTINEL_OWNER)

    return sentinel
