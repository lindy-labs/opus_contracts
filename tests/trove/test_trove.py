import pytest

from collections import namedtuple
from decimal import Decimal

from starkware.starkware_utils.error_handling import StarkException
from starkware.starknet.testing.starknet import StarknetContract
from starkware.starknet.testing.objects import StarknetTransactionExecutionInfo

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

SCALE = 10**18

GAGE0_STARTING_PRICE = 2000
GAGE1_STARTING_PRICE = 500
GAGE2_STARTING_PRICE = 1.25

FEED_LEN = 20
MAX_PRICE_CHANGE = 0.025
SECONDS_PER_MINUTE = 60

DEBT_CEILING = 10_000 * SCALE
LIQUIDATION_THRESHOLD = 8 * 10**17

GAGE0_MAX = 10_000 * SCALE
GAGE1_MAX = 100_000 * SCALE
GAGE2_MAX = 10_000_000 * SCALE

#
# Structs
#

Gage = namedtuple("Gage", ["total", "max"])
Point = namedtuple("Point", ["price", "time"])

# Utility functions


def to_wad(n: float):
    return int(n * SCALE)


# Returns a price feed
def create_feed(starting_price: float, length: int, max_change: float) -> list[int]:
    feed = []

    feed.append(starting_price)
    for i in range(1, length):
        change = uniform(-max_change, max_change)  # Returns the % change in price (in decimal form, meaning 1% = 0.01)
        feed.append(feed[i - 1] * (1 + change))

    # Scaling the feed before returning so it's ready to use in contracts
    return list(map(to_wad, feed))


#
# Fixtures
#

# Returns the deployed trove module
@pytest.fixture
async def trove(starknet, users) -> StarknetContract:

    trove_owner = await users("trove owner")
    trove_contract = compile_contract("contracts/trove/trove.cairo")

    trove = await starknet.deploy(contract_def=trove_contract, constructor_calldata=[trove_owner.address])

    return trove


# Same as above but also comes with ready-to-use gages and price feeds
@pytest.fixture
async def trove_setup(users, trove) -> StarknetContract:

    trove_owner = await users("trove owner")

    # Set liquidation threshold
    await trove_owner.send_tx(trove.contract_address, "set_threshold", [LIQUIDATION_THRESHOLD])

    # Set debt ceiling
    await trove_owner.send_tx(trove.contract_address, "set_ceiling", [DEBT_CEILING])

    # Creating the gages
    await trove_owner.send_tx(trove.contract_address, "add_gage", [GAGE0_MAX])
    await trove_owner.send_tx(trove.contract_address, "add_gage", [GAGE1_MAX])
    await trove_owner.send_tx(trove.contract_address, "add_gage", [GAGE2_MAX])

    # Creating the price feeds
    feed0 = create_feed(GAGE0_STARTING_PRICE, FEED_LEN, MAX_PRICE_CHANGE)
    feed1 = create_feed(GAGE1_STARTING_PRICE, FEED_LEN, MAX_PRICE_CHANGE)
    feed2 = create_feed(GAGE2_STARTING_PRICE, FEED_LEN, MAX_PRICE_CHANGE)

    # Putting the price feeds in the `series` storage variable
    for i in range(FEED_LEN):
        await trove_owner.send_tx(
            trove.contract_address,
            "advance",
            [0, feed0[i], i * 30 * SECONDS_PER_MINUTE],
        )
        await trove_owner.send_tx(
            trove.contract_address,
            "advance",
            [1, feed1[i], i * 30 * SECONDS_PER_MINUTE],
        )
        await trove_owner.send_tx(
            trove.contract_address,
            "advance",
            [2, feed2[i], i * 30 * SECONDS_PER_MINUTE],
        )

    return trove


@pytest.fixture
async def trove_deposit(users, trove_setup) -> StarknetTransactionExecutionInfo:
    trove = trove_setup
    trove_owner = await users("trove owner")
    trove_user = await users("trove user")

    deposit = await trove_owner.send_tx(trove.contract_address, "deposit", [0, to_wad(10), trove_user.address, 0])
    return deposit


@pytest.fixture
async def trove_forge(users, trove_setup, trove_deposit) -> StarknetTransactionExecutionInfo:
    trove = trove_setup
    trove_owner = await users("trove owner")
    trove_user = await users("trove user")

    forge = await trove_owner.send_tx(trove.contract_address, "forge", [trove_user.address, 0, to_wad(5000)])
    return forge


@pytest.fixture
async def trove_melt(users, trove_setup, trove_forge) -> StarknetTransactionExecutionInfo:
    trove = trove_setup
    trove_owner = await users("trove owner")
    trove_user = await users("trove user")

    melt = await trove_owner.send_tx(trove.contract_address, "melt", [trove_user.address, 0, to_wad(5000)])
    return melt


@pytest.fixture
async def trove_withdrawal(users, trove_setup, trove_deposit) -> StarknetTransactionExecutionInfo:
    trove = trove_setup
    trove_owner = await users("trove owner")
    trove_user = await users("trove user")

    withdrawal = await trove_owner.send_tx(trove.contract_address, "withdraw", [0, to_wad(10), trove_user.address, 0])
    return withdrawal


#
# Tests
#


@pytest.mark.asyncio
async def test_trove_setup(trove_setup):
    trove = trove_setup

    # Check system is live
    live = (await trove.get_is_live().invoke()).result.is_live
    assert live == 1

    # Check threshold
    threshold = (await trove.get_threshold().invoke()).result.threshold
    assert threshold == LIQUIDATION_THRESHOLD

    # Check debt ceiling
    ceiling = (await trove.get_ceiling().invoke()).result.ceiling
    assert ceiling == DEBT_CEILING

    # Check gage count
    gage_count = (await trove.get_num_gages().invoke()).result.num
    assert gage_count == 3

    # Check gages
    gage0 = (await trove.get_gages(0).invoke()).result.gage
    assert gage0 == Gage(0, GAGE0_MAX)

    gage1 = (await trove.get_gages(1).invoke()).result.gage
    assert gage1 == Gage(0, GAGE1_MAX)

    gage2 = (await trove.get_gages(2).invoke()).result.gage
    assert gage2 == Gage(0, to_wad(10_000_000))

    # Check price feeds
    gage0_first_point = (await trove.get_series(0, 0).invoke()).result.point
    assert gage0_first_point == Point(to_wad(GAGE0_STARTING_PRICE), 0)

    gage0_last_point = (await trove.get_series(0, FEED_LEN - 1).invoke()).result.point
    assert gage0_last_point.time == (FEED_LEN - 1) * 30 * SECONDS_PER_MINUTE

    gage0_null_point = (await trove.get_series(0, FEED_LEN).invoke()).result.point
    assert gage0_null_point == Point(0, 0)

    gage0_series_len = (await trove.get_series_len(0).invoke()).result.len
    assert gage0_series_len == FEED_LEN


@pytest.mark.asyncio
async def test_auth(trove, users):

    trove_owner = await users("trove owner")

    #
    # Auth
    #

    b = await users("2nd owner")
    c = await users("3rd owner")

    # Authorizing an address and testing that it can use authorized functions
    await trove_owner.send_tx(trove.contract_address, "authorize", [b.address])
    b_authorized = (await trove.get_auth(b.address).invoke()).result.is_auth
    assert b_authorized == TRUE

    await b.send_tx(trove.contract_address, "authorize", [c.address])
    c_authorized = (await trove.get_auth(c.address).invoke()).result.is_auth
    assert c_authorized == TRUE

    # Revoking an address
    await b.send_tx(trove.contract_address, "revoke", [c.address])
    c_authorized = (await trove.get_auth(c.address).invoke()).result.is_auth
    assert c_authorized == FALSE

    # Calling an authorized function with an unauthorized address - should fail
    with pytest.raises(StarkException):
        await c.send_tx(trove.contract_address, "revoke", [b.address])


@pytest.mark.asyncio
async def test_trove_deposit(trove_setup, users, trove_deposit):
    trove = trove_setup

    trove_user = await users("trove user")

    assert_event_emitted(
        trove_deposit,
        trove.contract_address,
        "GageTotalUpdated",
        [0, to_wad(10)],
    )
    assert_event_emitted(
        trove_deposit,
        trove.contract_address,
        "DepositUpdated",
        [trove_user.address, 0, 0, to_wad(10)],
    )

    gage = (await trove.get_gages(0).invoke()).result.gage
    assert gage.total == to_wad(10)

    amt = (await trove.get_deposits(trove_user.address, 0, 0).invoke()).result.amount
    assert amt == to_wad(10)


@pytest.mark.asyncio
async def test_trove_withdrawal_pass(trove_setup, users, trove_withdrawal):
    trove = trove_setup

    trove_user = await users("trove user")

    assert_event_emitted(
        trove_withdrawal,
        trove.contract_address,
        "GageTotalUpdated",
        [0, 0],
    )
    assert_event_emitted(
        trove_withdrawal,
        trove.contract_address,
        "DepositUpdated",
        [trove_user.address, 0, 0, 0],
    )

    gage = (await trove.get_gages(0).invoke()).result.gage
    assert gage.total == 0

    amt = (await trove.get_deposits(trove_user.address, 0, 0).invoke()).result.amount
    assert amt == 0

    ltv = (await trove.trove_ratio(trove_user.address, 0).invoke()).result.ratio
    assert ltv == 0

    is_healthy = (await trove.is_healthy(trove_user.address, 0).invoke()).result.healthy
    assert is_healthy == 1


@pytest.mark.asyncio
async def test_trove_forge_pass(trove_setup, users, trove_forge):
    trove = trove_setup

    trove_user = await users("trove user")

    assert_event_emitted(
        trove_forge,
        trove.contract_address,
        "SyntheticTotalUpdated",
        [to_wad(5000)],
    )
    assert_event_emitted(
        trove_forge,
        trove.contract_address,
        "TroveUpdated",
        [trove_user.address, 0, 0, to_wad(5000)],
    )

    system_debt = (await trove.get_synthetic().invoke()).result.amount
    assert system_debt == to_wad(5000)

    user_trove = (await trove.get_troves(trove_user.address, 0).invoke()).result.trove
    assert user_trove.debt == to_wad(5000)

    gage0_price = (await trove.gage_last_price(0).invoke()).result.price
    trove_ltv = (await trove.trove_ratio(trove_user.address, 0).invoke()).result.ratio
    expected_ltv = (Decimal(to_wad(5000)) / (Decimal(to_wad(10)) * gage0_price)) * (SCALE * SCALE)
    assert trove_ltv == expected_ltv

    healthy = (await trove.is_healthy(trove_user.address, 0).invoke()).result.healthy
    assert healthy == 1


@pytest.mark.asyncio
async def test_trove_melt_pass(trove_setup, users, trove_melt):
    trove = trove_setup

    trove_user = await users("trove user")

    assert_event_emitted(
        trove_melt,
        trove.contract_address,
        "SyntheticTotalUpdated",
        [0],
    )
    assert_event_emitted(
        trove_melt,
        trove.contract_address,
        "TroveUpdated",
        [trove_user.address, 0, 0, 0],
    )

    system_debt = (await trove.get_synthetic().invoke()).result.amount
    assert system_debt == 0

    user_trove = (await trove.get_troves(trove_user.address, 0).invoke()).result.trove
    assert user_trove.debt == 0

    trove_ltv = (await trove.trove_ratio(trove_user.address, 0).invoke()).result.ratio
    assert trove_ltv == 0

    healthy = (await trove.is_healthy(trove_user.address, 0).invoke()).result.healthy
    assert healthy == 1
