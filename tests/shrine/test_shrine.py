import pytest

from collections import namedtuple
from decimal import Decimal

from starkware.starkware_utils.error_handling import StarkException
from starkware.starknet.testing.starknet import StarknetContract
from starkware.starknet.testing.objects import StarknetTransactionExecutionInfo
from starkware.starknet.business_logic.state.state import BlockInfo

from utils import (
    assert_event_emitted,
    compile_contract,
)

from random import uniform

#
# Consts
#

TRUE = 1
FALSE = 0

WAD_SCALE = 10**18
RAY_SCALE = 10**27

GAGES = [
    {
        "start_price": 2000,
        "ceiling": 10_000 * WAD_SCALE,
    },
    {
        "start_price": 500,
        "ceiling": 100_000 * WAD_SCALE,
    },
    {"start_price": 1.25, "ceiling": 10_000_000 * WAD_SCALE},
]

FEED_LEN = 20
MAX_PRICE_CHANGE = 0.025
MULTIPLIER_FEED = [RAY_SCALE] * FEED_LEN

SECONDS_PER_MINUTE = 60

DEBT_CEILING = 10_000 * WAD_SCALE
LIQUIDATION_THRESHOLD = 8 * 10**17

#
# Structs
#

Gage = namedtuple("Gage", ["total", "max"])

# Utility functions


def to_wad(n: float):
    return int(n * WAD_SCALE)


# Returns a price feed
def create_feed(start_price: float, length: int, max_change: float) -> list[int]:
    feed = []

    feed.append(start_price)
    for i in range(1, length):
        change = uniform(-max_change, max_change)  # Returns the % change in price (in decimal form, meaning 1% = 0.01)
        feed.append(feed[i - 1] * (1 + change))

    # Scaling the feed before returning so it's ready to use in contracts
    return list(map(to_wad, feed))


def set_block_timestamp(sn, block_timestamp):
    sn.state.block_info = BlockInfo(
        sn.state.block_info.block_number, block_timestamp, sn.state.block_info.gas_price, sequencer_address=None
    )


#
# Fixtures
#

# Returns the deployed shrine module
@pytest.fixture
async def shrine_deploy(starknet, users) -> StarknetContract:

    shrine_owner = await users("shrine owner")
    shrine_contract = compile_contract("contracts/shrine/shrine.cairo")

    shrine = await starknet.deploy(contract_class=shrine_contract, constructor_calldata=[shrine_owner.address])

    return shrine


# Same as above but also comes with ready-to-use gages and price feeds
@pytest.fixture
async def shrine_setup(starknet, users, shrine_deploy) -> StarknetContract:
    shrine = shrine_deploy
    shrine_owner = await users("shrine owner")

    # Set liquidation threshold
    await shrine_owner.send_tx(shrine.contract_address, "set_threshold", [LIQUIDATION_THRESHOLD])

    # Set debt ceiling
    await shrine_owner.send_tx(shrine.contract_address, "set_ceiling", [DEBT_CEILING])

    # Creating the gages
    for g in GAGES:
        await shrine_owner.send_tx(shrine.contract_address, "add_gage", [g["ceiling"]])

    # Creating the price feeds
    feeds = [create_feed(g["start_price"], FEED_LEN, MAX_PRICE_CHANGE) for g in GAGES]

    # Putting the price feeds in the `series` storage variable
    for i in range(FEED_LEN):
        timestamp = i * 30 * SECONDS_PER_MINUTE
        set_block_timestamp(starknet.state, timestamp)
        for j in range(len(GAGES)):
            await shrine_owner.send_tx(shrine.contract_address, "advance", [j, feeds[j][i], timestamp])

        await shrine_owner.send_tx(shrine.contract_address, "update_multiplier", [MULTIPLIER_FEED[i], timestamp])

    return shrine


@pytest.fixture
async def shrine_deposit(users, shrine_setup) -> StarknetTransactionExecutionInfo:
    shrine = shrine_setup
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    deposit = await shrine_owner.send_tx(shrine.contract_address, "deposit", [0, to_wad(10), shrine_user.address, 0])
    return deposit


@pytest.fixture
async def shrine_forge(users, shrine_setup, shrine_deposit) -> StarknetTransactionExecutionInfo:
    shrine = shrine_setup
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    forge = await shrine_owner.send_tx(shrine.contract_address, "forge", [shrine_user.address, 0, to_wad(5000)])
    return forge


@pytest.fixture
async def shrine_melt(users, shrine_setup, shrine_forge) -> StarknetTransactionExecutionInfo:
    shrine = shrine_setup
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    melt = await shrine_owner.send_tx(shrine.contract_address, "melt", [shrine_user.address, 0, to_wad(5000)])
    return melt


@pytest.fixture
async def shrine_withdrawal(users, shrine_setup, shrine_deposit) -> StarknetTransactionExecutionInfo:
    shrine = shrine_setup
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    withdrawal = await shrine_owner.send_tx(
        shrine.contract_address, "withdraw", [0, to_wad(10), shrine_user.address, 0]
    )
    return withdrawal


@pytest.fixture
async def update_feeds(users, shrine_setup, shrine_deposit) -> None:
    """
    Additional price feeds for gage 0
    """
    shrine = shrine_setup
    shrine_owner = await users("shrine owner")

    gage0_feed = create_feed(GAGES[0]["start_price"], FEED_LEN, MAX_PRICE_CHANGE)

    for i in range(FEED_LEN):
        # Add offset for initial feeds in `shrine_setup`
        timestamp = (i + FEED_LEN) * 30 * SECONDS_PER_MINUTE

        await shrine_owner.send_tx(shrine.contract_address, "advance", [0, gage0_feed[i], timestamp])
        await shrine_owner.send_tx(shrine.contract_address, "update_multiplier", [MULTIPLIER_FEED[i], timestamp])

    return


#
# Tests
#


@pytest.mark.asyncio
async def test_shrine_setup(shrine_setup):
    shrine = shrine_setup

    # Check system is live
    live = (await shrine.get_live().invoke()).result.live
    assert live == 1

    # Check threshold
    threshold = (await shrine.get_threshold().invoke()).result.threshold
    assert threshold == LIQUIDATION_THRESHOLD

    # Check debt ceiling
    ceiling = (await shrine.get_ceiling().invoke()).result.ceiling
    assert ceiling == DEBT_CEILING

    # Check gage count
    gage_count = (await shrine.get_num_gages().invoke()).result.num
    assert gage_count == 3

    # Check gages

    for idx, g in enumerate(GAGES):
        result_gage = (await shrine.get_gage(idx).invoke()).result.gage
        assert result_gage == Gage(0, g["ceiling"])

    # Check price feeds
    gage0_first_point = (await shrine.get_series(0, 0).invoke()).result.price
    assert gage0_first_point == to_wad(GAGES[0]["start_price"])

    # Check multiplier feed
    multiplier_first_point = (await shrine.get_multiplier(0).invoke()).result.rate
    assert multiplier_first_point == RAY_SCALE


@pytest.mark.asyncio
async def test_auth(shrine_deploy, users):
    shrine = shrine_deploy
    shrine_owner = await users("shrine owner")

    #
    # Auth
    #

    b = await users("2nd owner")
    c = await users("3rd owner")

    # Authorizing an address and testing that it can use authorized functions
    await shrine_owner.send_tx(shrine.contract_address, "authorize", [b.address])
    b_authorized = (await shrine.get_auth(b.address).invoke()).result.authorized
    assert b_authorized == TRUE

    await b.send_tx(shrine.contract_address, "authorize", [c.address])
    c_authorized = (await shrine.get_auth(c.address).invoke()).result.authorized
    assert c_authorized == TRUE

    # Revoking an address
    await b.send_tx(shrine.contract_address, "revoke", [c.address])
    c_authorized = (await shrine.get_auth(c.address).invoke()).result.authorized
    assert c_authorized == FALSE

    # Calling an authorized function with an unauthorized address - should fail
    with pytest.raises(StarkException):
        await c.send_tx(shrine.contract_address, "revoke", [b.address])


@pytest.mark.asyncio
async def test_shrine_deposit(shrine_setup, users, shrine_deposit):
    shrine = shrine_setup

    shrine_user = await users("shrine user")

    assert_event_emitted(
        shrine_deposit,
        shrine.contract_address,
        "GageTotalUpdated",
        [0, to_wad(10)],
    )
    assert_event_emitted(
        shrine_deposit,
        shrine.contract_address,
        "DepositUpdated",
        [shrine_user.address, 0, 0, to_wad(10)],
    )

    gage = (await shrine.get_gage(0).invoke()).result.gage
    assert gage.total == to_wad(10)

    amt = (await shrine.get_deposit(shrine_user.address, 0, 0).invoke()).result.amount
    assert amt == to_wad(10)


@pytest.mark.asyncio
async def test_shrine_withdrawal_pass(shrine_setup, users, shrine_withdrawal):
    shrine = shrine_setup

    shrine_user = await users("shrine user")

    assert_event_emitted(
        shrine_withdrawal,
        shrine.contract_address,
        "GageTotalUpdated",
        [0, 0],
    )
    assert_event_emitted(
        shrine_withdrawal,
        shrine.contract_address,
        "DepositUpdated",
        [shrine_user.address, 0, 0, 0],
    )

    gage = (await shrine.get_gage(0).invoke()).result.gage
    assert gage.total == 0

    amt = (await shrine.get_deposit(shrine_user.address, 0, 0).invoke()).result.amount
    assert amt == 0

    ltv = (await shrine.trove_ratio_current(shrine_user.address, 0).invoke()).result.ratio
    assert ltv == 0

    is_healthy = (await shrine.is_healthy(shrine_user.address, 0).invoke()).result.healthy
    assert is_healthy == 1


@pytest.mark.asyncio
async def test_shrine_forge_pass(shrine_setup, users, shrine_forge):
    shrine = shrine_setup

    shrine_user = await users("shrine user")

    assert_event_emitted(
        shrine_forge,
        shrine.contract_address,
        "SyntheticTotalUpdated",
        [to_wad(5000)],
    )

    # TODO: Failing due to incorrect time interval/ID

    assert_event_emitted(
        shrine_forge,
        shrine.contract_address,
        "TroveUpdated",
        [shrine_user.address, 0, FEED_LEN - 1, to_wad(5000)],
    )

    system_debt = (await shrine.get_synthetic().invoke()).result.total
    assert system_debt == to_wad(5000)

    user_trove = (await shrine.get_trove(shrine_user.address, 0).invoke()).result.trove
    assert user_trove.debt == to_wad(5000)

    gage0_price = (await shrine.gage_last_price(0).invoke()).result.price
    shrine_ltv = (await shrine.trove_ratio_current(shrine_user.address, 0).invoke()).result.ratio
    expected_ltv = (Decimal(5000 * WAD_SCALE) / Decimal(10 * gage0_price)) * RAY_SCALE
    assert shrine_ltv == expected_ltv

    healthy = (await shrine.is_healthy(shrine_user.address, 0).invoke()).result.healthy
    assert healthy == 1


@pytest.mark.asyncio
async def test_shrine_melt_pass(shrine_setup, users, shrine_melt):
    shrine = shrine_setup

    shrine_user = await users("shrine user")

    assert_event_emitted(
        shrine_melt,
        shrine.contract_address,
        "SyntheticTotalUpdated",
        [0],
    )
    assert_event_emitted(
        shrine_melt,
        shrine.contract_address,
        "TroveUpdated",
        [shrine_user.address, 0, FEED_LEN - 1, 0],
    )

    system_debt = (await shrine.get_synthetic().invoke()).result.total
    assert system_debt == 0

    user_trove = (await shrine.get_trove(shrine_user.address, 0).invoke()).result.trove
    assert user_trove.debt == 0

    shrine_ltv = (await shrine.trove_ratio_current(shrine_user.address, 0).invoke()).result.ratio
    assert shrine_ltv == 0

    healthy = (await shrine.is_healthy(shrine_user.address, 0).invoke()).result.healthy
    assert healthy == 1


@pytest.mark.asyncio
async def test_charge(shrine_setup, users, shrine_forge, update_feeds):
    shrine = shrine_setup

    shrine_user = await users("shrine user")

    trove = (await shrine.get_trove(shrine_user.address, 0).invoke()).result.trove
    assert trove.last == 19

    # TODO Call `charge`, and assert updated debt is correct


@pytest.mark.asyncio
async def test_add_gage(shrine_setup, users):
    shrine_owner = await users("shrine owner")
    shrine = shrine_setup

    g_count = len(GAGES)
    assert (await shrine.get_num_gages().invoke()).result.num == g_count

    new_gage_max = 42_000 * WAD_SCALE
    tx = await shrine_owner.send_tx(shrine.contract_address, "add_gage", [new_gage_max])
    assert (await shrine.get_num_gages().invoke()).result.num == g_count + 1
    assert_event_emitted(tx, shrine.contract_address, "GageAdded", [g_count, new_gage_max])
    assert_event_emitted(tx, shrine.contract_address, "NumGagesUpdated", [g_count + 1])

    bad_guy = await users("bad guy")
    with pytest.raises(StarkException):
        await bad_guy.send_tx(shrine.contract_address, "add_gage", [1])


@pytest.mark.asyncio
async def test_update_gage_max(shrine_setup, users):
    shrine_owner = await users("shrine owner")
    shrine = shrine_setup

    gage_id = 0
    orig_gage = (await shrine.get_gage(gage_id).invoke()).result.gage

    async def update_and_assert(new_gage_max):
        tx = await shrine_owner.send_tx(shrine.contract_address, "update_gage_max", [gage_id, new_gage_max])
        assert_event_emitted(tx, shrine.contract_address, "GageMaxUpdated", [gage_id, new_gage_max])

        updated_gage = (await shrine.get_gage(gage_id).invoke()).result.gage
        assert updated_gage.total == orig_gage.total
        assert updated_gage.max == new_gage_max

    # test increasing the max
    new_gage_max = orig_gage.max * 2
    await update_and_assert(new_gage_max)

    # test decreasing the max
    new_gage_max = orig_gage.max - 1
    await update_and_assert(new_gage_max)

    # test decreasing the max below gage.total
    # to do so, we first need to deposit into it (TODO)
    # TODO: also try to deposit after the max change, should fail

    # test calling with a non-existing gage_id
    # faux_gage_id = 7890
    # with pytest.raises(StarkException):
    #     await shrine_owner.send_tx(shrine.contract_address, "update_gage_max", [faux_gage_id, new_gage_max])

    # test calling the func unauthorized
    bad_guy = await users("bad guy")
    with pytest.raises(StarkException):
        await bad_guy.send_tx(shrine.contract_address, "update_gage_max", [0, 2**251])
