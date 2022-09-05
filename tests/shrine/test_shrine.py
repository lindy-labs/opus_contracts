from collections import namedtuple
from decimal import Decimal
from math import exp
from typing import List, Tuple

import pytest
from starkware.starknet.testing.objects import StarknetTransactionExecutionInfo
from starkware.starkware_utils.error_handling import StarkException

from tests.shrine.constants import *  # noqa: F403
from tests.utils import (
    BAD_GUY,
    FALSE,
    RAY_PERCENT,
    RAY_SCALE,
    SHRINE_OWNER,
    TROVE1_OWNER,
    TROVE2_OWNER,
    TRUE,
    WAD_SCALE,
    assert_equalish,
    assert_event_emitted,
    create_feed,
    from_ray,
    from_wad,
    get_block_timestamp,
    price_bounds,
    set_block_timestamp,
    signed_int_to_felt,
    str_to_felt,
    to_wad,
)

#
# Structs
#

Yang = namedtuple("Yang", ["total", "max"])


def linear(x: Decimal, m: Decimal, b: Decimal) -> Decimal:
    """
    Helper function for y = m*x + b

    Arguments
    ---------
    x : Decimal
        Value of x.
    m : Decimal
        Value of m.
    b : Decimal
        Value of b.

    Returns
    -------
    Value of the given equation in Decimal.
    """
    return (m * x) + b


def base_rate(ltv: Decimal) -> Decimal:
    """
    Helper function to calculate base rate given loan-to-threshold-value ratio.

    Arguments
    ---------
    ltv : Decimal
        Loan-to-threshold-value ratio in Decimal

    Returns
    -------
    Value of the base rate in Decimal.
    """
    if ltv <= RATE_BOUND1:
        return linear(ltv, RATE_M1, RATE_B1)
    elif ltv <= RATE_BOUND2:
        return linear(ltv, RATE_M2, RATE_B2)
    elif ltv <= RATE_BOUND3:
        return linear(ltv, RATE_M3, RATE_B3)
    return linear(ltv, RATE_M4, RATE_B4)


def compound(
    yangs_amt: List[Decimal],
    yangs_thresholds: List[Decimal],
    yangs_cumulative_prices_start: List[Decimal],
    yangs_cumulative_prices_end: List[Decimal],
    cumulative_multiplier_start: Decimal,
    cumulative_multiplier_end: Decimal,
    start_interval: int,
    end_interval: int,
    debt: Decimal,
) -> Decimal:
    """
    Helper function to calculate the compounded debt.

    Arguments
    ---------
    yangs_amt : List[Decimal]
        Ordered list of the amount of each Yang
    yangs_thresholds : List[Decimal]
        Ordered list of the threshold for each Yang
    yang_cumulative_prices_start: List[Decimal]
        The cumulative price of each yang at the start of the interest accumulation period
    yang_cumulative_prices_end: List[Decimal]
        The cumulative price of each yang at the end of the interest accumulation period
    cumulative_multiplier_start : Decimal
        The cumulative multiplier at the start of the interest accumulation period
    cumulative_multiplier_end : Decimal
        The cumulative multiplier at the end of the interest accumulation period
    debt : Decimal
        Amount of debt at the start interval

    Returns
    -------
    Value of the compounded debt from start interval to end interval in Decimal
    """

    # Sanity check on input data
    assert (
        len(yangs_amt)
        == len(yangs_cumulative_prices_start)
        == len(yangs_cumulative_prices_end)
        == len(yangs_thresholds)
    )

    intervals_elapsed = Decimal(end_interval - start_interval)
    cumulative_weighted_threshold = Decimal("0")
    for i in range(len(yangs_amt)):
        avg_price = (yangs_cumulative_prices_end[i] - yangs_cumulative_prices_start[i]) / intervals_elapsed
        cumulative_weighted_threshold += yangs_amt[i] * avg_price * yangs_thresholds[i]

    relative_ltv = debt / cumulative_weighted_threshold

    trove_base_rate = base_rate(relative_ltv)
    avg_multiplier = (cumulative_multiplier_end - cumulative_multiplier_start) / intervals_elapsed

    true_rate = trove_base_rate * avg_multiplier

    new_debt = debt * Decimal(exp(true_rate * intervals_elapsed * TIME_INTERVAL_DIV_YEAR))
    return new_debt


def calculate_threshold_and_value(
    prices: List[int], amounts: List[int], thresholds: List[int]
) -> Tuple[Decimal, Decimal]:
    """
    Helper function to calculate a trove's cumulative weighted threshold and value

    Arguments
    ---------
    prices : List[int]
        Ordered list of the prices of each Yang in wad
    amounts: List[int]
        Ordered list of the amount of each Yang deposited in the Trove in wad
    thresholds: List[Decimal]
        Ordered list of the threshold for each Yang in wad

    Returns
    -------
    A tuple of the cumulative weighted threshold and total trove value, both in Decimal
    """

    cumulative_weighted_threshold = Decimal("0")
    total_value = Decimal("0")

    # Sanity check on inputs
    assert len(prices) == len(amounts) == len(thresholds)

    for p, a, t in zip(prices, amounts, thresholds):
        p = from_wad(p)
        a = from_wad(a)
        t = from_ray(t)

        total_value += p * a
        cumulative_weighted_threshold += p * a * t

    return cumulative_weighted_threshold, total_value


def calculate_trove_threshold(prices: List[int], amounts: List[int], thresholds: List[int]) -> Decimal:
    """
    Helper function to calculate a trove's threshold

    Arguments
    ---------
    prices : List[int]
        Ordered list of the prices of each Yang in wad
    amounts: List[int]
        Ordered list of the amount of each Yang deposited in the Trove in wad
    thresholds: List[Decimal]
        Ordered list of the threshold for each Yang in wad

    Returns
    -------
    Value of the variable threshold in decimal.
    """
    cumulative_weighted_threshold, total_value = calculate_threshold_and_value(prices, amounts, thresholds)
    return cumulative_weighted_threshold / total_value


def calculate_max_forge(prices: List[int], amounts: List[int], thresholds: List[int]) -> Decimal:
    """
    Helper function to calculate the maximum amount of debt a trove can forge

    Arguments
    ---------
    prices : List[int]
        Ordered list of the prices of each Yang in wad
    amounts: List[int]
        Ordered list of the amount of each Yang deposited in the Trove in wad
    thresholds: List[Decimal]
        Ordered list of the threshold for each Yang in wad

    Returns
    -------
    Value of the maximum forge value for a Trove in decimal.
    """
    cumulative_weighted_threshold, _ = calculate_threshold_and_value(prices, amounts, thresholds)
    return cumulative_weighted_threshold * from_ray(LIMIT_RATIO)


def get_interval(block_timestamp: int) -> int:
    """
    Helper function to calculate the interval by dividing the provided timestamp
    by the TIME_INTERVAL constant.

    Arguments
    ---------
    block_timestamp: int
        Timestamp value

    Returns
    -------
    Interval ID based on the given timestamp.
    """
    return block_timestamp // TIME_INTERVAL


#
# Fixtures
#


@pytest.fixture
async def shrine_withdraw(shrine, shrine_deposit) -> StarknetTransactionExecutionInfo:
    withdraw = await shrine.withdraw(YANG_0_ADDRESS, TROVE_1, to_wad(INITIAL_DEPOSIT)).invoke(
        caller_address=SHRINE_OWNER
    )
    return withdraw


@pytest.fixture
async def update_feeds(starknet, shrine, shrine_forge) -> List[Decimal]:
    """
    Additional price feeds for yang 0 after `shrine_forge`
    """

    yang0_address = YANG_0_ADDRESS
    yang0_feed = create_feed(YANGS[0]["start_price"], FEED_LEN, MAX_PRICE_CHANGE)

    for i in range(FEED_LEN):
        # Add offset for initial feeds in `shrine`
        timestamp = (i + FEED_LEN) * TIME_INTERVAL
        set_block_timestamp(starknet, timestamp)

        await shrine.advance(yang0_address, yang0_feed[i]).invoke(caller_address=SHRINE_OWNER)
        await shrine.update_multiplier(MULTIPLIER_FEED[i]).invoke(caller_address=SHRINE_OWNER)

    return list(map(from_wad, yang0_feed))


@pytest.fixture
async def shrine_deposit_multiple(shrine):
    for d in DEPOSITS:
        await shrine.deposit(d["address"], TROVE_1, d["amount"]).invoke(caller_address=SHRINE_OWNER)


@pytest.fixture
async def shrine_deposit_trove2(shrine) -> StarknetTransactionExecutionInfo:
    """
    Replicate deposit for another trove.
    """
    deposit = await shrine.deposit(YANG_0_ADDRESS, TROVE_2, to_wad(INITIAL_DEPOSIT)).invoke(caller_address=SHRINE_OWNER)
    return deposit


@pytest.fixture
async def shrine_melt(shrine, shrine_forge) -> StarknetTransactionExecutionInfo:

    estimated_debt = (await shrine.estimate(TROVE_1).invoke()).result.wad
    melt = await shrine.melt(TROVE1_OWNER, TROVE_1, estimated_debt).invoke(caller_address=SHRINE_OWNER)
    return melt


@pytest.fixture
async def shrine_forge_trove2(shrine, shrine_deposit_trove2) -> StarknetTransactionExecutionInfo:
    """
    Replicate forge for another trove.
    """
    forge = await shrine.forge(TROVE2_OWNER, TROVE_2, FORGE_AMT_WAD).invoke(caller_address=SHRINE_OWNER)
    return forge


@pytest.fixture
async def update_feeds_with_trove2(shrine_forge, shrine_forge_trove2, update_feeds) -> List[Decimal]:
    """
    Helper fixture for `update_feeds` with two troves.
    """
    return update_feeds


@pytest.fixture
async def estimate(shrine, update_feeds_with_trove2) -> tuple[int, int, Decimal]:
    trove = (await shrine.get_trove(TROVE_1).invoke()).result.trove

    # Get yang price and multiplier value at `trove.charge_from`
    start_cumulative_price = (
        await shrine.get_yang_price(YANG_0_ADDRESS, trove.charge_from).invoke()
    ).result.cumulative_price_wad
    start_cumulative_multiplier = (
        await shrine.get_multiplier(trove.charge_from).invoke()
    ).result.cumulative_multiplier_ray

    # Getting the current yang price and multiplier value
    end_cumulative_price = (await shrine.get_current_yang_price(YANG_0_ADDRESS).invoke()).result.cumulative_price_wad
    end_cumulative_multiplier = (await shrine.get_current_multiplier().invoke()).result.cumulative_multiplier_ray

    expected_debt = compound(
        [Decimal(INITIAL_DEPOSIT)],
        [from_ray(YANG_0_THRESHOLD)],
        [from_wad(start_cumulative_price)],
        [from_wad(end_cumulative_price)],
        from_ray(start_cumulative_multiplier),
        from_ray(end_cumulative_multiplier),
        trove.charge_from,
        2 * FEED_LEN - 1,
        from_wad(trove.debt),
    )

    # Get estimated debt for troves
    estimated_trove1_debt = (await shrine.estimate(TROVE_1).invoke()).result.wad
    estimated_trove2_debt = (await shrine.estimate(TROVE_2).invoke()).result.wad
    return estimated_trove1_debt, estimated_trove2_debt, expected_debt


@pytest.fixture(scope="function")
async def update_feeds_intermittent(request, starknet, shrine, shrine_forge) -> List[Decimal]:
    """
    Additional price feeds for yang 0 after `shrine_forge` with intermittent missed updates.

    This fixture takes in an index as argument, and skips that index when updating the
    price and multiplier values.
    """

    yang0_address = YANG_0_ADDRESS
    yang0_feed = create_feed(YANGS[0]["start_price"], FEED_LEN, MAX_PRICE_CHANGE)

    idx = request.param

    for i in range(FEED_LEN):
        # Add offset for initial feeds in `shrine`
        timestamp = (i + FEED_LEN) * TIME_INTERVAL
        set_block_timestamp(starknet, timestamp)

        price = yang0_feed[i]
        multiplier = MULTIPLIER_FEED[i]

        # Skip index after timestamp is set
        if i != idx:
            await shrine.advance(yang0_address, price).invoke(caller_address=SHRINE_OWNER)
            await shrine.update_multiplier(multiplier).invoke(caller_address=SHRINE_OWNER)

    return idx, list(map(from_wad, yang0_feed))


#
# Tests - Initial parameters of Shrine
#


@pytest.mark.usefixtures("shrine_deploy")
@pytest.mark.asyncio
async def test_shrine_deploy(shrine):
    # Check system is live
    live = (await shrine.get_live().invoke()).result.bool
    assert live == TRUE

    # Assert that `get_current_multiplier` terminates
    multiplier = (await shrine.get_current_multiplier().invoke()).result.multiplier_ray
    assert multiplier == RAY_SCALE


@pytest.mark.asyncio
async def test_shrine_setup(shrine_setup):
    shrine = shrine_setup

    # Check debt ceiling
    ceiling = (await shrine.get_ceiling().invoke()).result.wad
    assert ceiling == DEBT_CEILING

    # Check yang count
    yang_count = (await shrine.get_yangs_count().invoke()).result.ufelt
    assert yang_count == len(YANGS)

    # Check threshold
    for i in range(len(YANGS)):
        yang_address = YANGS[i]["address"]
        threshold = (await shrine.get_threshold(yang_address).invoke()).result.ray
        assert threshold == YANGS[i]["threshold"]

        # Assert that `get_current_yang_price` terminates
        price = (await shrine.get_current_yang_price(yang_address).invoke()).result.price_wad
        assert price == to_wad(YANGS[i]["start_price"])


@pytest.mark.asyncio
async def test_shrine_setup_with_feed(shrine_with_feeds):
    shrine, feeds = shrine_with_feeds

    # Check price feeds
    for i in range(len(YANGS)):
        yang_address = YANGS[i]["address"]

        start_price, start_cumulative_price = (await shrine.get_yang_price(yang_address, 0).invoke()).result
        assert start_price == to_wad(YANGS[i]["start_price"])
        assert start_cumulative_price == to_wad(YANGS[i]["start_price"])

        end_price, end_cumulative_price = (await shrine.get_yang_price(yang_address, FEED_LEN - 1).invoke()).result
        lo, hi = price_bounds(start_price, FEED_LEN, MAX_PRICE_CHANGE)
        assert lo <= end_price <= hi
        assert end_cumulative_price == sum(feeds[i])

    # Check multiplier feed
    start_multiplier, start_cumulative_multiplier = (await shrine.get_multiplier(0).invoke()).result
    assert start_multiplier == RAY_SCALE
    assert start_cumulative_multiplier == RAY_SCALE

    end_multiplier, end_cumulative_multiplier = (await shrine.get_multiplier(FEED_LEN - 1).invoke()).result
    assert end_multiplier != 0
    assert end_cumulative_multiplier == RAY_SCALE * (FEED_LEN)


@pytest.mark.usefixtures("shrine_deploy")
@pytest.mark.asyncio
async def test_auth(shrine_deploy):
    shrine = shrine_deploy

    #
    # Auth
    #
    b = str_to_felt("2nd owner")

    auth_function = ShrineRoles.SET_CEILING

    assert (await shrine.get_admin().invoke()).result.address == SHRINE_OWNER

    # Authorizing an address and testing that it can use authorized functions
    tx = await shrine.grant_role(auth_function, b).invoke(caller_address=SHRINE_OWNER)
    assert_event_emitted(tx, shrine.contract_address, "RoleGranted", [auth_function, b])
    b_authorized = (await shrine.has_role(auth_function, b).invoke()).result.bool
    assert b_authorized == TRUE
    b_role = (await shrine.get_role(b).invoke()).result.ufelt
    assert b_role == auth_function

    await shrine.set_ceiling(WAD_SCALE).invoke(caller_address=b)
    new_ceiling = (await shrine.get_ceiling().invoke()).result.wad
    assert new_ceiling == WAD_SCALE

    # Revoking an address
    tx = await shrine.revoke_role(auth_function, b).invoke(caller_address=SHRINE_OWNER)
    assert_event_emitted(tx, shrine.contract_address, "RoleRevoked", [auth_function, b])
    b_authorized = (await shrine.has_role(auth_function, b).invoke()).result.bool
    assert b_authorized == FALSE
    b_role = (await shrine.get_role(b).invoke()).result.ufelt
    assert b_role == 0

    # Calling an authorized function with an unauthorized address - should fail
    with pytest.raises(StarkException):
        await shrine.set_ceiling(WAD_SCALE).invoke(caller_address=b)


#
# Tests - Yin parameters
#


@pytest.mark.asyncio
async def test_set_ceiling(shrine):
    new_ceiling = to_wad(20_000_000)
    tx = await shrine.set_ceiling(new_ceiling).invoke(caller_address=SHRINE_OWNER)
    assert_event_emitted(tx, shrine.contract_address, "CeilingUpdated", [new_ceiling])
    assert (await shrine.get_ceiling().invoke()).result.wad == new_ceiling


@pytest.mark.asyncio
async def test_set_ceiling_unauthorized(shrine):
    with pytest.raises(StarkException):
        await shrine.set_ceiling(1).invoke(caller_address=BAD_GUY)


#
# Tests - Yang onboarding and parameters
#


@pytest.mark.asyncio
async def test_add_yang_pass(shrine):
    g_count = len(YANGS)
    assert (await shrine.get_yangs_count().invoke()).result.ufelt == g_count

    new_yang_address = 987
    new_yang_max = to_wad(42_000)
    new_yang_threshold = to_wad(Decimal("0.6"))
    new_yang_start_price = to_wad(5)
    tx = await shrine.add_yang(new_yang_address, new_yang_max, new_yang_threshold, new_yang_start_price).invoke(
        caller_address=SHRINE_OWNER
    )
    assert (await shrine.get_yangs_count().invoke()).result.ufelt == g_count + 1
    assert (await shrine.get_current_yang_price(new_yang_address).invoke()).result.price_wad == new_yang_start_price
    assert_event_emitted(
        tx,
        shrine.contract_address,
        "YangAdded",
        [new_yang_address, g_count + 1, new_yang_max, new_yang_start_price],
    )
    assert_event_emitted(tx, shrine.contract_address, "YangsCountUpdated", [g_count + 1])
    assert_event_emitted(
        tx,
        shrine.contract_address,
        "ThresholdUpdated",
        [new_yang_address, new_yang_threshold],
    )

    # Check maximum is correct
    new_yang_info = (await shrine.get_yang(new_yang_address).invoke()).result.yang
    assert new_yang_info.total == 0
    assert new_yang_info.max == new_yang_max

    # Check start price is correct
    new_yang_price_info = (await shrine.get_current_yang_price(new_yang_address).invoke()).result
    assert new_yang_price_info.price_wad == new_yang_start_price

    # Check threshold is correct
    actual_threshold = (await shrine.get_threshold(new_yang_address).invoke()).result.ray
    assert actual_threshold == new_yang_threshold


@pytest.mark.asyncio
async def test_add_yang_duplicate_fail(shrine):
    # Test adding duplicate Yang
    with pytest.raises(StarkException, match="Shrine: Yang already exists"):
        await shrine.add_yang(
            YANG_0_ADDRESS,
            YANG_0_CEILING,
            YANG_0_THRESHOLD,
            to_wad(YANGS[0]["start_price"]),
        ).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_add_yang_unauthorized(shrine):
    # test calling the func unauthorized
    bad_guy_yang_address = 555
    bad_guy_yang_max = to_wad(10_000)
    bad_guy_yang_threshold = to_wad(Decimal("0.5"))
    bad_guy_yang_start_price = to_wad(10)
    with pytest.raises(StarkException):
        await shrine.add_yang(
            bad_guy_yang_address,
            bad_guy_yang_max,
            bad_guy_yang_threshold,
            bad_guy_yang_start_price,
        ).invoke(caller_address=BAD_GUY)


@pytest.mark.asyncio
async def test_set_threshold(shrine):
    # test setting to normal value
    value = 90 * RAY_PERCENT
    tx = await shrine.set_threshold(YANG_0_ADDRESS, value).invoke(caller_address=SHRINE_OWNER)
    assert_event_emitted(tx, shrine.contract_address, "ThresholdUpdated", [YANG_0_ADDRESS, value])
    assert (await shrine.get_threshold(YANG_0_ADDRESS).invoke()).result.ray == value

    # test setting to max value
    max = RAY_SCALE
    tx = await shrine.set_threshold(YANG_0_ADDRESS, max).invoke(caller_address=SHRINE_OWNER)
    assert_event_emitted(tx, shrine.contract_address, "ThresholdUpdated", [YANG_0_ADDRESS, max])
    assert (await shrine.get_threshold(YANG_0_ADDRESS).invoke()).result.ray == max


@pytest.mark.asyncio
async def test_set_threshold_exceeds_max(shrine):
    # test setting over the limit
    max = RAY_SCALE
    with pytest.raises(StarkException, match="Shrine: Threshold exceeds 100%"):
        await shrine.set_threshold(YANG_0_ADDRESS, max + 1).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_set_threshold_unauthorized(shrine):
    value = 90 * RAY_PERCENT
    # test calling the func unauthorized
    with pytest.raises(StarkException):
        await shrine.set_threshold(YANG_0_ADDRESS, value).invoke(caller_address=BAD_GUY)


@pytest.mark.asyncio
async def test_set_threshold_invalid_yang(shrine):
    with pytest.raises(StarkException, match="Shrine: Yang does not exist"):
        await shrine.set_threshold(FAUX_YANG_ADDRESS, to_wad(1000)).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_update_yang_max(shrine):
    async def update_and_assert(new_yang_max):
        orig_yang = (await shrine.get_yang(YANG_0_ADDRESS).invoke()).result.yang
        tx = await shrine.update_yang_max(YANG_0_ADDRESS, new_yang_max).invoke(caller_address=SHRINE_OWNER)
        assert_event_emitted(
            tx,
            shrine.contract_address,
            "YangUpdated",
            [YANG_0_ADDRESS, orig_yang.total, new_yang_max],
        )

        updated_yang = (await shrine.get_yang(YANG_0_ADDRESS).invoke()).result.yang
        assert updated_yang.total == orig_yang.total
        assert updated_yang.max == new_yang_max

    # test increasing the max
    new_yang_max = YANG_0_CEILING * 2
    await update_and_assert(new_yang_max)

    # test decreasing the max
    new_yang_max = YANG_0_CEILING - 1
    await update_and_assert(new_yang_max)

    # test decreasing the max below yang.total
    deposit_amt = to_wad(100)
    # Deposit 100 yang tokens
    await shrine.deposit(YANG_0_ADDRESS, TROVE_1, deposit_amt).invoke(caller_address=SHRINE_OWNER)

    new_yang_max = deposit_amt - to_wad(1)
    await update_and_assert(
        new_yang_max
    )  # update yang_max to a value smaller than the total amount currently deposited

    # This should fail, since yang.total exceeds yang.max
    with pytest.raises(
        StarkException,
        match="Shrine: Exceeds maximum amount of Yang allowed for system",
    ):
        await shrine.deposit(YANG_0_ADDRESS, TROVE_1, deposit_amt).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_update_yang_max_invalid_yang(shrine):
    # test calling with a non-existing yang_address
    with pytest.raises(StarkException, match="Shrine: Yang does not exist"):
        await shrine.update_yang_max(FAUX_YANG_ADDRESS, YANG_0_CEILING - 1).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_update_yang_max_unauthorized(shrine):
    with pytest.raises(StarkException):
        await shrine.update_yang_max(YANG_0_ADDRESS, 2**251).invoke(caller_address=BAD_GUY)


#
# Tests - Shrine kill
#


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_kill(shrine):
    # Check shrine is live
    is_live = (await shrine.get_live().invoke()).result.bool
    assert is_live == TRUE

    tx = await shrine.kill().invoke(caller_address=SHRINE_OWNER)
    assert_event_emitted(tx, shrine.contract_address, "Killed")

    # Check shrine is not live
    is_live = (await shrine.get_live().invoke()).result.bool
    assert is_live == FALSE

    # Check deposit fails
    with pytest.raises(StarkException, match="Shrine: System is not live"):
        await shrine.deposit(YANG_0_ADDRESS, TROVE_1, to_wad(10)).invoke(caller_address=SHRINE_OWNER)

    # Check forge fails
    with pytest.raises(StarkException, match="Shrine: System is not live"):
        await shrine.forge(TROVE1_OWNER, TROVE_1, to_wad(100)).invoke(caller_address=SHRINE_OWNER)

    # Test withdraw pass
    await shrine.withdraw(YANG_0_ADDRESS, TROVE_1, to_wad(1)).invoke(caller_address=SHRINE_OWNER)

    # Test melt pass
    await shrine.melt(TROVE1_OWNER, TROVE_1, to_wad(100)).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_unauthorized_kill(shrine):
    # test calling func unauthorized
    with pytest.raises(StarkException):
        await shrine.kill().invoke(caller_address=BAD_GUY)


#
# Tests - Price and multiplier updates
#


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_advance(starknet, shrine):
    timestamp = get_block_timestamp(starknet)
    interval = get_interval(timestamp)
    yang_price_info = (await shrine.get_yang_price(YANG_0_ADDRESS, interval - 1).invoke()).result

    new_price = to_wad(YANGS[0]["start_price"] + 1)
    advance = await shrine.advance(YANG_0_ADDRESS, new_price).invoke(caller_address=SHRINE_OWNER)

    expected_cumulative = int(yang_price_info.cumulative_price_wad + new_price)

    # Test event emitted
    assert_event_emitted(
        advance,
        shrine.contract_address,
        "YangPriceUpdated",
        [YANG_0_ADDRESS, new_price, expected_cumulative, interval],
    )

    # Test yang price is updated
    updated_yang_price_info = (await shrine.get_current_yang_price(YANG_0_ADDRESS).invoke()).result
    assert updated_yang_price_info.price_wad == new_price
    assert updated_yang_price_info.cumulative_price_wad == expected_cumulative
    assert updated_yang_price_info.interval_ufelt == interval


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_advance_unauthorized(shrine):
    with pytest.raises(StarkException):
        await shrine.advance(YANG_0_ADDRESS, to_wad(YANGS[0]["start_price"])).invoke(caller_address=BAD_GUY)


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_advance_invalid_yang(shrine):
    with pytest.raises(StarkException, match="Shrine: Yang does not exist"):
        await shrine.advance(FAUX_YANG_ADDRESS, to_wad(YANGS[0]["start_price"])).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_update_multiplier(starknet, shrine):
    timestamp = get_block_timestamp(starknet)
    interval = get_interval(timestamp)
    multiplier_info = (await shrine.get_multiplier(interval - 1).invoke()).result

    new_multiplier_value = RAY_SCALE + RAY_SCALE // 2
    update = await shrine.update_multiplier(new_multiplier_value).invoke(caller_address=SHRINE_OWNER)

    expected_cumulative = int(multiplier_info.cumulative_multiplier_ray + new_multiplier_value)

    # Test event emitted
    assert_event_emitted(
        update,
        shrine.contract_address,
        "MultiplierUpdated",
        [new_multiplier_value, expected_cumulative, interval],
    )

    # Test multiplier is updated
    updated_multiplier_info = (await shrine.get_current_multiplier().invoke()).result
    assert updated_multiplier_info.multiplier_ray == new_multiplier_value
    assert updated_multiplier_info.cumulative_multiplier_ray == expected_cumulative
    assert updated_multiplier_info.interval_ufelt == interval


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_update_multiplier_unauthorized(shrine):
    with pytest.raises(StarkException):
        await shrine.update_multiplier(RAY_SCALE).invoke(caller_address=BAD_GUY)


#
# Tests - Trove deposit
#


@pytest.mark.parametrize(
    "deposit_amt_wad",
    [
        0,
        to_wad(Decimal("1E-18")),
        INITIAL_DEPOSIT_WAD // 2,
        INITIAL_DEPOSIT_WAD - 1,
        INITIAL_DEPOSIT_WAD,
    ],
)
@pytest.mark.asyncio
async def test_shrine_deposit_pass(shrine, deposit_amt_wad, collect_gas_cost):
    deposit = await shrine.deposit(YANG_0_ADDRESS, TROVE_1, deposit_amt_wad).invoke(caller_address=SHRINE_OWNER)

    collect_gas_cost("shrine/deposit", deposit, 4, 1)
    assert_event_emitted(
        deposit,
        shrine.contract_address,
        "YangUpdated",
        [YANG_0_ADDRESS, deposit_amt_wad, YANG_0_CEILING],
    )
    assert_event_emitted(
        deposit,
        shrine.contract_address,
        "DepositUpdated",
        [YANG_0_ADDRESS, TROVE_1, deposit_amt_wad],
    )

    yang = (await shrine.get_yang(YANG_0_ADDRESS).invoke()).result.yang
    assert yang.total == deposit_amt_wad

    amt = (await shrine.get_deposit(YANG_0_ADDRESS, TROVE_1).invoke()).result.wad
    assert amt == deposit_amt_wad

    # Check max forge amount
    yang_price = (await shrine.get_current_yang_price(YANG_0_ADDRESS).invoke()).result.price_wad
    max_forge_amt = from_wad((await shrine.get_max_forge(TROVE_1).invoke()).result.wad)
    expected_limit = calculate_max_forge([yang_price], [deposit_amt_wad], [YANG_0_THRESHOLD])
    assert_equalish(max_forge_amt, expected_limit)


@pytest.mark.asyncio
async def test_shrine_deposit_invalid_yang_fail(shrine):
    # Invalid yang ID that has not been added
    with pytest.raises(StarkException, match="Shrine: Yang does not exist"):
        await shrine.deposit(789, TROVE_1, to_wad(1)).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_shrine_deposit_unauthorized(shrine):
    with pytest.raises(StarkException):
        await shrine.deposit(YANG_0_ADDRESS, TROVE_1, INITIAL_DEPOSIT_WAD).invoke(caller_address=BAD_GUY)


@pytest.mark.usefixtures("shrine_deposit")
@pytest.mark.asyncio
async def test_shrine_deposit_exceeds_max(shrine):
    deposit_amt = YANG_0_CEILING - INITIAL_DEPOSIT_WAD + 1
    # Checks for shrine deposit that would exceed the max
    with pytest.raises(
        StarkException,
        match="Shrine: Exceeds maximum amount of Yang allowed for system",
    ):
        await shrine.deposit(YANG_0_ADDRESS, TROVE_1, deposit_amt).invoke(caller_address=SHRINE_OWNER)


#
# Tests - Trove withdraw
#


@pytest.mark.parametrize(
    "withdraw_amt_wad",
    [
        0,
        to_wad(Decimal("1E-18")),
        to_wad(1),
        INITIAL_DEPOSIT_WAD - 1,
        INITIAL_DEPOSIT_WAD,
    ],
)
@pytest.mark.usefixtures("shrine_deposit")
@pytest.mark.asyncio
async def test_shrine_withdraw_pass(shrine, collect_gas_cost, withdraw_amt_wad):
    withdraw = await shrine.withdraw(YANG_0_ADDRESS, TROVE_1, withdraw_amt_wad).invoke(caller_address=SHRINE_OWNER)

    collect_gas_cost("shrine/withdraw", withdraw, 4, 1)

    remaining_amt_wad = INITIAL_DEPOSIT_WAD - withdraw_amt_wad

    assert_event_emitted(
        withdraw,
        shrine.contract_address,
        "YangUpdated",
        [YANG_0_ADDRESS, remaining_amt_wad, YANG_0_CEILING],
    )

    assert_event_emitted(
        withdraw,
        shrine.contract_address,
        "DepositUpdated",
        [YANG_0_ADDRESS, TROVE_1, remaining_amt_wad],
    )

    yang = (await shrine.get_yang(YANG_0_ADDRESS).invoke()).result.yang
    assert yang.total == remaining_amt_wad

    amt = (await shrine.get_deposit(YANG_0_ADDRESS, TROVE_1).invoke()).result.wad
    assert amt == remaining_amt_wad

    ltv = (await shrine.get_current_trove_ratio(TROVE_1).invoke()).result.ray
    assert ltv == 0

    is_healthy = (await shrine.is_healthy(TROVE_1).invoke()).result.bool
    assert is_healthy == TRUE

    # Check max forge amount
    yang_price = (await shrine.get_current_yang_price(YANG_0_ADDRESS).invoke()).result.price_wad
    max_forge_amt = from_wad((await shrine.get_max_forge(TROVE_1).invoke()).result.wad)
    expected_limit = calculate_max_forge([yang_price], [remaining_amt_wad], [YANG_0_THRESHOLD])
    assert_equalish(max_forge_amt, expected_limit)


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.parametrize("withdraw_amt_wad", [0, to_wad(Decimal("1E-18")), to_wad(1), to_wad(5)])
@pytest.mark.asyncio
async def test_shrine_forged_partial_withdraw_pass(shrine, withdraw_amt_wad):
    price_wad = (await shrine.get_current_yang_price(YANG_0_ADDRESS).invoke()).result.price_wad

    initial_amt_wad = INITIAL_DEPOSIT_WAD
    remaining_amt_wad = initial_amt_wad - withdraw_amt_wad

    withdraw = await shrine.withdraw(YANG_0_ADDRESS, TROVE_1, withdraw_amt_wad).invoke(caller_address=SHRINE_OWNER)

    assert_event_emitted(
        withdraw,
        shrine.contract_address,
        "YangUpdated",
        [YANG_0_ADDRESS, remaining_amt_wad, YANG_0_CEILING],
    )

    assert_event_emitted(
        withdraw,
        shrine.contract_address,
        "DepositUpdated",
        [YANG_0_ADDRESS, TROVE_1, remaining_amt_wad],
    )

    yang = (await shrine.get_yang(YANG_0_ADDRESS).invoke()).result.yang
    assert yang.total == remaining_amt_wad

    amt = (await shrine.get_deposit(YANG_0_ADDRESS, TROVE_1).invoke()).result.wad
    assert amt == remaining_amt_wad

    ltv = (await shrine.get_current_trove_ratio(TROVE_1).invoke()).result.ray
    expected_ltv = from_wad(FORGE_AMT_WAD) / (from_wad(price_wad) * from_wad(remaining_amt_wad))
    assert_equalish(from_ray(ltv), expected_ltv)

    is_healthy = (await shrine.is_healthy(TROVE_1).invoke()).result.bool
    assert is_healthy == TRUE

    # Check max forge amount
    yang0_price_wad = (await shrine.get_current_yang_price(YANG_0_ADDRESS).invoke()).result.price_wad
    expected_max_forge_amt = calculate_max_forge([yang0_price_wad], [remaining_amt_wad], [YANG_0_THRESHOLD]) - from_wad(
        FORGE_AMT_WAD
    )
    max_forge_amt = from_wad((await shrine.get_max_forge(TROVE_1).invoke()).result.wad)
    assert_equalish(max_forge_amt, expected_max_forge_amt)


@pytest.mark.asyncio
async def test_shrine_withdraw_invalid_yang_fail(shrine):

    # Invalid yang ID that has not been added
    with pytest.raises(StarkException, match="Shrine: Yang does not exist"):
        await shrine.withdraw(789, TROVE_1, to_wad(1)).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_shrine_withdraw_insufficient_yang_fail(shrine, shrine_deposit):
    with pytest.raises(StarkException, match="Shrine: Insufficient yang"):
        await shrine.withdraw(YANG_0_ADDRESS, TROVE_1, to_wad(11)).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_shrine_withdraw_unsafe_fail(shrine, update_feeds):

    # Get latest price
    price = (await shrine.get_yang_price(YANG_0_ADDRESS, 2 * FEED_LEN - 1).invoke()).result.price_wad
    assert price != 0

    unsafe_amt = (5000 / Decimal("0.85")) / from_wad(price)
    withdraw_amt = Decimal("10") - unsafe_amt

    with pytest.raises(StarkException, match="Shrine: Trove LTV is too high"):
        await shrine.withdraw(YANG_0_ADDRESS, TROVE_1, to_wad(withdraw_amt)).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("shrine_deposit")
@pytest.mark.asyncio
async def test_shrine_withdraw_unauthorized(shrine):
    with pytest.raises(StarkException):
        await shrine.withdraw(YANG_0_ADDRESS, TROVE_1, INITIAL_DEPOSIT_WAD).invoke(caller_address=BAD_GUY)


#
# Tests - Trove forge
#


@pytest.mark.parametrize(
    "forge_amt_wad",
    [0, to_wad(Decimal("1E-18")), FORGE_AMT_WAD // 2, FORGE_AMT_WAD - 1, FORGE_AMT_WAD],
)
@pytest.mark.usefixtures("shrine_deposit")
@pytest.mark.asyncio
async def test_shrine_forge_pass(shrine, forge_amt_wad):
    forge = await shrine.forge(TROVE1_OWNER, TROVE_1, forge_amt_wad).invoke(caller_address=SHRINE_OWNER)

    assert_event_emitted(forge, shrine.contract_address, "DebtTotalUpdated", [forge_amt_wad])
    assert_event_emitted(
        forge,
        shrine.contract_address,
        "TroveUpdated",
        [TROVE_1, FEED_LEN - 1, forge_amt_wad],
    )

    # Yin Events
    assert_event_emitted(forge, shrine.contract_address, "YinUpdated", [TROVE1_OWNER, forge_amt_wad])
    assert_event_emitted(forge, shrine.contract_address, "YinTotalUpdated", [forge_amt_wad])

    system_debt = (await shrine.get_debt().invoke()).result.wad
    assert system_debt == forge_amt_wad

    trove = (await shrine.get_trove(TROVE_1).invoke()).result.trove
    assert trove.debt == forge_amt_wad
    assert trove.charge_from == FEED_LEN - 1

    yang0_price = (await shrine.get_current_yang_price(YANG_0_ADDRESS).invoke()).result.price_wad
    trove_ltv = (await shrine.get_current_trove_ratio(TROVE_1).invoke()).result.ray
    adjusted_trove_ltv = Decimal(trove_ltv) / RAY_SCALE
    expected_ltv = Decimal(forge_amt_wad) / Decimal(10 * yang0_price)
    assert_equalish(adjusted_trove_ltv, expected_ltv)

    healthy = (await shrine.is_healthy(TROVE_1).invoke()).result.bool
    assert healthy == TRUE

    # Check max forge amount
    yang_price = (await shrine.get_current_yang_price(YANG_0_ADDRESS).invoke()).result.price_wad
    max_forge_amt = from_wad((await shrine.get_max_forge(TROVE_1).invoke()).result.wad)
    expected_limit = calculate_max_forge([yang_price], [INITIAL_DEPOSIT_WAD], [YANG_0_THRESHOLD])
    current_debt = from_wad((await shrine.estimate(TROVE_1).invoke()).result.wad)
    assert_equalish(max_forge_amt, expected_limit - current_debt)


@pytest.mark.asyncio
async def test_shrine_forge_zero_deposit_fail(shrine):
    # Forge without any yangs deposited
    with pytest.raises(StarkException, match="Shrine: Trove LTV is too high"):
        await shrine.forge(TROVE1_OWNER, TROVE_1, to_wad(1_000)).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_shrine_forge_unsafe_fail(shrine):
    # Increase debt ceiling
    new_ceiling = to_wad(100_000)
    await shrine.set_ceiling(new_ceiling).invoke(caller_address=SHRINE_OWNER)

    with pytest.raises(StarkException, match="Shrine: Trove LTV is too high"):
        await shrine.forge(TROVE1_OWNER, TROVE_1, to_wad(14_000)).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_shrine_forge_ceiling_fail(shrine):
    # Deposit more yang
    await shrine.deposit(YANG_0_ADDRESS, TROVE_1, to_wad(10)).invoke(caller_address=SHRINE_OWNER)
    updated_deposit = (await shrine.get_deposit(YANG_0_ADDRESS, TROVE_1).invoke()).result.wad
    assert updated_deposit == to_wad(20)

    with pytest.raises(StarkException, match="Shrine: Debt ceiling reached"):
        await shrine.forge(TROVE1_OWNER, TROVE_1, to_wad(15_000)).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("shrine_deposit")
@pytest.mark.asyncio
async def test_shrine_forge_unauthorized(shrine):
    with pytest.raises(StarkException):
        await shrine.forge(TROVE1_OWNER, TROVE_1, FORGE_AMT_WAD).invoke(caller_address=BAD_GUY)


#
# Tests - Trove melt
#


@pytest.mark.asyncio
async def test_shrine_melt_pass(shrine, shrine_melt):
    assert_event_emitted(shrine_melt, shrine.contract_address, "DebtTotalUpdated", [0])
    assert_event_emitted(shrine_melt, shrine.contract_address, "TroveUpdated", [TROVE_1, FEED_LEN - 1, 0])

    # Yin events
    assert_event_emitted(shrine_melt, shrine.contract_address, "YinUpdated", [TROVE1_OWNER, 0])
    assert_event_emitted(shrine_melt, shrine.contract_address, "YinTotalUpdated", [0])

    system_debt = (await shrine.get_debt().invoke()).result.wad
    assert system_debt == 0

    trove = (await shrine.get_trove(TROVE_1).invoke()).result.trove
    assert trove.debt == 0
    assert trove.charge_from == FEED_LEN - 1

    shrine_ltv = (await shrine.get_current_trove_ratio(TROVE_1).invoke()).result.ray
    assert shrine_ltv == 0

    healthy = (await shrine.is_healthy(TROVE_1).invoke()).result.bool
    assert healthy == TRUE

    # Check max forge amount
    yang_price = (await shrine.get_current_yang_price(YANG_0_ADDRESS).invoke()).result.price_wad
    max_forge_amt = from_wad((await shrine.get_max_forge(TROVE_1).invoke()).result.wad)
    expected_limit = calculate_max_forge([yang_price], [INITIAL_DEPOSIT_WAD], [YANG_0_THRESHOLD])
    assert_equalish(max_forge_amt, expected_limit)


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.parametrize("melt_amt_wad", [0, to_wad(Decimal("1E-18")), FORGE_AMT_WAD // 2, FORGE_AMT_WAD])
@pytest.mark.asyncio
async def test_shrine_partial_melt_pass(shrine, melt_amt_wad):
    price_wad = (await shrine.get_current_yang_price(YANG_0_ADDRESS).invoke()).result.price_wad

    estimated_debt_wad = (await shrine.estimate(TROVE_1).invoke()).result.wad
    outstanding_amt_wad = estimated_debt_wad - melt_amt_wad

    melt = await shrine.melt(TROVE1_OWNER, TROVE_1, melt_amt_wad).invoke(caller_address=SHRINE_OWNER)

    assert_event_emitted(melt, shrine.contract_address, "DebtTotalUpdated", [outstanding_amt_wad])

    assert_event_emitted(
        melt,
        shrine.contract_address,
        "TroveUpdated",
        [TROVE_1, FEED_LEN - 1, outstanding_amt_wad],
    )

    system_debt = (await shrine.get_debt().invoke()).result.wad
    assert system_debt == outstanding_amt_wad

    trove = (await shrine.get_trove(TROVE_1).invoke()).result.trove
    assert trove.debt == outstanding_amt_wad
    assert trove.charge_from == FEED_LEN - 1

    shrine_ltv = (await shrine.get_current_trove_ratio(TROVE_1).invoke()).result.ray
    expected_ltv = from_wad(outstanding_amt_wad) / (INITIAL_DEPOSIT * from_wad(price_wad))
    assert_equalish(from_ray(shrine_ltv), expected_ltv)

    healthy = (await shrine.is_healthy(TROVE_1).invoke()).result.bool
    assert healthy == TRUE

    # Check max forge amount
    yang_price = (await shrine.get_current_yang_price(YANG_0_ADDRESS).invoke()).result.price_wad
    max_forge_amt = from_wad((await shrine.get_max_forge(TROVE_1).invoke()).result.wad)
    expected_limit = calculate_max_forge([yang_price], [INITIAL_DEPOSIT_WAD], [YANG_0_THRESHOLD]) - from_wad(
        outstanding_amt_wad
    )
    assert_equalish(max_forge_amt, expected_limit)


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_shrine_melt_system_underflow(shrine):
    estimated_debt = (await shrine.estimate(TROVE_1).invoke()).result.wad
    excess_debt = estimated_debt + 1
    with pytest.raises(StarkException, match="Shrine: System debt underflow"):
        await shrine.melt(TROVE1_OWNER, TROVE_1, excess_debt).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("update_feeds_with_trove2")
@pytest.mark.asyncio
async def test_shrine_melt_trove_underflow(shrine):
    estimated_debt = (await shrine.estimate(TROVE_1).invoke()).result.wad
    excess_debt = estimated_debt + 1
    with pytest.raises(
        StarkException,
        match="Shrine: cannot pay back more debt than exists in this trove",
    ):
        await shrine.melt(TROVE1_OWNER, TROVE_1, excess_debt).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_shrine_melt_unauthorized(shrine):
    estimated_debt = (await shrine.estimate(TROVE_1).invoke()).result.wad
    with pytest.raises(StarkException):
        await shrine.melt(TROVE1_OWNER, TROVE_1, estimated_debt).invoke(caller_address=BAD_GUY)


#
# Tests - Trove estimate and charge
#


@pytest.mark.asyncio
async def test_estimate(shrine, estimate):
    trove1 = (await shrine.get_trove(TROVE_1).invoke()).result.trove
    assert trove1.charge_from == FEED_LEN - 1

    trove2 = (await shrine.get_trove(TROVE_2).invoke()).result.trove
    assert trove2.charge_from == FEED_LEN - 1

    last_updated = (await shrine.get_yang_price(YANG_0_ADDRESS, 2 * FEED_LEN - 1).invoke()).result.price_wad
    assert last_updated != 0

    estimated_trove1_debt, estimated_trove2_debt, expected_debt = estimate

    # Convert wad values to decimal
    adjusted_estimated_trove1_debt = Decimal(estimated_trove1_debt) / WAD_SCALE
    adjusted_estimated_trove2_debt = Decimal(estimated_trove2_debt) / WAD_SCALE

    # Check values
    assert_equalish(adjusted_estimated_trove1_debt, expected_debt)
    assert_equalish(adjusted_estimated_trove2_debt, expected_debt)


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "method,calldata",
    [
        ("deposit", [YANG_0_ADDRESS, 1, 0]),  # yang_address, trove_id, amount
        ("withdraw", [YANG_0_ADDRESS, 1, 0]),  # yang_address, trove_id, amount
        ("forge", [1, 1, 0]),  # user_address, trove_id, amount
        ("melt", [1, 1, 0]),  # user_address, trove_id, amount
        (
            "move_yang",
            [YANG_0_ADDRESS, 1, 2, 0],
        ),  # yang_address, src_trove_id, dst_trove_id, amount
    ],
)
async def test_charge(shrine, estimate, method, calldata):

    estimated_trove1_debt, estimated_trove2_debt, expected_debt = estimate

    # Calculate expected system debt
    if method == "move_yang":
        expected_system_debt = estimated_trove1_debt + estimated_trove2_debt
    else:
        expected_system_debt = estimated_trove1_debt + FORGE_AMT_WAD

    # Test `charge` by calling the method without any value
    tx = await getattr(shrine, method)(*calldata).invoke(caller_address=SHRINE_OWNER)

    # Get updated system info
    new_system_debt = (await shrine.get_debt().invoke()).result.wad
    assert new_system_debt == expected_system_debt

    # Get updated trove information for Trove ID 1
    updated_trove1 = (await shrine.get_trove(TROVE_1).invoke()).result.trove
    adjusted_trove_debt = Decimal(updated_trove1.debt) / WAD_SCALE

    assert_equalish(adjusted_trove_debt, expected_debt)
    assert updated_trove1.charge_from == FEED_LEN * 2 - 1

    assert_event_emitted(tx, shrine.contract_address, "DebtTotalUpdated", [expected_system_debt])
    assert_event_emitted(
        tx,
        shrine.contract_address,
        "TroveUpdated",
        [TROVE_1, updated_trove1.charge_from, updated_trove1.debt],
    )

    # `charge` should not have any effect if `Trove.charge_from` is the current interval
    redundant_tx = await getattr(shrine, method)(*calldata).invoke(caller_address=SHRINE_OWNER)
    redundant_trove1 = (await shrine.get_trove(TROVE_1).invoke()).result.trove
    assert updated_trove1 == redundant_trove1
    assert_event_emitted(
        redundant_tx,
        shrine.contract_address,
        "DebtTotalUpdated",
        [expected_system_debt],
    )
    assert_event_emitted(
        redundant_tx,
        shrine.contract_address,
        "TroveUpdated",
        [TROVE_1, updated_trove1.charge_from, updated_trove1.debt],
    )

    # Check Trove ID 2 if method is `move_yang`
    if method == "move_yang":
        # Get updated trove information for Trove ID 2
        updated_trove2 = (await shrine.get_trove(TROVE_2).invoke()).result.trove
        adjusted_trove_debt = Decimal(updated_trove2.debt) / WAD_SCALE

        assert_equalish(adjusted_trove_debt, expected_debt)
        assert updated_trove2.charge_from == FEED_LEN * 2 - 1

        assert_event_emitted(
            tx,
            shrine.contract_address,
            "TroveUpdated",
            [TROVE_2, updated_trove2.charge_from, updated_trove2.debt],
        )

        # `charge` should not have any effect if `Trove.charge_from` is current interval + 1
        redundant_tx = await getattr(shrine, method)(*calldata).invoke(caller_address=SHRINE_OWNER)
        redundant_trove2 = (await shrine.get_trove(TROVE_2).invoke()).result.trove
        assert updated_trove2 == redundant_trove2
        assert_event_emitted(
            redundant_tx,
            shrine.contract_address,
            "DebtTotalUpdated",
            [expected_system_debt],
        )
        assert_event_emitted(
            redundant_tx,
            shrine.contract_address,
            "TroveUpdated",
            [TROVE_2, updated_trove2.charge_from, updated_trove2.debt],
        )


# Skip index 0 because initial price is set in `add_yang`
@pytest.mark.asyncio
@pytest.mark.parametrize(
    "update_feeds_intermittent",
    [0, 1, FEED_LEN - 2, FEED_LEN - 1],
    indirect=["update_feeds_intermittent"],
)
async def test_intermittent_charge(shrine, update_feeds_intermittent):
    """
    Test for `charge` with "missed" price and multiplier updates at the given index.

    The `update_feeds_intermittent` fixture returns a tuple of the index that is skipped,
    and a list for the price feed.

    The index is with reference to the second set of feeds.
    Therefore, writes to the contract takes in an additional offset of FEED_LEN for the initial
    set of feeds in `shrine` fixture.
    """

    idx, price_feed = update_feeds_intermittent

    # Assert that value for skipped index is set to 0
    assert (await shrine.get_yang_price(YANG_0_ADDRESS, idx + FEED_LEN).invoke()).result.price_wad == 0
    assert (await shrine.get_multiplier(idx + FEED_LEN).invoke()).result.multiplier_ray == 0

    # Get yang price and multiplier value at `trove.charge_from`
    trove = (await shrine.get_trove(TROVE_1).invoke()).result.trove
    start_price = (await shrine.get_yang_price(YANG_0_ADDRESS, trove.charge_from).invoke()).result.price_wad
    start_multiplier = (await shrine.get_multiplier(trove.charge_from).invoke()).result.multiplier_ray

    # Modify feeds
    yang0_price_feed = [from_wad(start_price)] + price_feed
    multiplier_feed = [from_ray(start_multiplier)] + [Decimal("1")] * FEED_LEN

    # Add offset of 1 to account for last price of first set of feeds being appended as first value
    yang0_price_feed[idx + 1] = yang0_price_feed[idx]
    multiplier_feed[idx + 1] = multiplier_feed[idx]

    # Test 'charge' by calling deposit without any value
    await shrine.deposit(YANG_0_ADDRESS, TROVE_1, 0).invoke(caller_address=SHRINE_OWNER)
    updated_trove = (await shrine.get_trove(TROVE_1).invoke()).result.trove

    expected_debt = compound(
        [Decimal("10")],
        [from_ray(YANG_0_THRESHOLD)],
        [yang0_price_feed[0]],
        [sum(yang0_price_feed)],
        multiplier_feed[0],
        sum(multiplier_feed),
        0,
        FEED_LEN * 2 - 1,
        Decimal("5000"),
    )

    adjusted_trove_debt = Decimal(updated_trove.debt) / WAD_SCALE
    # Precision loss gets quite bad for the interest accumulation calculations due
    # to the several multiplications and divisions, as well the `exp` function.
    assert_equalish(adjusted_trove_debt, expected_debt, Decimal("0.1"))

    assert updated_trove.charge_from == FEED_LEN * 2 - 1


#
# Tests - Move yang
#


@pytest.mark.parametrize("move_amt", [0, to_wad(Decimal("1E-18")), 1, INITIAL_DEPOSIT // 2])
@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_move_yang_pass(shrine, move_amt, collect_gas_cost):
    # Check max forge amount
    yang_price = (await shrine.get_current_yang_price(YANG_0_ADDRESS).invoke()).result.price_wad
    max_forge_amt = from_wad((await shrine.get_max_forge(TROVE_1).invoke()).result.wad)
    expected_limit = calculate_max_forge([yang_price], [INITIAL_DEPOSIT_WAD], [YANG_0_THRESHOLD])
    current_debt = from_wad((await shrine.estimate(TROVE_1).invoke()).result.wad)
    assert_equalish(max_forge_amt, expected_limit - current_debt)

    tx = await shrine.move_yang(YANG_0_ADDRESS, TROVE_1, TROVE_2, to_wad(move_amt)).invoke(caller_address=SHRINE_OWNER)

    collect_gas_cost("shrine/move_yang", tx, 6, 1)

    assert_event_emitted(
        tx,
        shrine.contract_address,
        "DepositUpdated",
        [YANG_0_ADDRESS, TROVE_1, to_wad(INITIAL_DEPOSIT - move_amt)],
    )
    assert_event_emitted(
        tx,
        shrine.contract_address,
        "DepositUpdated",
        [YANG_0_ADDRESS, TROVE_2, to_wad(move_amt)],
    )

    src_amt = (await shrine.get_deposit(YANG_0_ADDRESS, TROVE_1).invoke()).result.wad
    assert src_amt == to_wad(INITIAL_DEPOSIT - move_amt)

    dst_amt = (await shrine.get_deposit(YANG_0_ADDRESS, TROVE_2).invoke()).result.wad
    assert dst_amt == to_wad(move_amt)

    # Check max forge amount
    max_forge_amt = from_wad((await shrine.get_max_forge(TROVE_1).invoke()).result.wad)
    move_amt_value = move_amt * from_wad(yang_price) * from_ray(YANG_0_THRESHOLD) * from_ray(LIMIT_RATIO)
    expected_limit -= move_amt_value
    assert_equalish(max_forge_amt, expected_limit - current_debt)


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_move_yang_insufficient_fail(shrine):
    with pytest.raises(StarkException, match="Shrine: Insufficient yang"):
        await shrine.move_yang(YANG_0_ADDRESS, TROVE_1, TROVE_2, to_wad(11)).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_move_yang_unsafe_fail(shrine):
    # Get latest price
    price = (await shrine.get_current_yang_price(YANG_0_ADDRESS).invoke()).result.price_wad
    assert price != 0

    unsafe_amt = (5000 / Decimal("0.85")) / from_wad(price)
    withdraw_amt = Decimal("10") - unsafe_amt

    with pytest.raises(StarkException, match="Shrine: Trove LTV is too high"):
        await shrine.move_yang(YANG_0_ADDRESS, TROVE_1, TROVE_2, to_wad(withdraw_amt)).invoke(
            caller_address=SHRINE_OWNER
        )


@pytest.mark.asyncio
async def test_move_yang_invalid_yang(shrine):
    with pytest.raises(StarkException, match="Shrine: Yang does not exist"):
        await shrine.set_threshold(FAUX_YANG_ADDRESS, to_wad(1000)).invoke(caller_address=SHRINE_OWNER)


#
# Tests - Move yin
#


@pytest.mark.parametrize("transfer_amount", [0, FORGE_AMT_WAD // 2, FORGE_AMT_WAD])
@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_shrine_move_yin_pass(shrine, transfer_amount):

    await shrine.move_yin(TROVE1_OWNER, TROVE2_OWNER, transfer_amount).invoke(caller_address=SHRINE_OWNER)
    # Checking the updated balances
    u1_new_bal = (await shrine.get_yin(TROVE1_OWNER).invoke()).result.wad
    assert u1_new_bal == FORGE_AMT_WAD - transfer_amount

    u2_new_bal = (await shrine.get_yin(TROVE2_OWNER).invoke()).result.wad
    assert u2_new_bal == transfer_amount


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_shrine_move_yin_fail(shrine):

    # Trying to transfer more than the user owns
    with pytest.raises(StarkException, match="Shrine: transfer amount exceeds yin balance"):
        await shrine.move_yin(TROVE1_OWNER, TROVE2_OWNER, FORGE_AMT_WAD + 1).invoke(caller_address=SHRINE_OWNER)

    # Trying to transfer a negative amount
    with pytest.raises(StarkException, match="Shrine: transfer amount outside the valid range."):
        await shrine.move_yin(TROVE1_OWNER, TROVE2_OWNER, signed_int_to_felt(-1)).invoke(caller_address=SHRINE_OWNER)

    # Trying to transfer an amount greater than 2**125
    with pytest.raises(StarkException, match="Shrine: transfer amount outside the valid range."):
        await shrine.move_yin(TROVE1_OWNER, TROVE2_OWNER, 2**125 + 1).invoke(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_shrine_melt_after_move_yin_fail(shrine):

    # Transfer half of the forge amount to another account
    await shrine.move_yin(TROVE1_OWNER, TROVE2_OWNER, FORGE_AMT_WAD // 2).invoke(caller_address=SHRINE_OWNER)
    # Attempt to melt all debt - should fail since not enough yin
    with pytest.raises(StarkException, match="Shrine: not enough yin to melt debt"):
        await shrine.melt(TROVE1_OWNER, TROVE_1, FORGE_AMT_WAD).invoke(caller_address=SHRINE_OWNER)


#
# Tests - Price and multiplier
#


@pytest.mark.asyncio
async def test_shrine_advance_update_multiplier_invalid_fail(shrine_deploy):
    shrine = shrine_deploy
    with pytest.raises(StarkException, match="Shrine: cannot set a price value to zero."):
        await shrine.advance(YANG_0_ADDRESS, 0).invoke(caller_address=SHRINE_OWNER)

    with pytest.raises(StarkException, match="Shrine: cannot set a multiplier value to zero."):
        await shrine.update_multiplier(0).invoke(caller_address=SHRINE_OWNER)


#
# Tests - Getters for Trove information
#


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_shrine_unhealthy(shrine):
    # Calculate unsafe yang price
    yang_balance = from_wad((await shrine.get_deposit(YANG_0_ADDRESS, TROVE_1).invoke()).result.wad)
    debt = from_wad((await shrine.get_trove(TROVE_1).invoke()).result.trove.debt)
    unsafe_price = debt / Decimal("0.85") / yang_balance

    # Update yang price to unsafe level
    await shrine.advance(YANG_0_ADDRESS, to_wad(unsafe_price)).invoke(caller_address=SHRINE_OWNER)
    is_healthy = (await shrine.is_healthy(TROVE_1).invoke()).result.bool
    assert is_healthy == FALSE


@pytest.mark.asyncio
async def test_get_trove_threshold(shrine, shrine_deposit_multiple):
    prices = []
    for d in DEPOSITS:
        price = (await shrine.get_current_yang_price(d["address"]).invoke()).result.price_wad
        prices.append(price)

    expected_threshold = calculate_trove_threshold(
        prices, [d["amount"] for d in DEPOSITS], [d["threshold"] for d in DEPOSITS]
    )

    # Getting actual threshold
    actual_threshold = (await shrine.get_trove_threshold(TROVE_1).invoke()).result.threshold_ray
    assert_equalish(from_ray(actual_threshold), expected_threshold)
