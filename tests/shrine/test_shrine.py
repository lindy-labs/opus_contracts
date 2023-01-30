from decimal import ROUND_DOWN, Decimal
from math import exp

import pytest
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.objects import StarknetCallInfo
from starkware.starkware_utils.error_handling import StarkException

from tests.shrine.constants import *  # noqa: F403
from tests.utils import (
    BAD_GUY,
    FALSE,
    INFINITE_YIN_ALLOWANCE,
    RAY_PERCENT,
    RAY_SCALE,
    SHRINE_OWNER,
    TIME_INTERVAL,
    TIME_INTERVAL_DIV_YEAR,
    TROVE1_OWNER,
    TROVE2_OWNER,
    TROVE3_OWNER,
    TROVE_1,
    TROVE_2,
    TROVE_3,
    TRUE,
    WAD_RAY_BOUND,
    WAD_RAY_OOB_VALUES,
    WAD_SCALE,
    assert_equalish,
    assert_event_emitted,
    calculate_max_forge,
    calculate_trove_threshold_and_value,
    create_feed,
    from_ray,
    from_wad,
    get_block_timestamp,
    get_interval,
    price_bounds,
    set_block_timestamp,
    str_to_felt,
    to_ray,
    to_uint,
    to_wad,
)

#
# Structs
#


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


def compound_with_avg_price(
    yangs_amt: list[Decimal],
    yangs_thresholds: list[Decimal],
    yang_prices: list[Decimal],
    multiplier: Decimal,
    intervals: int,
    debt: Decimal,
) -> Decimal:
    """
    Helper function to calculate the compound debt using average price and multiplier values.

    Arguments
    ---------
    yangs_amt : list[Decimal]
        Ordered list of the amount of each Yang
    yangs_thresholds : list[Decimal]
        Ordered list of the threshold for each Yang
    yang_prices: list[Decimal]
        The price of each yang
    multiplier : Decimal
        The multiplier value
    intervals: int
        Number of intervals to compound
    debt : Decimal
        Amount of debt at the start interval

    Returns
    -------
    Value of the compounded debt from start interval to end interval in Decimal
    """

    # Sanity check on input data
    assert len(yangs_amt) == len(yang_prices) == len(yangs_thresholds)

    avg_max_debt = Decimal("0")
    for i in range(len(yangs_amt)):
        avg_max_debt += yangs_amt[i] * yang_prices[i] * yangs_thresholds[i]

    relative_ltv = debt / avg_max_debt

    trove_base_rate = base_rate(relative_ltv)
    true_rate = trove_base_rate * multiplier

    new_debt = debt * Decimal(exp(true_rate * intervals * TIME_INTERVAL_DIV_YEAR))
    return new_debt


#
# Fixtures
#


@pytest.fixture
async def shrine_withdraw(shrine, shrine_deposit) -> StarknetCallInfo:
    withdraw = await shrine.withdraw(YANG1_ADDRESS, TROVE_1, to_wad(INITIAL_DEPOSIT)).execute(
        caller_address=SHRINE_OWNER
    )
    return withdraw


@pytest.fixture
async def update_feeds(starknet, shrine, shrine_forge) -> list[Decimal]:
    """
    Additional price feeds for yang 0 after `shrine_forge`
    """

    yang0_address = YANG1_ADDRESS
    yang0_feed = create_feed(YANGS[0]["start_price"], FEED_LEN, MAX_PRICE_CHANGE)

    for i in range(FEED_LEN):
        # Add offset for initial feeds in `shrine`
        timestamp = (i + FEED_LEN) * TIME_INTERVAL
        set_block_timestamp(starknet, timestamp)

        await shrine.advance(yang0_address, yang0_feed[i]).execute(caller_address=SHRINE_OWNER)
        await shrine.set_multiplier(MULTIPLIER_FEED[i]).execute(caller_address=SHRINE_OWNER)

    return list(map(from_wad, yang0_feed))


@pytest.fixture
async def shrine_deposit_multiple(shrine):
    for d in DEPOSITS:
        await shrine.deposit(d["address"], TROVE_1, d["amount"]).execute(caller_address=SHRINE_OWNER)


@pytest.fixture
async def shrine_deposit_trove2(shrine) -> StarknetCallInfo:
    """
    Replicate deposit for another trove.
    """
    deposit = await shrine.deposit(YANG1_ADDRESS, TROVE_2, to_wad(INITIAL_DEPOSIT)).execute(caller_address=SHRINE_OWNER)
    return deposit


@pytest.fixture
async def shrine_melt(shrine, shrine_forge) -> StarknetCallInfo:
    estimated_debt = (await shrine.get_trove_info(TROVE_1).execute()).result.debt
    melt = await shrine.melt(TROVE1_OWNER, TROVE_1, estimated_debt).execute(caller_address=SHRINE_OWNER)
    return melt


@pytest.fixture
async def shrine_forge_trove2(shrine, shrine_deposit_trove2) -> StarknetCallInfo:
    """
    Replicate forge for another trove.
    """
    forge = await shrine.forge(TROVE2_OWNER, TROVE_2, FORGE_AMT_WAD).execute(caller_address=SHRINE_OWNER)
    return forge


@pytest.fixture
async def update_feeds_with_trove2(shrine_forge, shrine_forge_trove2, update_feeds) -> list[Decimal]:
    """
    Helper fixture for `update_feeds` with two troves.
    """
    return update_feeds


@pytest.fixture
async def estimate(shrine, update_feeds_with_trove2) -> tuple[int, int, Decimal, Decimal]:
    trove = (await shrine.get_trove(TROVE_1).execute()).result.trove

    # Get yang price and multiplier value at `trove.charge_from`
    start_cumulative_price = (
        await shrine.get_yang_price(YANG1_ADDRESS, trove.charge_from).execute()
    ).result.cumulative_price
    start_cumulative_multiplier = (
        await shrine.get_multiplier(trove.charge_from).execute()
    ).result.cumulative_multiplier

    # Getting the current yang price and multiplier value
    end_cumulative_price = (await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result.cumulative_price
    end_cumulative_multiplier = (await shrine.get_current_multiplier().execute()).result.cumulative_multiplier

    expected_avg_price = from_wad(end_cumulative_price - start_cumulative_price) / FEED_LEN
    expected_avg_multiplier = from_ray(end_cumulative_multiplier - start_cumulative_multiplier) / FEED_LEN

    expected_debt = compound_with_avg_price(
        [Decimal(INITIAL_DEPOSIT)],
        [from_ray(YANG1_THRESHOLD)],
        [expected_avg_price],
        expected_avg_multiplier,
        FEED_LEN,
        from_wad(trove.debt),
    )

    # Get estimated debt for troves
    estimated_trove1_debt = (await shrine.get_trove_info(TROVE_1).execute()).result.debt
    estimated_trove2_debt = (await shrine.get_trove_info(TROVE_2).execute()).result.debt
    return estimated_trove1_debt, estimated_trove2_debt, expected_debt, expected_avg_price


@pytest.fixture(scope="function")
async def update_feeds_intermittent(request, starknet, shrine, shrine_forge) -> list[Decimal]:
    """
    Additional price feeds for yang 0 after `shrine_forge` with intermittent missed updates.

    This fixture takes in an index as argument, and skips that index when updating the
    price and multiplier values.
    """

    yang0_address = YANG1_ADDRESS
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
            await shrine.advance(yang0_address, price).execute(caller_address=SHRINE_OWNER)
            await shrine.set_multiplier(multiplier).execute(caller_address=SHRINE_OWNER)

    return idx, list(map(from_wad, yang0_feed))


@pytest.fixture
async def shrine_killed(shrine) -> StarknetContract:
    await shrine.kill().execute(caller_address=SHRINE_OWNER)
    return shrine


@pytest.fixture
def shrine_both(request) -> StarknetContract:
    """
    Wrapper fixture to pass the regular and killed instances of shrine to `pytest.parametrize`.
    """
    return request.getfixturevalue(request.param)


#
# Tests - Initial parameters of Shrine
#


@pytest.mark.usefixtures("shrine_deploy")
@pytest.mark.asyncio
async def test_shrine_deploy(shrine):
    # Check system is live
    live = (await shrine.get_live().execute()).result.is_live
    assert live == TRUE

    # Assert that `get_current_multiplier` terminates
    multiplier = (await shrine.get_current_multiplier().execute()).result.multiplier
    assert multiplier == RAY_SCALE

    assert (await shrine.name().execute()).result.name == YIN_NAME
    assert (await shrine.symbol().execute()).result.symbol == YIN_SYMBOL
    assert (await shrine.decimals().execute()).result.decimals == 18


@pytest.mark.asyncio
async def test_shrine_setup(shrine_setup):
    shrine = shrine_setup

    # Check debt ceiling
    ceiling = (await shrine.get_ceiling().execute()).result.ceiling
    assert ceiling == DEBT_CEILING

    # Check yang count
    yang_count = (await shrine.get_yangs_count().execute()).result.count
    assert yang_count == len(YANGS)

    # Check threshold
    for i in range(len(YANGS)):
        yang_address = YANGS[i]["address"]
        threshold = (await shrine.get_yang_threshold(yang_address).execute()).result.threshold
        assert threshold == YANGS[i]["threshold"]

        # Assert that `get_current_yang_price` terminates
        price = (await shrine.get_current_yang_price(yang_address).execute()).result.price
        assert price == to_wad(YANGS[i]["start_price"])


@pytest.mark.asyncio
async def test_shrine_setup_with_feed(shrine_with_feeds):
    shrine, feeds = shrine_with_feeds

    # Check price feeds
    for i in range(len(YANGS)):
        yang_address = YANGS[i]["address"]

        start_price, start_cumulative_price = (await shrine.get_yang_price(yang_address, 0).execute()).result
        assert start_price == to_wad(YANGS[i]["start_price"])
        assert start_cumulative_price == to_wad(YANGS[i]["start_price"])

        end_price, end_cumulative_price = (await shrine.get_yang_price(yang_address, FEED_LEN - 1).execute()).result
        lo, hi = price_bounds(start_price, FEED_LEN, MAX_PRICE_CHANGE)
        assert lo <= end_price <= hi
        assert end_cumulative_price == sum(feeds[i])

    # Check multiplier feed
    start_multiplier, start_cumulative_multiplier = (await shrine.get_multiplier(0).execute()).result
    assert start_multiplier == RAY_SCALE
    assert start_cumulative_multiplier == RAY_SCALE

    end_multiplier, end_cumulative_multiplier = (await shrine.get_multiplier(FEED_LEN - 1).execute()).result
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

    assert (await shrine.get_admin().execute()).result.admin == SHRINE_OWNER

    # Authorizing an address and testing that it can use authorized functions
    tx = await shrine.grant_role(auth_function, b).execute(caller_address=SHRINE_OWNER)
    assert_event_emitted(tx, shrine.contract_address, "RoleGranted", [auth_function, b])
    b_authorized = (await shrine.has_role(auth_function, b).execute()).result.has_role
    assert b_authorized == TRUE
    b_role = (await shrine.get_roles(b).execute()).result.roles
    assert b_role == auth_function

    await shrine.set_ceiling(WAD_SCALE).execute(caller_address=b)
    new_ceiling = (await shrine.get_ceiling().execute()).result.ceiling
    assert new_ceiling == WAD_SCALE

    # Revoking an address
    tx = await shrine.revoke_role(auth_function, b).execute(caller_address=SHRINE_OWNER)
    assert_event_emitted(tx, shrine.contract_address, "RoleRevoked", [auth_function, b])
    b_authorized = (await shrine.has_role(auth_function, b).execute()).result.has_role
    assert b_authorized == FALSE
    b_role = (await shrine.get_roles(b).execute()).result.roles
    assert b_role == 0

    # Calling an authorized function with an unauthorized address - should fail
    with pytest.raises(StarkException):
        await shrine.set_ceiling(WAD_SCALE).execute(caller_address=b)


#
# Tests - Yin parameters
#


@pytest.mark.asyncio
async def test_set_ceiling(shrine):
    new_ceiling = to_wad(20_000_000)
    tx = await shrine.set_ceiling(new_ceiling).execute(caller_address=SHRINE_OWNER)
    assert_event_emitted(tx, shrine.contract_address, "CeilingUpdated", [new_ceiling])
    assert (await shrine.get_ceiling().execute()).result.ceiling == new_ceiling


@pytest.mark.asyncio
async def test_set_ceiling_unauthorized(shrine):
    with pytest.raises(StarkException):
        await shrine.set_ceiling(1).execute(caller_address=BAD_GUY)


@pytest.mark.parametrize("new_ceiling", WAD_RAY_OOB_VALUES)
@pytest.mark.asyncio
async def test_set_ceiling_out_of_bounds(shrine, new_ceiling):
    with pytest.raises(StarkException, match=r"Shrine: Value of `new_ceiling` \(-?\d+\) is out of bounds"):
        await shrine.set_ceiling(new_ceiling).execute(caller_address=SHRINE_OWNER)


#
# Tests - Yang onboarding and parameters
#


@pytest.mark.asyncio
async def test_add_yang_pass(shrine):
    g_count = len(YANGS)
    assert (await shrine.get_yangs_count().execute()).result.count == g_count

    new_yang_address = 987
    new_yang_max = to_wad(42_000)
    new_yang_threshold = to_wad(Decimal("0.6"))
    new_yang_start_price = to_wad(5)
    tx = await shrine.add_yang(new_yang_address, new_yang_max, new_yang_threshold, new_yang_start_price).execute(
        caller_address=SHRINE_OWNER
    )
    assert (await shrine.get_yangs_count().execute()).result.count == g_count + 1
    assert (await shrine.get_current_yang_price(new_yang_address).execute()).result.price == new_yang_start_price
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
    new_yang_info = (await shrine.get_yang(new_yang_address).execute()).result.yang
    assert new_yang_info.total == 0
    assert new_yang_info.max == new_yang_max

    # Check start price is correct
    new_yang_price_info = (await shrine.get_current_yang_price(new_yang_address).execute()).result
    assert new_yang_price_info.price == new_yang_start_price

    # Check threshold is correct
    actual_threshold = (await shrine.get_yang_threshold(new_yang_address).execute()).result.threshold
    assert actual_threshold == new_yang_threshold


@pytest.mark.asyncio
async def test_add_yang_duplicate_fail(shrine):
    # Test adding duplicate Yang
    with pytest.raises(StarkException, match="Shrine: Yang already exists"):
        await shrine.add_yang(
            YANG1_ADDRESS,
            YANG1_CEILING,
            YANG1_THRESHOLD,
            to_wad(YANGS[0]["start_price"]),
        ).execute(caller_address=SHRINE_OWNER)


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
        ).execute(caller_address=BAD_GUY)


@pytest.mark.parametrize("max_amt", WAD_RAY_OOB_VALUES)
@pytest.mark.asyncio
async def test_add_yang_max_out_of_bounds(shrine, max_amt):
    with pytest.raises(StarkException, match=r"Shrine: Value of `max` \(-?\d+\) is out of bounds"):
        await shrine.add_yang(123, max_amt, YANG1_THRESHOLD, to_wad(YANGS[0]["start_price"])).execute(
            caller_address=SHRINE_OWNER
        )


@pytest.mark.asyncio
async def test_set_threshold(shrine):
    # test setting to normal value
    value = 90 * RAY_PERCENT
    tx = await shrine.set_threshold(YANG1_ADDRESS, value).execute(caller_address=SHRINE_OWNER)
    assert_event_emitted(tx, shrine.contract_address, "ThresholdUpdated", [YANG1_ADDRESS, value])
    assert (await shrine.get_yang_threshold(YANG1_ADDRESS).execute()).result.threshold == value

    # test setting to max value
    max_threshold = RAY_SCALE
    tx = await shrine.set_threshold(YANG1_ADDRESS, max_threshold).execute(caller_address=SHRINE_OWNER)
    assert_event_emitted(tx, shrine.contract_address, "ThresholdUpdated", [YANG1_ADDRESS, max_threshold])
    assert (await shrine.get_yang_threshold(YANG1_ADDRESS).execute()).result.threshold == max_threshold


@pytest.mark.asyncio
async def test_set_threshold_exceeds_max(shrine):
    # test setting over the limit
    max = RAY_SCALE
    with pytest.raises(StarkException, match="Shrine: Threshold exceeds 100%"):
        await shrine.set_threshold(YANG1_ADDRESS, max + 1).execute(caller_address=SHRINE_OWNER)


@pytest.mark.parametrize("threshold", WAD_RAY_OOB_VALUES)
@pytest.mark.asyncio
async def test_set_threshold_out_of_bounds(shrine, threshold):
    with pytest.raises(StarkException, match=r"Shrine: Value of `new_threshold` \(-?\d+\) is out of bounds"):
        await shrine.set_threshold(YANG1_ADDRESS, threshold).execute(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_set_threshold_unauthorized(shrine):
    value = 90 * RAY_PERCENT
    # test calling the func unauthorized
    with pytest.raises(StarkException):
        await shrine.set_threshold(YANG1_ADDRESS, value).execute(caller_address=BAD_GUY)


@pytest.mark.asyncio
async def test_set_threshold_invalid_yang(shrine):
    with pytest.raises(StarkException, match="Shrine: Yang does not exist"):
        await shrine.set_threshold(FAUX_YANG_ADDRESS, to_wad(1000)).execute(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_set_yang_max(shrine):
    async def set_and_assert(new_yang_max):
        orig_yang = (await shrine.get_yang(YANG1_ADDRESS).execute()).result.yang
        tx = await shrine.set_yang_max(YANG1_ADDRESS, new_yang_max).execute(caller_address=SHRINE_OWNER)
        assert_event_emitted(
            tx,
            shrine.contract_address,
            "YangUpdated",
            [YANG1_ADDRESS, orig_yang.total, new_yang_max],
        )

        updated_yang = (await shrine.get_yang(YANG1_ADDRESS).execute()).result.yang
        assert updated_yang.total == orig_yang.total
        assert updated_yang.max == new_yang_max

    # test increasing the max
    new_yang_max = YANG1_CEILING * 2
    await set_and_assert(new_yang_max)

    # test decreasing the max
    new_yang_max = YANG1_CEILING - 1
    await set_and_assert(new_yang_max)

    # test decreasing the max below yang.total
    deposit_amt = to_wad(100)
    # Deposit 100 yang tokens
    await shrine.deposit(YANG1_ADDRESS, TROVE_1, deposit_amt).execute(caller_address=SHRINE_OWNER)

    new_yang_max = deposit_amt - to_wad(1)
    await set_and_assert(new_yang_max)  # update yang_max to a value smaller than the total amount currently deposited

    # This should fail, since yang.total exceeds yang.max
    with pytest.raises(
        StarkException,
        match="Shrine: Exceeds maximum amount of Yang allowed for system",
    ):
        await shrine.deposit(YANG1_ADDRESS, TROVE_1, deposit_amt).execute(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_set_yang_max_invalid_yang(shrine):
    # test calling with a non-existing yang_address
    with pytest.raises(StarkException, match="Shrine: Yang does not exist"):
        await shrine.set_yang_max(FAUX_YANG_ADDRESS, YANG1_CEILING - 1).execute(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_set_yang_max_unauthorized(shrine):
    with pytest.raises(StarkException):
        await shrine.set_yang_max(YANG1_ADDRESS, 2**251).execute(caller_address=BAD_GUY)


@pytest.mark.parametrize("max_amt", WAD_RAY_OOB_VALUES)
@pytest.mark.asyncio
async def test_set_yang_max_out_of_bounds(shrine, max_amt):
    with pytest.raises(StarkException, match=r"Shrine: Value of `new_max` \(-?\d+\) is out of bounds"):
        await shrine.set_yang_max(YANG1_ADDRESS, max_amt).execute(caller_address=SHRINE_OWNER)


#
# Tests - Shrine kill
#


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_kill(shrine):
    # Check shrine is live
    is_live = (await shrine.get_live().execute()).result.is_live
    assert is_live == TRUE

    tx = await shrine.kill().execute(caller_address=SHRINE_OWNER)
    assert_event_emitted(tx, shrine.contract_address, "Killed")

    # Check shrine is not live
    is_live = (await shrine.get_live().execute()).result.is_live
    assert is_live == FALSE

    # Check deposit fails
    with pytest.raises(StarkException, match="Shrine: System is not live"):
        await shrine.deposit(YANG1_ADDRESS, TROVE_1, to_wad(10)).execute(caller_address=SHRINE_OWNER)

    # Check forge fails
    with pytest.raises(StarkException, match="Shrine: System is not live"):
        await shrine.forge(TROVE1_OWNER, TROVE_1, to_wad(100)).execute(caller_address=SHRINE_OWNER)

    # Test withdraw pass
    await shrine.withdraw(YANG1_ADDRESS, TROVE_1, to_wad(1)).execute(caller_address=SHRINE_OWNER)

    # Test melt pass
    await shrine.melt(TROVE1_OWNER, TROVE_1, to_wad(100)).execute(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_unauthorized_kill(shrine):
    # test calling func unauthorized
    with pytest.raises(StarkException):
        await shrine.kill().execute(caller_address=BAD_GUY)


#
# Tests - Price and multiplier updates
#


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_advance(starknet, shrine):
    timestamp = get_block_timestamp(starknet)
    interval = get_interval(timestamp)
    yang_price_info = (await shrine.get_yang_price(YANG1_ADDRESS, interval - 1).execute()).result

    new_price = to_wad(YANGS[0]["start_price"] + 1)
    advance = await shrine.advance(YANG1_ADDRESS, new_price).execute(caller_address=SHRINE_OWNER)

    expected_cumulative = int(yang_price_info.cumulative_price + new_price)

    # Test event emitted
    assert_event_emitted(
        advance,
        shrine.contract_address,
        "YangPriceUpdated",
        [YANG1_ADDRESS, new_price, expected_cumulative, interval],
    )

    # Test yang price is updated
    updated_yang_price_info = (await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result
    assert updated_yang_price_info.price == new_price
    assert updated_yang_price_info.cumulative_price == expected_cumulative
    assert updated_yang_price_info.interval == interval


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_advance_unauthorized(shrine):
    with pytest.raises(StarkException):
        await shrine.advance(YANG1_ADDRESS, to_wad(YANGS[0]["start_price"])).execute(caller_address=BAD_GUY)


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_advance_invalid_yang(shrine):
    with pytest.raises(StarkException, match="Shrine: Yang does not exist"):
        await shrine.advance(FAUX_YANG_ADDRESS, to_wad(YANGS[0]["start_price"])).execute(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_advance_out_of_bounds(shrine):
    for val in WAD_RAY_OOB_VALUES:
        with pytest.raises(StarkException, match=r"Shrine: Value of `price` \(-?\d+\) is out of bounds"):
            await shrine.advance(YANG1_ADDRESS, val).execute(caller_address=SHRINE_OWNER)

    with pytest.raises(StarkException, match="Shrine: Cumulative price is out of bounds"):
        await shrine.advance(YANG1_ADDRESS, WAD_RAY_BOUND - 1).execute(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_set_multiplier(starknet, shrine):
    timestamp = get_block_timestamp(starknet)
    interval = get_interval(timestamp)
    multiplier_info = (await shrine.get_multiplier(interval - 1).execute()).result

    new_multiplier_value = RAY_SCALE + RAY_SCALE // 2
    update = await shrine.set_multiplier(new_multiplier_value).execute(caller_address=SHRINE_OWNER)

    expected_cumulative = int(multiplier_info.cumulative_multiplier + new_multiplier_value)

    # Test event emitted
    assert_event_emitted(
        update,
        shrine.contract_address,
        "MultiplierUpdated",
        [new_multiplier_value, expected_cumulative, interval],
    )

    # Test multiplier is updated
    updated_multiplier_info = (await shrine.get_current_multiplier().execute()).result
    assert updated_multiplier_info.multiplier == new_multiplier_value
    assert updated_multiplier_info.cumulative_multiplier == expected_cumulative
    assert updated_multiplier_info.interval == interval


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_set_multiplier_unauthorized(shrine):
    with pytest.raises(StarkException):
        await shrine.set_multiplier(RAY_SCALE).execute(caller_address=BAD_GUY)


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_set_multiplier_out_of_bounds(shrine):
    for val in WAD_RAY_OOB_VALUES:
        with pytest.raises(StarkException, match=r"Shrine: Value of `new_multiplier` \(-?\d+\) is out of bounds"):
            await shrine.set_multiplier(val).execute(caller_address=SHRINE_OWNER)

    with pytest.raises(StarkException, match="Shrine: Cumulative multiplier is out of bounds"):
        await shrine.set_multiplier(WAD_RAY_BOUND - 1).execute(caller_address=SHRINE_OWNER)


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
    deposit = await shrine.deposit(YANG1_ADDRESS, TROVE_1, deposit_amt_wad).execute(caller_address=SHRINE_OWNER)

    collect_gas_cost("shrine/deposit", deposit, 4, 1)
    assert_event_emitted(
        deposit,
        shrine.contract_address,
        "YangUpdated",
        [YANG1_ADDRESS, deposit_amt_wad, YANG1_CEILING],
    )
    assert_event_emitted(
        deposit,
        shrine.contract_address,
        "DepositUpdated",
        [YANG1_ADDRESS, TROVE_1, deposit_amt_wad],
    )

    yang = (await shrine.get_yang(YANG1_ADDRESS).execute()).result.yang
    assert yang.total == deposit_amt_wad

    amt = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert amt == deposit_amt_wad

    # Check max forge amount
    yang_price = from_wad((await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result.price)
    max_forge_amt = from_wad((await shrine.get_max_forge(TROVE_1).execute()).result.max)
    expected_limit = calculate_max_forge([yang_price], [from_wad(deposit_amt_wad)], [from_ray(YANG1_THRESHOLD)])
    assert_equalish(max_forge_amt, expected_limit)


@pytest.mark.asyncio
async def test_shrine_deposit_invalid_yang_fail(shrine):
    # Invalid yang ID that has not been added
    with pytest.raises(StarkException, match="Shrine: Yang does not exist"):
        await shrine.deposit(789, TROVE_1, to_wad(1)).execute(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_shrine_deposit_unauthorized(shrine):
    with pytest.raises(StarkException):
        await shrine.deposit(YANG1_ADDRESS, TROVE_1, INITIAL_DEPOSIT_WAD).execute(caller_address=BAD_GUY)


@pytest.mark.usefixtures("shrine_deposit")
@pytest.mark.asyncio
async def test_shrine_deposit_exceeds_max(shrine):
    deposit_amt = YANG1_CEILING - INITIAL_DEPOSIT_WAD + 1
    # Checks for shrine deposit that would exceed the max
    with pytest.raises(
        StarkException,
        match="Shrine: Exceeds maximum amount of Yang allowed for system",
    ):
        await shrine.deposit(YANG1_ADDRESS, TROVE_1, deposit_amt).execute(caller_address=SHRINE_OWNER)


@pytest.mark.parametrize("deposit_amt", WAD_RAY_OOB_VALUES)
@pytest.mark.asyncio
async def test_shrine_deposit_amount_out_of_bounds(shrine, deposit_amt):
    with pytest.raises(StarkException, match=r"Shrine: Value of `amount` \(-?\d+\) is out of bounds"):
        await shrine.deposit(YANG1_ADDRESS, TROVE_1, deposit_amt).execute(caller_address=SHRINE_OWNER)


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
    withdraw = await shrine.withdraw(YANG1_ADDRESS, TROVE_1, withdraw_amt_wad).execute(caller_address=SHRINE_OWNER)

    collect_gas_cost("shrine/withdraw", withdraw, 4, 1)

    remaining_amt_wad = INITIAL_DEPOSIT_WAD - withdraw_amt_wad

    assert_event_emitted(
        withdraw,
        shrine.contract_address,
        "YangUpdated",
        [YANG1_ADDRESS, remaining_amt_wad, YANG1_CEILING],
    )

    assert_event_emitted(
        withdraw,
        shrine.contract_address,
        "DepositUpdated",
        [YANG1_ADDRESS, TROVE_1, remaining_amt_wad],
    )

    yang = (await shrine.get_yang(YANG1_ADDRESS).execute()).result.yang
    assert yang.total == remaining_amt_wad

    amt = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert amt == remaining_amt_wad

    ltv = (await shrine.get_trove_info(TROVE_1).execute()).result.ltv
    assert ltv == 0

    is_healthy = (await shrine.is_healthy(TROVE_1).execute()).result.healthy
    assert is_healthy == TRUE

    # Check max forge amount
    yang_price = from_wad((await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result.price)
    max_forge_amt = from_wad((await shrine.get_max_forge(TROVE_1).execute()).result.max)
    expected_limit = calculate_max_forge([yang_price], [from_wad(remaining_amt_wad)], [from_ray(YANG1_THRESHOLD)])
    assert_equalish(max_forge_amt, expected_limit)


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.parametrize("withdraw_amt_wad", [0, to_wad(Decimal("1E-18")), to_wad(1), to_wad(5)])
@pytest.mark.asyncio
async def test_shrine_forged_partial_withdraw_pass(shrine, withdraw_amt_wad):
    price = (await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result.price

    initial_amt_wad = INITIAL_DEPOSIT_WAD
    remaining_amt_wad = initial_amt_wad - withdraw_amt_wad

    withdraw = await shrine.withdraw(YANG1_ADDRESS, TROVE_1, withdraw_amt_wad).execute(caller_address=SHRINE_OWNER)

    assert_event_emitted(
        withdraw,
        shrine.contract_address,
        "YangUpdated",
        [YANG1_ADDRESS, remaining_amt_wad, YANG1_CEILING],
    )

    assert_event_emitted(
        withdraw,
        shrine.contract_address,
        "DepositUpdated",
        [YANG1_ADDRESS, TROVE_1, remaining_amt_wad],
    )

    yang = (await shrine.get_yang(YANG1_ADDRESS).execute()).result.yang
    assert yang.total == remaining_amt_wad

    amt = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert amt == remaining_amt_wad

    ltv = (await shrine.get_trove_info(TROVE_1).execute()).result.ltv
    expected_ltv = from_wad(FORGE_AMT_WAD) / (from_wad(price) * from_wad(remaining_amt_wad))
    assert_equalish(from_ray(ltv), expected_ltv)

    is_healthy = (await shrine.is_healthy(TROVE_1).execute()).result.healthy
    assert is_healthy == TRUE

    # Check max forge amount
    yang0_price = from_wad((await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result.price)
    expected_max_forge_amt = calculate_max_forge(
        [yang0_price], [from_wad(remaining_amt_wad)], [from_ray(YANG1_THRESHOLD)]
    ) - from_wad(FORGE_AMT_WAD)
    max_forge_amt = from_wad((await shrine.get_max_forge(TROVE_1).execute()).result.max)
    assert_equalish(max_forge_amt, expected_max_forge_amt)


@pytest.mark.asyncio
async def test_shrine_withdraw_invalid_yang_fail(shrine):

    # Invalid yang ID that has not been added
    with pytest.raises(StarkException, match="Shrine: Yang does not exist"):
        await shrine.withdraw(789, TROVE_1, to_wad(1)).execute(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_shrine_withdraw_insufficient_yang_fail(shrine, shrine_deposit):
    with pytest.raises(StarkException, match="Shrine: Insufficient yang"):
        await shrine.withdraw(YANG1_ADDRESS, TROVE_1, to_wad(11)).execute(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_shrine_withdraw_zero_yang_fail(shrine):
    with pytest.raises(StarkException, match="Shrine: Insufficient yang"):
        await shrine.withdraw(YANG1_ADDRESS, TROVE_3, to_wad(1)).execute(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_shrine_withdraw_unsafe_fail(shrine):

    # Get latest price
    price = (await shrine.get_yang_price(YANG1_ADDRESS, 2 * FEED_LEN - 1).execute()).result.price
    assert price != 0

    unsafe_amt = (5000 / Decimal("0.85")) / from_wad(price)
    withdraw_amt = Decimal("10") - unsafe_amt

    with pytest.raises(StarkException, match="Shrine: Trove LTV is too high"):
        await shrine.withdraw(YANG1_ADDRESS, TROVE_1, to_wad(withdraw_amt)).execute(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("shrine_deposit")
@pytest.mark.asyncio
async def test_shrine_withdraw_unauthorized(shrine):
    with pytest.raises(StarkException):
        await shrine.withdraw(YANG1_ADDRESS, TROVE_1, INITIAL_DEPOSIT_WAD).execute(caller_address=BAD_GUY)


@pytest.mark.parametrize("withdraw_amt", WAD_RAY_OOB_VALUES)
@pytest.mark.asyncio
async def test_shrine_withdraw_amount_out_of_bounds(shrine, withdraw_amt):
    # no need to have an actual deposit in this test, the
    # amount check happens before checking balances
    with pytest.raises(StarkException, match=r"Shrine: Value of `amount` \(-?\d+\) is out of bounds"):
        await shrine.withdraw(YANG1_ADDRESS, TROVE_1, withdraw_amt).execute(caller_address=SHRINE_OWNER)


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
    forge = await shrine.forge(TROVE1_OWNER, TROVE_1, forge_amt_wad).execute(caller_address=SHRINE_OWNER)

    assert_event_emitted(forge, shrine.contract_address, "DebtTotalUpdated", [forge_amt_wad])
    assert_event_emitted(
        forge,
        shrine.contract_address,
        "TroveUpdated",
        [TROVE_1, FEED_LEN - 1, forge_amt_wad],
    )

    system_debt = (await shrine.get_total_debt().execute()).result.total_debt
    assert system_debt == forge_amt_wad

    trove = (await shrine.get_trove(TROVE_1).execute()).result.trove
    assert trove.debt == forge_amt_wad
    assert trove.charge_from == FEED_LEN - 1

    yang_price = (await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result.price
    trove_info = (await shrine.get_trove_info(TROVE_1).execute()).result
    trove_ltv = from_ray(trove_info.ltv)
    expected_ltv = Decimal(forge_amt_wad) / Decimal(10 * yang_price)
    assert_equalish(trove_ltv, expected_ltv)

    is_healthy = (await shrine.is_healthy(TROVE_1).execute()).result.healthy
    assert is_healthy == TRUE

    # Check max forge amount
    max_forge_amt = from_wad((await shrine.get_max_forge(TROVE_1).execute()).result.max)
    expected_limit = calculate_max_forge(
        [from_wad(yang_price)], [from_wad(INITIAL_DEPOSIT_WAD)], [from_ray(YANG1_THRESHOLD)]
    )
    current_debt = from_wad(trove_info.debt)
    assert_equalish(max_forge_amt, expected_limit - current_debt)


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_shrine_forge_zero_deposit_fail(shrine):
    # Forge without any yangs deposited
    with pytest.raises(StarkException, match="Shrine: Trove LTV is too high"):
        await shrine.forge(TROVE3_OWNER, TROVE_3, to_wad(1_000)).execute(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_shrine_forge_unsafe_fail(shrine):
    # Increase debt ceiling
    new_ceiling = to_wad(100_000)
    await shrine.set_ceiling(new_ceiling).execute(caller_address=SHRINE_OWNER)

    with pytest.raises(StarkException, match="Shrine: Trove LTV is too high"):
        await shrine.forge(TROVE1_OWNER, TROVE_1, to_wad(14_000)).execute(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_shrine_forge_ceiling_fail(shrine):
    # Deposit more yang
    await shrine.deposit(YANG1_ADDRESS, TROVE_1, to_wad(10)).execute(caller_address=SHRINE_OWNER)
    updated_deposit = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert updated_deposit == to_wad(20)

    with pytest.raises(StarkException, match="Shrine: Debt ceiling reached"):
        await shrine.forge(TROVE1_OWNER, TROVE_1, to_wad(15_000)).execute(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("shrine_deposit")
@pytest.mark.asyncio
async def test_shrine_forge_unauthorized(shrine):
    with pytest.raises(StarkException):
        await shrine.forge(TROVE1_OWNER, TROVE_1, FORGE_AMT_WAD).execute(caller_address=BAD_GUY)


@pytest.mark.parametrize("forge_amt", WAD_RAY_OOB_VALUES)
@pytest.mark.asyncio
async def test_shrine_forge_amount_out_of_bounds(shrine, forge_amt):
    # no need to have any setup for the test,
    # amount check happens before checking balances
    with pytest.raises(StarkException, match=r"Shrine: Value of `amount` \(-?\d+\) is out of bounds"):
        await shrine.forge(TROVE1_OWNER, TROVE_1, forge_amt).execute(caller_address=SHRINE_OWNER)


#
# Tests - Trove melt
#


@pytest.mark.usefixtures("shrine_forge", "shrine_forge_trove2")
@pytest.mark.parametrize("melt_amt_wad", [0, to_wad(Decimal("1E-18")), FORGE_AMT_WAD // 2, FORGE_AMT_WAD, 2**125])
@pytest.mark.asyncio
async def test_shrine_melt_pass(shrine, melt_amt_wad):
    price = (await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result.price

    total_debt_wad = (await shrine.get_total_debt().execute()).result.total_debt
    # Debt should be forged amount since the interval has not progressed
    estimated_debt_wad = FORGE_AMT_WAD

    melt = await shrine.melt(TROVE1_OWNER, TROVE_1, melt_amt_wad).execute(caller_address=SHRINE_OWNER)

    if melt_amt_wad > estimated_debt_wad:
        melt_amt_wad = estimated_debt_wad

    outstanding_amt_wad = estimated_debt_wad - melt_amt_wad
    expected_total_debt_wad = total_debt_wad - melt_amt_wad

    assert_event_emitted(melt, shrine.contract_address, "DebtTotalUpdated", [expected_total_debt_wad])

    assert_event_emitted(
        melt,
        shrine.contract_address,
        "TroveUpdated",
        [TROVE_1, FEED_LEN - 1, outstanding_amt_wad],
    )

    system_debt = (await shrine.get_total_debt().execute()).result.total_debt
    assert system_debt == expected_total_debt_wad

    trove = (await shrine.get_trove(TROVE_1).execute()).result.trove
    assert trove.debt == outstanding_amt_wad
    assert trove.charge_from == FEED_LEN - 1

    shrine_ltv = (await shrine.get_trove_info(TROVE_1).execute()).result.ltv
    expected_ltv = from_wad(outstanding_amt_wad) / (INITIAL_DEPOSIT * from_wad(price))
    assert_equalish(from_ray(shrine_ltv), expected_ltv)

    is_healthy = (await shrine.is_healthy(TROVE_1).execute()).result.healthy
    assert is_healthy == TRUE

    # Check max forge amount
    yang_price = from_wad((await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result.price)
    max_forge_amt = from_wad((await shrine.get_max_forge(TROVE_1).execute()).result.max)
    expected_max_forge_amt = calculate_max_forge(
        [yang_price], [from_wad(INITIAL_DEPOSIT_WAD)], [from_ray(YANG1_THRESHOLD)]
    ) - from_wad(outstanding_amt_wad)
    assert_equalish(max_forge_amt, expected_max_forge_amt)


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_shrine_melt_unauthorized(shrine):
    estimated_debt = (await shrine.get_trove_info(TROVE_1).execute()).result.debt
    with pytest.raises(StarkException):
        await shrine.melt(TROVE1_OWNER, TROVE_1, estimated_debt).execute(caller_address=BAD_GUY)


@pytest.mark.parametrize("melt_amt", WAD_RAY_OOB_VALUES)
@pytest.mark.asyncio
async def test_shrine_melt_amount_out_of_bounds(shrine, melt_amt):
    # no need to have any setup for the test,
    # amount check happens before checking balances
    with pytest.raises(StarkException, match=r"Shrine: Value of `amount` \(-?\d+\) is out of bounds"):
        await shrine.melt(TROVE1_OWNER, TROVE_1, melt_amt).execute(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("shrine_forge", "shrine_forge_trove2")
@pytest.mark.asyncio
async def test_shrine_melt_insufficient_yin(shrine):
    # Set up trove 2 to have less yin than trove 1's debt
    await shrine.transfer(TROVE1_OWNER, to_uint(1)).execute(caller_address=TROVE2_OWNER)
    with pytest.raises(StarkException, match="Shrine: Not enough yin to melt debt"):
        await shrine.melt(TROVE2_OWNER, TROVE_1, WAD_RAY_BOUND).execute(caller_address=SHRINE_OWNER)


#
# Tests - Trove estimate and charge
#


@pytest.mark.asyncio
async def test_compound(shrine, estimate):
    start_interval = FEED_LEN - 1
    end_interval = start_interval + FEED_LEN

    trove1 = (await shrine.get_trove(TROVE_1).execute()).result.trove
    assert trove1.charge_from == FEED_LEN - 1

    trove2 = (await shrine.get_trove(TROVE_2).execute()).result.trove
    assert trove2.charge_from == FEED_LEN - 1

    last_updated = (await shrine.get_yang_price(YANG1_ADDRESS, end_interval).execute()).result.price
    assert last_updated != 0

    estimated_trove1_debt, estimated_trove2_debt, expected_debt, expected_avg_price = estimate

    # Convert wad values to decimal
    adjusted_estimated_trove1_debt = from_wad(estimated_trove1_debt)
    adjusted_estimated_trove2_debt = from_wad(estimated_trove2_debt)

    # Check values
    assert_equalish(adjusted_estimated_trove1_debt, expected_debt)
    assert_equalish(adjusted_estimated_trove2_debt, expected_debt)

    # Check average price
    avg_price = from_wad((await shrine.get_avg_price(YANG1_ID, start_interval, end_interval).execute()).result.price)
    assert_equalish(avg_price, expected_avg_price)


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "method,calldata",
    [
        ("deposit", [YANG1_ADDRESS, 1, 0]),  # yang_address, trove_id, amount
        ("withdraw", [YANG1_ADDRESS, 1, 0]),  # yang_address, trove_id, amount
        ("forge", [1, 1, 0]),  # user_address, trove_id, amount
        ("melt", [1, 1, 0]),  # user_address, trove_id, amount
        (
            "move_yang",
            [YANG1_ADDRESS, 1, 2, 0],
        ),  # yang_address, src_trove_id, dst_trove_id, amount
    ],
)
async def test_charge_scenario_1(shrine, estimate, method, calldata):
    """
    Test for `charge` with all intervals between start and end inclusive updated.

    T+START--------------T+END
    """

    estimated_trove1_debt, estimated_trove2_debt, expected_debt, expected_avg_price = estimate

    start_interval = FEED_LEN - 1
    end_interval = start_interval + FEED_LEN

    # Calculate expected system debt
    if method == "move_yang":
        expected_system_debt = estimated_trove1_debt + estimated_trove2_debt
    else:
        expected_system_debt = estimated_trove1_debt + FORGE_AMT_WAD

    old_trove1 = (await shrine.get_trove(TROVE_1).execute()).result.trove
    old_trove2 = (await shrine.get_trove(TROVE_2).execute()).result.trove

    # Test `charge` by calling the method without any value
    tx = await getattr(shrine, method)(*calldata).execute(caller_address=SHRINE_OWNER)

    # Get updated system info
    new_system_debt = (await shrine.get_total_debt().execute()).result.total_debt
    assert new_system_debt == expected_system_debt

    # Get updated trove information for Trove ID 1
    updated_trove1 = (await shrine.get_trove(TROVE_1).execute()).result.trove
    adjusted_trove_debt = from_wad(updated_trove1.debt)

    # Sanity check
    assert estimated_trove1_debt > from_wad(old_trove1.debt)

    assert_equalish(adjusted_trove_debt, expected_debt)
    assert updated_trove1.charge_from == end_interval

    assert_event_emitted(tx, shrine.contract_address, "DebtTotalUpdated", [expected_system_debt])
    assert_event_emitted(
        tx,
        shrine.contract_address,
        "TroveUpdated",
        [TROVE_1, updated_trove1.charge_from, updated_trove1.debt],
    )

    # `charge` should not have any effect if `Trove.charge_from` is the current interval
    await getattr(shrine, method)(*calldata).execute(caller_address=SHRINE_OWNER)
    redundant_trove1 = (await shrine.get_trove(TROVE_1).execute()).result.trove
    assert updated_trove1 == redundant_trove1

    # Check average price
    avg_price = from_wad((await shrine.get_avg_price(YANG1_ID, start_interval, end_interval).execute()).result.price)
    assert_equalish(avg_price, expected_avg_price)

    # Check Trove ID 2 if method is `move_yang`
    if method == "move_yang":
        # Get updated trove information for Trove ID 2
        updated_trove2 = (await shrine.get_trove(TROVE_2).execute()).result.trove
        adjusted_trove_debt = from_wad(updated_trove2.debt)
        assert estimated_trove2_debt > from_wad(old_trove2.debt)

        assert_equalish(adjusted_trove_debt, expected_debt)
        assert updated_trove2.charge_from == end_interval

        assert_event_emitted(
            tx,
            shrine.contract_address,
            "TroveUpdated",
            [TROVE_2, updated_trove2.charge_from, updated_trove2.debt],
        )

        # `charge` should not have any effect if `Trove.charge_from` is current interval + 1
        await getattr(shrine, method)(*calldata).execute(caller_address=SHRINE_OWNER)
        redundant_trove2 = (await shrine.get_trove(TROVE_2).execute()).result.trove
        assert updated_trove2 == redundant_trove2


# Skip index 0 because initial price is set in `add_yang`
@pytest.mark.asyncio
@pytest.mark.parametrize(
    "update_feeds_intermittent",
    [0, 1, FEED_LEN - 2],
    indirect=["update_feeds_intermittent"],
)
async def test_charge_scenario_1b(starknet, shrine, update_feeds_intermittent):
    """
    Slight variation of `test_charge_scenario_1` where there is an interval between start and end
    that does not have a price update.

    `X` in the diagram below indicates a missed interval.

    T+START------X-------T+END

    The `update_feeds_intermittent` fixture returns a tuple of the index that is skipped,
    and a list for the price feed.

    The index is with reference to the second set of feeds.
    Therefore, writes to the contract takes in an additional offset of FEED_LEN for the initial
    set of feeds in `shrine` fixture.
    """

    idx, price_feed = update_feeds_intermittent

    start_interval = FEED_LEN - 1
    end_interval = FEED_LEN * 2 - 1
    skipped_interval = idx + FEED_LEN

    # Assert that value for skipped index is set to 0
    assert (await shrine.get_yang_price(YANG1_ADDRESS, skipped_interval).execute()).result.price == 0
    assert (await shrine.get_multiplier(skipped_interval).execute()).result.multiplier == 0

    # Get yang price and multiplier value at `trove.charge_from`
    original_trove = (await shrine.get_trove(TROVE_1).execute()).result.trove
    original_trove_debt = original_trove.debt

    start_cumulative_price = (
        await shrine.get_yang_price(YANG1_ADDRESS, original_trove.charge_from).execute()
    ).result.cumulative_price
    start_cumulative_multiplier = (
        await shrine.get_multiplier(original_trove.charge_from).execute()
    ).result.cumulative_multiplier

    # Getting the current yang price and multiplier value
    end_cumulative_price = (await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result.cumulative_price
    end_cumulative_multiplier = (await shrine.get_current_multiplier().execute()).result.cumulative_multiplier

    # Test 'charge' by calling deposit without any value
    await shrine.deposit(YANG1_ADDRESS, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)
    updated_trove = (await shrine.get_trove(TROVE_1).execute()).result.trove
    updated_trove_debt = updated_trove.debt

    # Sanity check that compounded debt is greater than original debt
    assert updated_trove_debt > original_trove_debt

    expected_avg_price = (from_wad(end_cumulative_price) - from_wad(start_cumulative_price)) / FEED_LEN
    expected_avg_multiplier = (from_ray(end_cumulative_multiplier) - from_ray(start_cumulative_multiplier)) / FEED_LEN

    expected_debt = compound_with_avg_price(
        [Decimal("10")],
        [from_ray(YANG1_THRESHOLD)],
        [expected_avg_price],
        expected_avg_multiplier,
        FEED_LEN,
        from_wad(original_trove_debt),
    )

    assert_equalish(from_wad(updated_trove_debt), expected_debt)
    assert updated_trove.charge_from == end_interval

    # Check average price
    avg_price = from_wad((await shrine.get_avg_price(YANG1_ID, start_interval, end_interval).execute()).result.price)
    assert_equalish(avg_price, expected_avg_price)


@pytest.mark.parametrize("intervals_before_last_charge", [2, 4, 7, 10])
@pytest.mark.parametrize("intervals_after_start", [1, 5, 10, 50])
@pytest.mark.usefixtures("estimate")
@pytest.mark.asyncio
async def test_charge_scenario_2(starknet, shrine, intervals_before_last_charge, intervals_after_start):
    """
    Test for `charge` with "missed" price and multiplier updates since before the start interval,
    Start_interval does not have a price or multiplier update.
    End interval does not have a price or multiplier update.

    T+LAST_UPDATED       T+START-------------T+END
    """
    # Advance timestamp by 2 intervals and set price - `T+LAST_UPDATED`
    current_timestamp = get_block_timestamp(starknet)
    new_timestamp = current_timestamp + 2 * TIME_INTERVAL
    set_block_timestamp(starknet, new_timestamp)

    start_price = Decimal("2_005")
    start_price_wad = to_wad(start_price)

    await shrine.advance(YANG1_ADDRESS, start_price_wad).execute(caller_address=SHRINE_OWNER)
    await shrine.set_multiplier(RAY_SCALE).execute(caller_address=SHRINE_OWNER)

    # Advnce timestamp by `intervals_before_last_charge` intervals and charge using a zero deposit - `T+START`
    new_timestamp = new_timestamp + intervals_before_last_charge * TIME_INTERVAL
    set_block_timestamp(starknet, new_timestamp)
    start_interval = get_interval(new_timestamp)

    await shrine.deposit(YANG1_ADDRESS, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)

    original_trove_debt = from_wad((await shrine.get_trove(TROVE_1).execute()).result.trove.debt)

    # Advance timestamp by `intervals_after_start` and charge - `T+END`
    new_timestamp = new_timestamp + intervals_after_start * TIME_INTERVAL
    set_block_timestamp(starknet, new_timestamp)
    end_interval = get_interval(new_timestamp)

    await shrine.deposit(YANG1_ADDRESS, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)

    updated_trove_debt = from_wad((await shrine.get_trove(TROVE_1).execute()).result.trove.debt)

    # Sanity check that compounded debt is greater than original debt
    assert updated_trove_debt > original_trove_debt

    expected_debt = compound_with_avg_price(
        [Decimal(INITIAL_DEPOSIT)],
        [from_ray(YANG1_THRESHOLD)],
        [start_price],
        Decimal("1"),
        intervals_after_start,
        original_trove_debt,
    )
    assert_equalish(expected_debt, updated_trove_debt)

    # Check average price
    avg_price = from_wad((await shrine.get_avg_price(YANG1_ID, start_interval, end_interval).execute()).result.price)
    assert avg_price == start_price


@pytest.mark.parametrize("interval_count", [1, 5, 10, 50])
@pytest.mark.usefixtures("estimate")
@pytest.mark.asyncio
async def test_charge_scenario_3(starknet, shrine, interval_count):
    """
    Test for `charge` with "missed" price and multiplier updates after the start interval,
    Start interval has a price and multiplier update.
    End interval does not have a price or multiplier update.

    T+START/LAST_UPDATED-------------T+END
    """
    start_price = Decimal("2_005")
    start_price_wad = to_wad(start_price)
    start_interval = get_interval(get_block_timestamp(starknet))

    await shrine.advance(YANG1_ADDRESS, start_price_wad).execute(caller_address=SHRINE_OWNER)

    # Charge trove after initial set of price feeds by calling deposit with 0 - `T+START/LAST_UPDATED`
    await shrine.deposit(YANG1_ADDRESS, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)

    # Get yang price and multiplier value at `trove.charge_from`
    original_trove = (await shrine.get_trove(TROVE_1).execute()).result.trove
    original_trove_debt = from_wad(original_trove.debt)

    # Advance timestamp by given intervals - `T+END`
    current_timestamp = get_block_timestamp(starknet)
    new_timestamp = current_timestamp + interval_count * TIME_INTERVAL
    set_block_timestamp(starknet, new_timestamp)
    end_interval = get_interval(new_timestamp)

    # Charge trove again
    await shrine.deposit(YANG1_ADDRESS, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)

    updated_trove = (await shrine.get_trove(TROVE_1).execute()).result.trove
    updated_trove_debt = from_wad(updated_trove.debt)

    # Sanity check that compounded debt is greater than original debt
    assert updated_trove_debt > original_trove_debt

    expected_debt = compound_with_avg_price(
        [Decimal(INITIAL_DEPOSIT)],
        [from_ray(YANG1_THRESHOLD)],
        [start_price],
        Decimal("1"),
        interval_count,
        original_trove_debt,
    )
    assert_equalish(expected_debt, updated_trove_debt)

    # Check average price
    avg_price = from_wad((await shrine.get_avg_price(YANG1_ID, start_interval, end_interval).execute()).result.price)
    assert avg_price == start_price


@pytest.mark.parametrize("last_updated_interval_after_start", [2, 5, 10])
@pytest.mark.parametrize("intervals_after_last_update", [1, 5, 10, 50])
@pytest.mark.usefixtures("estimate")
@pytest.mark.asyncio
async def test_charge_scenario_4(starknet, shrine, last_updated_interval_after_start, intervals_after_last_update):
    """
    Test for `charge` with "missed" price and multiplier updates from `intervals_after_last_update` intervals
    after start interval.
    Start interval has a price and multiplier update.
    End interval does not have a price or multiplier update.

    T+START-------T+LAST_UPDATED------T+END
    """
    start_interval = get_interval(get_block_timestamp(starknet))

    # Charge with zero deposit - `T+START`
    await shrine.deposit(YANG1_ADDRESS, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)

    original_trove = (await shrine.get_trove(TROVE_1).execute()).result.trove
    original_trove_debt = from_wad(original_trove.debt)

    _, start_cumulative_price, _ = (await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result

    # Advance timestamp by `last_updated_interval_after_start` intervals and set price - `T+LAST_UPDATED`
    current_timestamp = get_block_timestamp(starknet)
    new_timestamp = current_timestamp + last_updated_interval_after_start * TIME_INTERVAL
    set_block_timestamp(starknet, new_timestamp)

    available_end_price = Decimal("2_110")
    available_end_price_wad = to_wad(available_end_price)
    await shrine.advance(YANG1_ADDRESS, available_end_price_wad).execute(caller_address=SHRINE_OWNER)
    await shrine.set_multiplier(RAY_SCALE).execute(caller_address=SHRINE_OWNER)

    _, end_cumulative_price, _ = (await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result

    # Advnce timestamp by `intervals_after_last_update` intervals and charge using a zero deposit - `T+END`
    new_timestamp = new_timestamp + intervals_after_last_update * TIME_INTERVAL
    set_block_timestamp(starknet, new_timestamp)
    end_interval = get_interval(new_timestamp)

    await shrine.deposit(YANG1_ADDRESS, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)
    updated_trove = (await shrine.get_trove(TROVE_1).execute()).result.trove
    updated_trove_debt = from_wad(updated_trove.debt)

    # Sanity check that compounded debt is greater than original debt
    assert updated_trove_debt > original_trove_debt

    intervals_lapsed = last_updated_interval_after_start + intervals_after_last_update

    expected_avg_price = (
        (from_wad(end_cumulative_price) - from_wad(start_cumulative_price))
        + available_end_price * intervals_after_last_update
    ) / intervals_lapsed

    expected_debt = compound_with_avg_price(
        [Decimal(INITIAL_DEPOSIT)],
        [from_ray(YANG1_THRESHOLD)],
        [expected_avg_price],
        Decimal("1"),
        intervals_lapsed,
        original_trove_debt,
    )
    assert_equalish(expected_debt, updated_trove_debt)

    # Check average price
    avg_price = from_wad((await shrine.get_avg_price(YANG1_ID, start_interval, end_interval).execute()).result.price)
    assert_equalish(avg_price, expected_avg_price)


@pytest.mark.parametrize("missed_intervals_before_start", [2, 4, 7, 10])
@pytest.mark.parametrize("last_updated_interval_after_start", [2, 4, 7, 10])
@pytest.mark.parametrize("intervals_after_last_update", [1, 5, 10, 50])
@pytest.mark.usefixtures("estimate")
@pytest.mark.asyncio
async def test_charge_scenario_5(
    starknet, shrine, missed_intervals_before_start, last_updated_interval_after_start, intervals_after_last_update
):
    """
    Test for `charge` with "missed" price and multiplier updates from `intervals_after_last_update`
    intervals after start interval onwards.
    Start interval does not have a price or multiplier update.
    End interval does not have a price or multiplier update.

    T+LAST_UPDATED_BEFORE_START       T+START----T+LAST_UPDATED---------T+END
    """
    # Advance timestamp by 2 intervals and set price - `T+LAST_UPDATED_BEFORE_START`
    current_timestamp = get_block_timestamp(starknet)
    new_timestamp = current_timestamp + 2 * TIME_INTERVAL
    set_block_timestamp(starknet, new_timestamp)

    available_start_price = Decimal("2_005")
    available_start_price_wad = to_wad(available_start_price)

    await shrine.advance(YANG1_ADDRESS, available_start_price_wad).execute(caller_address=SHRINE_OWNER)
    await shrine.set_multiplier(RAY_SCALE).execute(caller_address=SHRINE_OWNER)

    _, available_start_cumulative_price, _ = (await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result

    # Advnce timestamp by `missed_intervals_before_start` intervals and charge using a zero deposit - `T+START`
    new_timestamp = new_timestamp + missed_intervals_before_start * TIME_INTERVAL
    set_block_timestamp(starknet, new_timestamp)
    start_interval = get_interval(new_timestamp)

    await shrine.deposit(YANG1_ADDRESS, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)

    original_trove = (await shrine.get_trove(TROVE_1).execute()).result.trove
    original_trove_debt = from_wad(original_trove.debt)

    # Advance timestamp by `last_updated_interval_after_start` and set price - `T+LAST_UPDATED`
    new_timestamp = new_timestamp + last_updated_interval_after_start * TIME_INTERVAL
    set_block_timestamp(starknet, new_timestamp)

    available_end_price = Decimal("2_155")
    available_end_price_wad = to_wad(available_end_price)

    await shrine.advance(YANG1_ADDRESS, available_end_price_wad).execute(caller_address=SHRINE_OWNER)
    await shrine.set_multiplier(RAY_SCALE).execute(caller_address=SHRINE_OWNER)

    _, available_end_cumulative_price, _ = (await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result

    # Advance timestamp by `intervals_after_last_update` and charge - `T+END`
    new_timestamp = new_timestamp + intervals_after_last_update * TIME_INTERVAL
    set_block_timestamp(starknet, new_timestamp)
    end_interval = get_interval(new_timestamp)

    await shrine.deposit(YANG1_ADDRESS, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)
    updated_trove = (await shrine.get_trove(TROVE_1).execute()).result.trove
    updated_trove_debt = from_wad(updated_trove.debt)

    # Sanity check that compounded debt is greater than original debt
    assert updated_trove_debt > original_trove_debt

    interval_diff = Decimal(last_updated_interval_after_start + intervals_after_last_update)

    expected_avg_price = (
        from_wad(available_end_cumulative_price - available_start_cumulative_price)
        - (missed_intervals_before_start * available_start_price)
        + (intervals_after_last_update * available_end_price)
    ) / interval_diff

    expected_debt = compound_with_avg_price(
        [Decimal(INITIAL_DEPOSIT)],
        [from_ray(YANG1_THRESHOLD)],
        [expected_avg_price],
        Decimal("1"),
        interval_diff,
        original_trove_debt,
    )
    assert_equalish(expected_debt, updated_trove_debt)

    # Check average price
    avg_price = from_wad((await shrine.get_avg_price(YANG1_ID, start_interval, end_interval).execute()).result.price)
    assert_equalish(avg_price, expected_avg_price)


@pytest.mark.parametrize("missed_intervals_before_start", [2, 4, 7, 10])
@pytest.mark.parametrize("interval_count", [1, 5, 10, 50])
@pytest.mark.usefixtures("estimate")
@pytest.mark.asyncio
async def test_charge_scenario_6(starknet, shrine, missed_intervals_before_start, interval_count):
    """
    Test for `charge` with "missed" price and multiplier update at the start interval.
    Start interval does not have a price or multiplier update.
    End interval has both price and multiplier update.

    T+LAST_UPDATED_BEFORE_START       T+START-------------T+END/LAST_UPDATED
    """
    # Advance timestamp by 2 intervals and set price - `T+LAST_UPDATED_BEFORE_START`
    current_timestamp = get_block_timestamp(starknet)
    new_timestamp = current_timestamp + 2 * TIME_INTERVAL
    set_block_timestamp(starknet, new_timestamp)

    available_start_price = Decimal("2_005")
    available_start_price_wad = to_wad(available_start_price)

    await shrine.advance(YANG1_ADDRESS, available_start_price_wad).execute(caller_address=SHRINE_OWNER)
    await shrine.set_multiplier(RAY_SCALE).execute(caller_address=SHRINE_OWNER)

    _, available_start_cumulative_price, _ = (await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result

    # Advnce timestamp by `missed_intervals_before_start` intervals and charge using a zero deposit - `T+START`
    new_timestamp = new_timestamp + missed_intervals_before_start * TIME_INTERVAL
    set_block_timestamp(starknet, new_timestamp)
    start_interval = get_interval(new_timestamp)

    await shrine.deposit(YANG1_ADDRESS, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)

    original_trove = (await shrine.get_trove(TROVE_1).execute()).result.trove
    original_trove_debt = from_wad(original_trove.debt)

    # Advance timestamp by `interval_count` and charge - `T+END/LAST_UPDATED`
    new_timestamp = new_timestamp + interval_count * TIME_INTERVAL
    set_block_timestamp(starknet, new_timestamp)
    end_interval = get_interval(new_timestamp)

    available_end_price = Decimal("2_255")
    available_end_price_wad = to_wad(available_end_price)

    await shrine.advance(YANG1_ADDRESS, available_end_price_wad).execute(caller_address=SHRINE_OWNER)
    await shrine.set_multiplier(RAY_SCALE).execute(caller_address=SHRINE_OWNER)

    _, available_end_cumulative_price, _ = (await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result

    await shrine.deposit(YANG1_ADDRESS, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)
    updated_trove = (await shrine.get_trove(TROVE_1).execute()).result.trove
    updated_trove_debt = from_wad(updated_trove.debt)

    # Sanity check that compounded debt is greater than original debt
    assert updated_trove_debt > original_trove_debt

    expected_avg_price = (
        from_wad(available_end_cumulative_price - available_start_cumulative_price)
        - (missed_intervals_before_start * available_start_price)
    ) / Decimal(interval_count)

    expected_debt = compound_with_avg_price(
        [Decimal(INITIAL_DEPOSIT)],
        [from_ray(YANG1_THRESHOLD)],
        [expected_avg_price],
        Decimal("1"),
        Decimal(interval_count),
        original_trove_debt,
    )
    assert_equalish(expected_debt, updated_trove_debt)

    # Check average price
    avg_price = from_wad((await shrine.get_avg_price(YANG1_ID, start_interval, end_interval).execute()).result.price)
    assert_equalish(avg_price, expected_avg_price)


#
# Tests - Move yang
#


@pytest.mark.parametrize("move_amt", [0, to_wad(Decimal("1E-18")), 1, INITIAL_DEPOSIT // 2])
@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_move_yang_pass(shrine, move_amt, collect_gas_cost):
    # Check max forge amount
    yang_price = from_wad((await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result.price)
    max_forge_amt = from_wad((await shrine.get_max_forge(TROVE_1).execute()).result.max)
    expected_max_forge_amt = calculate_max_forge(
        [yang_price], [from_wad(INITIAL_DEPOSIT_WAD)], [from_ray(YANG1_THRESHOLD)]
    )
    current_debt = from_wad((await shrine.get_trove_info(TROVE_1).execute()).result.debt)
    assert_equalish(max_forge_amt, expected_max_forge_amt - current_debt)

    tx = await shrine.move_yang(YANG1_ADDRESS, TROVE_1, TROVE_2, to_wad(move_amt)).execute(caller_address=SHRINE_OWNER)

    collect_gas_cost("shrine/move_yang", tx, 6, 1)

    assert_event_emitted(
        tx,
        shrine.contract_address,
        "DepositUpdated",
        [YANG1_ADDRESS, TROVE_1, to_wad(INITIAL_DEPOSIT - move_amt)],
    )
    assert_event_emitted(
        tx,
        shrine.contract_address,
        "DepositUpdated",
        [YANG1_ADDRESS, TROVE_2, to_wad(move_amt)],
    )

    src_amt = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert src_amt == to_wad(INITIAL_DEPOSIT - move_amt)

    dst_amt = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_2).execute()).result.balance
    assert dst_amt == to_wad(move_amt)

    # Check max forge amount
    max_forge_amt = from_wad((await shrine.get_max_forge(TROVE_1).execute()).result.max)
    move_amt_value = move_amt * yang_price * from_ray(YANG1_THRESHOLD)
    expected_max_forge_amt -= move_amt_value
    assert_equalish(max_forge_amt, expected_max_forge_amt - current_debt)


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_move_yang_insufficient_fail(shrine):
    with pytest.raises(StarkException, match="Shrine: Insufficient yang"):
        await shrine.move_yang(YANG1_ADDRESS, TROVE_1, TROVE_2, to_wad(11)).execute(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_move_yang_unsafe_fail(shrine):
    # Get latest price
    price = (await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result.price
    assert price != 0

    unsafe_amt = (5000 / Decimal("0.85")) / from_wad(price)
    withdraw_amt = Decimal("10") - unsafe_amt

    with pytest.raises(StarkException, match="Shrine: Trove LTV is too high"):
        await shrine.move_yang(YANG1_ADDRESS, TROVE_1, TROVE_2, to_wad(withdraw_amt)).execute(
            caller_address=SHRINE_OWNER
        )


@pytest.mark.parametrize("move_amt", WAD_RAY_OOB_VALUES)
@pytest.mark.asyncio
async def test_move_yang_fail_amount_out_of_bounds(shrine, move_amt):
    # no need to have an actual deposit in this test, the
    # amount check happens before checking balances
    with pytest.raises(StarkException, match=r"Shrine: Value of `amount` \(-?\d+\) is out of bounds"):
        await shrine.move_yang(YANG1_ADDRESS, TROVE_1, TROVE_2, move_amt).execute(caller_address=SHRINE_OWNER)


@pytest.mark.asyncio
async def test_move_yang_invalid_yang(shrine):
    with pytest.raises(StarkException, match="Shrine: Yang does not exist"):
        await shrine.set_threshold(FAUX_YANG_ADDRESS, to_wad(1000)).execute(caller_address=SHRINE_OWNER)


#
# Tests - Yin transfers
#


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.parametrize("shrine_both", ["shrine", "shrine_killed"], indirect=["shrine_both"])
@pytest.mark.asyncio
async def test_yin_transfer_pass(shrine_both):

    shrine = shrine_both

    # Checking TROVE1_OWNER's and user's initial balance
    assert (await shrine.balanceOf(TROVE1_OWNER).execute()).result.balance == to_uint(FORGE_AMT_WAD)
    assert (await shrine.balanceOf(YIN_USER1).execute()).result.balance == to_uint(0)

    # Transferring all of TROVE1_OWNER's balance to user
    transfer_tx = await shrine.transfer(YIN_USER1, to_uint(FORGE_AMT_WAD)).execute(caller_address=TROVE1_OWNER)
    assert transfer_tx.result.success == TRUE

    assert (await shrine.balanceOf(TROVE1_OWNER).execute()).result.balance == to_uint(0)
    assert (await shrine.balanceOf(YIN_USER1).execute()).result.balance == to_uint(FORGE_AMT_WAD)

    assert_event_emitted(
        transfer_tx,
        shrine.contract_address,
        "Transfer",
        [TROVE1_OWNER, YIN_USER1, *to_uint(FORGE_AMT_WAD)],
    )

    # Attempting to transfer 0 yin when TROVE1_OWNER owns nothing - should pass
    await shrine.transfer(YIN_USER1, to_uint(0)).execute(caller_address=TROVE1_OWNER)


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_yin_transfer_fail(shrine):
    # Attempting to transfer more yin than TROVE1_OWNER owns
    with pytest.raises(StarkException, match="Shrine: Transfer amount exceeds yin balance"):
        await shrine.transfer(YIN_USER1, to_uint(FORGE_AMT_WAD + 1)).execute(caller_address=TROVE1_OWNER)

    # Attempting to transfer any amount of yin when user owns nothing
    with pytest.raises(StarkException, match="Shrine: Transfer amount exceeds yin balance"):
        await shrine.transfer(TROVE1_OWNER, to_uint(1)).execute(caller_address=YIN_USER1)


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.parametrize("shrine_both", ["shrine", "shrine_killed"], indirect=["shrine_both"])
@pytest.mark.asyncio
async def test_yin_transfer_from_pass(shrine_both):

    shrine = shrine_both

    # TROVE1_OWNER approves YIN_USER1
    approve_tx = await shrine.approve(YIN_USER1, to_uint(FORGE_AMT_WAD)).execute(caller_address=TROVE1_OWNER)
    assert approve_tx.result.success == TRUE
    assert_event_emitted(
        approve_tx, shrine.contract_address, "Approval", [TROVE1_OWNER, YIN_USER1, *to_uint(FORGE_AMT_WAD)]
    )

    # Checking user1's allowance for TROVE1_OWNER
    allowance = (await shrine.allowance(TROVE1_OWNER, YIN_USER1).execute()).result.allowance
    assert allowance == to_uint(FORGE_AMT_WAD)

    # YIN_USER1 transfers all of TROVE1_OWNER's funds to YIN_USER2
    tx = await shrine.transferFrom(TROVE1_OWNER, YIN_USER2, to_uint(FORGE_AMT_WAD)).execute(caller_address=YIN_USER1)
    assert_event_emitted(tx, shrine.contract_address, "Transfer", [TROVE1_OWNER, YIN_USER2, *to_uint(FORGE_AMT_WAD)])

    # Checking balances
    assert (await shrine.balanceOf(TROVE1_OWNER).execute()).result.balance == to_uint(0)
    assert (await shrine.balanceOf(YIN_USER2).execute()).result.balance == to_uint(FORGE_AMT_WAD)

    # Checking YIN_USER1's allowance
    assert (await shrine.allowance(TROVE1_OWNER, YIN_USER1).execute()).result.allowance == to_uint(0)


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_yin_infinite_allowance(shrine):
    # infinite allowance test
    await shrine.approve(YIN_USER1, to_uint(INFINITE_YIN_ALLOWANCE)).execute(caller_address=TROVE1_OWNER)
    await shrine.transferFrom(TROVE1_OWNER, YIN_USER2, to_uint(FORGE_AMT_WAD)).execute(caller_address=YIN_USER1)
    assert (await shrine.allowance(TROVE1_OWNER, YIN_USER1).execute()).result.allowance == to_uint(
        INFINITE_YIN_ALLOWANCE
    )


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_yin_transfer_from_fail(shrine):
    # Calling `transferFrom` with an allowance of zero

    # YIN_USER1 transfers all of TROVE1_OWNER's funds to USER_3 - should fail
    # since TROVE1_OWNER hasn't approved YIN_USER1
    with pytest.raises(StarkException, match="Shrine: Insufficient yin allowance"):
        await shrine.transferFrom(TROVE1_OWNER, YIN_USER2, to_uint(FORGE_AMT_WAD)).execute(caller_address=YIN_USER1)

    # TROVE1_OWNER approves YIN_USER1 but not enough to send FORGE_AMT_WAD
    await shrine.approve(YIN_USER1, to_uint(FORGE_AMT_WAD // 2)).execute(caller_address=TROVE1_OWNER)

    # Should fail since YIN_USER1's allowance for TROVE1_OWNER is less than FORGE_AMT_WAD
    with pytest.raises(StarkException, match="Shrine: Insufficient yin allowance"):
        await shrine.transferFrom(TROVE1_OWNER, YIN_USER2, to_uint(FORGE_AMT_WAD)).execute(caller_address=YIN_USER1)

    # TROVE1_OWNER grants YIN_USER1 unlimited allowance
    await shrine.approve(YIN_USER1, to_uint(INFINITE_YIN_ALLOWANCE)).execute(caller_address=TROVE1_OWNER)

    # Should fail since YIN_USER1's tries transferring more than TROVE1_OWNER has in their balance
    with pytest.raises(StarkException, match="Shrine: Transfer amount exceeds yin balance"):
        await shrine.transferFrom(TROVE1_OWNER, YIN_USER2, to_uint(FORGE_AMT_WAD + 1)).execute(caller_address=YIN_USER1)

    # Transfer to zero address - should fail since a check prevents this
    with pytest.raises(StarkException, match="Shrine: Cannot transfer to the zero address"):
        await shrine.transferFrom(TROVE1_OWNER, 0, to_uint(FORGE_AMT_WAD)).execute(caller_address=YIN_USER1)


@pytest.mark.parametrize(
    "amount", [to_uint(-1), to_uint(2**125 + 1), to_uint(2**128 + 1), (2**128, 0), (0, 2**128)]
)
@pytest.mark.asyncio
async def test_yin_transfer_invalid_inputs(shrine, amount):
    with pytest.raises(StarkException):
        await shrine.transfer(YIN_USER1, amount).execute(caller_address=TROVE1_OWNER)


@pytest.mark.parametrize("amount", [to_uint(-1), to_uint(2**256), (2**128, 0), (0, 2**128)])
@pytest.mark.asyncio
async def test_yin_approve_invalid_inputs(shrine, amount):
    with pytest.raises(StarkException, match="Shrine: Amount not valid"):
        await shrine.approve(YIN_USER1, amount).execute(caller_address=TROVE1_OWNER)


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.parametrize("shrine_both", ["shrine", "shrine_killed"], indirect=["shrine_both"])
@pytest.mark.asyncio
async def test_yin_melt_after_transfer(shrine_both):
    shrine = shrine_both

    # Transferring half of TROVE1_OWNER's balance to YIN_USER1
    await shrine.transfer(YIN_USER1, to_uint(FORGE_AMT_WAD // 2)).execute(caller_address=TROVE1_OWNER)

    # Trying to melt `FORGE_AMT_WAD` debt. Should fail since TROVE1_OWNER no longer has FORGE_AMT_WAD yin.
    with pytest.raises(StarkException, match="Shrine: Not enough yin to melt debt"):
        await shrine.melt(TROVE1_OWNER, TROVE_1, FORGE_AMT_WAD).execute(caller_address=SHRINE_OWNER)

    # Trying to melt less than half of `FORGE_AMT_WAD`. Should pass since TROVE1_OWNER has enough yin to do this.
    await shrine.melt(TROVE1_OWNER, TROVE_1, FORGE_AMT_WAD // 2 - 1).execute(caller_address=SHRINE_OWNER)

    # Checking that the user's debt and yin are what we expect them to be
    trove1_info = (await shrine.get_trove(TROVE_1).execute()).result.trove
    trove1_owner_yin = (await shrine.get_yin(TROVE1_OWNER).execute()).result.balance

    assert trove1_info.debt == FORGE_AMT_WAD - (FORGE_AMT_WAD // 2 - 1)

    # First `FORGE_AMT_WAD//2` yin was transferred, and then `FORGE_AMT_WAD//2 - 1` was melted
    assert trove1_owner_yin == FORGE_AMT_WAD - FORGE_AMT_WAD // 2 - (FORGE_AMT_WAD // 2 - 1)


#
# Tests - Price and multiplier
#


@pytest.mark.asyncio
async def test_shrine_advance_set_multiplier_invalid_fail(shrine_deploy):
    shrine = shrine_deploy
    with pytest.raises(StarkException, match="Shrine: Cannot set a price value to zero"):
        await shrine.advance(YANG1_ADDRESS, 0).execute(caller_address=SHRINE_OWNER)

    with pytest.raises(StarkException, match="Shrine: Cannot set a multiplier value to zero"):
        await shrine.set_multiplier(0).execute(caller_address=SHRINE_OWNER)


#
# Tests - Getters for Trove information
#


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_shrine_unhealthy(shrine):
    # Calculate unsafe yang price
    yang_balance = from_wad((await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance)
    debt = from_wad((await shrine.get_trove(TROVE_1).execute()).result.trove.debt)
    unsafe_price = debt / Decimal("0.85") / yang_balance

    # Update yang price to unsafe level
    await shrine.advance(YANG1_ADDRESS, to_wad(unsafe_price)).execute(caller_address=SHRINE_OWNER)
    is_healthy = (await shrine.is_healthy(TROVE_1).execute()).result.healthy
    assert is_healthy == FALSE


@pytest.mark.usefixtures("shrine_deposit_multiple")
@pytest.mark.parametrize("max_forge_percentage", [Decimal("0.001"), Decimal("0.01"), Decimal("0.1"), Decimal("1")])
@pytest.mark.asyncio
async def test_get_trove_info_variable_forge(shrine, max_forge_percentage):
    # Check LTV for trove with value but zero debt
    trove_info = (await shrine.get_trove_info(TROVE_1).execute()).result
    assert trove_info.ltv == 0

    prices = []
    for d in DEPOSITS:
        price = from_wad((await shrine.get_current_yang_price(d["address"]).execute()).result.price)
        prices.append(price)

    expected_threshold, expected_value = calculate_trove_threshold_and_value(
        prices, [from_wad(d["amount"]) for d in DEPOSITS], [from_ray(d["threshold"]) for d in DEPOSITS]
    )

    expected_max_forge_amt = expected_threshold * expected_value
    forge_amt = (max_forge_percentage * expected_max_forge_amt).quantize(Decimal("1E-18"), rounding=ROUND_DOWN)
    forge_amt_wad = to_wad(forge_amt)

    await shrine.forge(TROVE1_OWNER, TROVE_1, forge_amt_wad).execute(caller_address=SHRINE_OWNER)

    expected_ltv = forge_amt / expected_value

    trove_info = (await shrine.get_trove_info(TROVE_1).execute()).result
    assert trove_info.debt == forge_amt_wad
    assert_equalish(from_ray(trove_info.threshold), expected_threshold)
    assert_equalish(from_wad(trove_info.value), expected_value)
    assert_equalish(from_ray(trove_info.ltv), expected_ltv)


@pytest.mark.usefixtures("shrine_deposit_multiple")
@pytest.mark.parametrize(
    "thresholds",
    [
        (Decimal("0.5"), Decimal("0.66"), Decimal("0.8")),
        (Decimal("0.65432"), Decimal("0.76543"), Decimal("0.87654")),
        (Decimal("0.333"), Decimal("0.666"), Decimal("0.888")),
    ],
)
@pytest.mark.asyncio
async def test_get_trove_info_variable_thresholds(shrine, thresholds):
    prices = []
    for d, threshold in zip(DEPOSITS, thresholds):
        yang_address = d["address"]
        await shrine.set_threshold(yang_address, to_ray(threshold)).execute(caller_address=SHRINE_OWNER)

        price = from_wad((await shrine.get_current_yang_price(yang_address).execute()).result.price)
        prices.append(price)

    expected_threshold, expected_value = calculate_trove_threshold_and_value(
        prices, [from_wad(d["amount"]) for d in DEPOSITS], thresholds
    )

    trove_info = (await shrine.get_trove_info(TROVE_1).execute()).result
    assert_equalish(from_ray(trove_info.threshold), expected_threshold)


@pytest.mark.usefixtures("update_feeds")
@pytest.mark.asyncio
async def test_zero_value_trove(shrine):
    # Trove with zero value
    trove_info = (await shrine.get_trove_info(TROVE_3).execute()).result
    assert trove_info.ltv == 0
    assert trove_info.value == 0
    assert trove_info.debt == 0
    assert trove_info.threshold == 0
