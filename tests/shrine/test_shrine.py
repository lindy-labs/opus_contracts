from collections import namedtuple
from curses.ascii import FF
from decimal import Decimal, localcontext
from typing import List
from math import exp 

import pytest
from constants import *  # noqa: F403
from starkware.starknet.testing.objects import StarknetTransactionExecutionInfo
from starkware.starkware_utils.error_handling import StarkException

from tests.utils import (
    FALSE,
    RAY_SCALE,
    TRUE,
    WAD_SCALE,
    assert_equalish,
    assert_event_emitted,
    create_feed,
    from_ray,
    from_wad,
    price_bounds,
    set_block_timestamp,
    to_wad,
)

YANG_0_ADDRESS = YANGS[0]["address"]
YANG_0_CEILING = YANGS[0]["ceiling"]

#
# Structs
#

Yang = namedtuple("Yang", ["total", "max"])


def linear(x: Decimal, m: Decimal, b: Decimal):
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
    Helper function to calculate base rate given loan-to-value ratio.

    Arguments
    ---------
    ltv : Decimal
        Loan-to-value ratio in Decimal

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
    yangs_cumulative_prices_start: List[Decimal],
    yangs_cumulative_prices_end: List[Decimal],
    cumulative_multiplier_start : Decimal, 
    cumulative_multiplier_end : Decimal,
    start_interval : int,
    end_interval : int,
    debt: Decimal,
) -> Decimal:
    """
    Helper function to calculate the compounded debt.

    Arguments
    ---------
    yangs_amt : List[Decimal]
        Ordered list of the amount of each Yang
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
    Value of the compounded debt from start interval to end interval in
    Decimal with ray precision of 27 decimals.
    """

    # Sanity check on input data 
    assert len(yangs_amt) == len(yangs_cumulative_prices_start)
    assert len(yangs_amt) == len(yangs_cumulative_prices_end)

    intervals_elapsed = Decimal(end_interval - start_interval)
    avg_trove_value = Decimal(0)
    for i in range(len(yangs_amt)):
        avg_price = (yangs_cumulative_prices_end[i] - yangs_cumulative_prices_start[i]) / intervals_elapsed
        avg_trove_value += avg_price * yangs_amt[i]
    
    ltv = debt / avg_trove_value

    trove_base_rate = base_rate(ltv)
    avg_multiplier = (cumulative_multiplier_end - cumulative_multiplier_start) / intervals_elapsed

    true_rate = trove_base_rate * avg_multiplier

    new_debt = debt * Decimal(exp(true_rate * intervals_elapsed * TIME_INTERVAL_DIV_YEAR))
    return new_debt


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

    return cumulative_weighted_threshold / total_value


#
# Fixtures
#
@pytest.fixture
async def shrine_deposit(users, shrine) -> StarknetTransactionExecutionInfo:
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    deposit = await shrine_owner.send_tx(
        shrine.contract_address,
        "deposit",
        [YANG_0_ADDRESS, to_wad(INITIAL_DEPOSIT), shrine_user.address, 0],
    )
    return deposit


@pytest.fixture
async def shrine_deposit_multiple(users, shrine):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    for d in DEPOSITS:
        await shrine_owner.send_tx(
            shrine.contract_address,
            "deposit",
            [d["address"], d["amount"], shrine_user.address, 0],
        )


@pytest.fixture
async def shrine_forge(users, shrine, shrine_deposit) -> StarknetTransactionExecutionInfo:
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    forge = await shrine_owner.send_tx(shrine.contract_address, "forge", [FORGE_AMT, shrine_user.address, 0])
    return forge


@pytest.fixture
async def shrine_melt(users, shrine, shrine_forge) -> StarknetTransactionExecutionInfo:
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    estimated_debt = (await shrine.estimate(shrine_user.address, 0).invoke()).result.wad
    melt = await shrine_owner.send_tx(shrine.contract_address, "melt", [estimated_debt, shrine_user.address, 0])

    return melt


@pytest.fixture
async def shrine_withdraw(users, shrine, shrine_deposit) -> StarknetTransactionExecutionInfo:
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    withdraw = await shrine_owner.send_tx(
        shrine.contract_address,
        "withdraw",
        [YANG_0_ADDRESS, to_wad(INITIAL_DEPOSIT), shrine_user.address, 0],
    )
    return withdraw


@pytest.fixture
async def update_feeds(starknet, users, shrine, shrine_forge) -> List[Decimal]:
    """
    Additional price feeds for yang 0 after `shrine_forge`
    """
    shrine_owner = await users("shrine owner")

    yang0_address = YANG_0_ADDRESS
    yang0_feed = create_feed(YANGS[0]["start_price"], FEED_LEN, MAX_PRICE_CHANGE)

    for i in range(FEED_LEN):
        # Add offset for initial feeds in `shrine`
        timestamp = (i + FEED_LEN) * TIME_INTERVAL
        set_block_timestamp(starknet.state, timestamp)
        await shrine_owner.send_tx(
            shrine.contract_address,
            "advance",
            [yang0_address, yang0_feed[i]],
        )
        await shrine_owner.send_tx(
            shrine.contract_address,
            "update_multiplier",
            [MULTIPLIER_FEED[i]],
        )

    return list(map(from_wad, yang0_feed))


@pytest.fixture
async def shrine_deposit_user2(users, shrine) -> StarknetTransactionExecutionInfo:
    """
    Replicate `shrine user` deposit for another user address.
    """
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user 2")

    deposit = await shrine_owner.send_tx(
        shrine.contract_address,
        "deposit",
        [YANG_0_ADDRESS, to_wad(INITIAL_DEPOSIT), shrine_user.address, 0],
    )
    return deposit


@pytest.fixture
async def shrine_forge_user2(users, shrine, shrine_deposit_user2) -> StarknetTransactionExecutionInfo:
    """
    Replicate `shrine user` forge for another user address.
    """
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user 2")

    forge = await shrine_owner.send_tx(shrine.contract_address, "forge", [FORGE_AMT, shrine_user.address, 0])
    return forge


@pytest.fixture
async def update_feeds_with_user2(shrine_forge, shrine_forge_user2, update_feeds):
    """
    Helper fixture for `update_feeds` with another user address.
    """
    return update_feeds


@pytest.fixture
async def estimate(users, shrine, update_feeds_with_user2):
    shrine_user1 = await users("shrine user")
    shrine_user2 = await users("shrine user 2")

    trove = (await shrine.get_trove(shrine_user1.address, 0).invoke()).result.trove

    # Get yang price and multiplier value at `trove.charge_from`
    start_cumulative_price = (await shrine.get_yang_price(YANG_0_ADDRESS, trove.charge_from).invoke()).result.cumulative_price_wad
    start_cumulative_multiplier = (await shrine.get_multiplier(trove.charge_from).invoke()).result.cumulative_multiplier_ray

    # Getting the current yang price and multiplier value 
    end__cumulative_price = (await shrine.get_current_yang_price(YANG_0_ADDRESS).invoke()).result.cumulative_price_wad
    end_cumulative_multiplier = (await shrine.get_current_multiplier().invoke()).result.cumulative_multiplier_ray
    
    expected_debt = compound(
        [Decimal(INITIAL_DEPOSIT)],
        [from_wad(start_cumulative_price)], 
        [from_wad(end__cumulative_price)],
        from_ray(start_cumulative_multiplier), 
        from_ray(end_cumulative_multiplier),
        trove.charge_from, 
        2*FEED_LEN - 1,
        from_wad(trove.debt)
    )

    # Get estimated debt for users
    estimated_user1_debt = (await shrine.estimate(shrine_user1.address, 0).invoke()).result.wad
    estimated_user2_debt = (await shrine.estimate(shrine_user2.address, 0).invoke()).result.wad
    return estimated_user1_debt, estimated_user2_debt, expected_debt
    

@pytest.fixture(scope="function")
async def update_feeds_intermittent(request, starknet, users, shrine, shrine_forge) -> List[Decimal]:
    """
    Additional price feeds for yang 0 after `shrine_forge` with intermittent missed updates.

    This fixture takes in an index as argument, and skips that index when updating the
    price and multiplier values.
    """
    shrine_owner = await users("shrine owner")

    yang0_address = YANG_0_ADDRESS
    yang0_feed = create_feed(YANGS[0]["start_price"], FEED_LEN, MAX_PRICE_CHANGE)

    idx = request.param

    for i in range(FEED_LEN):
        # Add offset for initial feeds in `shrine`
        timestamp = (i + FEED_LEN) * TIME_INTERVAL
        set_block_timestamp(starknet.state, timestamp)

        price = yang0_feed[i]
        multiplier = MULTIPLIER_FEED[i]
        # Skip index after timestamp is set
        if i == idx:
            price = 0
            multiplier = 0

        await shrine_owner.send_tx(
            shrine.contract_address,
            "advance",
            [yang0_address, price],
        )
        await shrine_owner.send_tx(
            shrine.contract_address,
            "update_multiplier",
            [multiplier],
        )

    return idx, list(map(from_wad, yang0_feed))


#
# Tests
#


@pytest.mark.asyncio
async def test_shrine_deploy(shrine_deploy):
    shrine = shrine_deploy

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
async def test_shrine_setup_with_feed(shrine):
    
    # Check price feeds
    for i in range(len(YANGS)):
        yang_address = YANGS[i]["address"]
        start_price = (await shrine.get_yang_price(yang_address, 0).invoke()).result.price_wad
        assert start_price == to_wad(YANGS[i]["start_price"])

        end_price = (await shrine.get_yang_price(yang_address, FEED_LEN - 1).invoke()).result.price_wad
        lo, hi = price_bounds(start_price, FEED_LEN, MAX_PRICE_CHANGE)
        assert lo <= end_price <= hi

    # Check multiplier feed
    multiplier_first_point = (await shrine.get_multiplier(0).invoke()).result.multiplier_ray
    assert multiplier_first_point == RAY_SCALE

    multiplier_last_point = (await shrine.get_multiplier(FEED_LEN - 1).invoke()).result.multiplier_ray
    assert multiplier_last_point != 0
    

@pytest.mark.asyncio
async def test_auth(users, shrine_deploy):
    shrine = shrine_deploy
    shrine_owner = await users("shrine owner")

    #
    # Auth
    #

    b = await users("2nd owner")
    c = await users("3rd owner")

    # Authorizing an address and testing that it can use authorized functions
    await shrine_owner.send_tx(shrine.contract_address, "authorize", [b.address])
    b_authorized = (await shrine.get_auth(b.address).invoke()).result.bool
    assert b_authorized == TRUE

    await b.send_tx(shrine.contract_address, "authorize", [c.address])
    c_authorized = (await shrine.get_auth(c.address).invoke()).result.bool
    assert c_authorized == TRUE

    # Revoking an address
    await b.send_tx(shrine.contract_address, "revoke", [c.address])
    c_authorized = (await shrine.get_auth(c.address).invoke()).result.bool
    assert c_authorized == FALSE

    # Calling an authorized function with an unauthorized address - should fail
    with pytest.raises(StarkException):
        await c.send_tx(shrine.contract_address, "revoke", [b.address])


@pytest.mark.asyncio
async def test_shrine_deposit(users, shrine, shrine_deposit, collect_gas_cost):
    shrine_user = await users("shrine user")

    collect_gas_cost("shrine/deposit", shrine_deposit, 4, 1)
    assert_event_emitted(
        shrine_deposit,
        shrine.contract_address,
        "YangUpdated",
        [YANG_0_ADDRESS, to_wad(INITIAL_DEPOSIT), YANG_0_CEILING],
    )
    assert_event_emitted(
        shrine_deposit,
        shrine.contract_address,
        "DepositUpdated",
        [shrine_user.address, 0, YANG_0_ADDRESS, to_wad(INITIAL_DEPOSIT)],
    )

    yang = (await shrine.get_yang(YANG_0_ADDRESS).invoke()).result.yang
    assert yang.total == to_wad(INITIAL_DEPOSIT)

    amt = (await shrine.get_deposit(shrine_user.address, 0, YANG_0_ADDRESS).invoke()).result.wad
    assert amt == to_wad(INITIAL_DEPOSIT)


@pytest.mark.asyncio
async def test_shrine_withdraw_pass(users, shrine, shrine_withdraw, collect_gas_cost):
    shrine_user = await users("shrine user")

    collect_gas_cost("shrine/withdraw", shrine_withdraw, 4, 1)

    assert_event_emitted(
        shrine_withdraw,
        shrine.contract_address,
        "YangUpdated",
        [YANG_0_ADDRESS, 0, YANG_0_CEILING],
    )

    assert_event_emitted(
        shrine_withdraw,
        shrine.contract_address,
        "DepositUpdated",
        [shrine_user.address, 0, YANG_0_ADDRESS, 0],
    )

    yang = (await shrine.get_yang(YANG_0_ADDRESS).invoke()).result.yang
    assert yang.total == 0

    amt = (await shrine.get_deposit(shrine_user.address, 0, YANG_0_ADDRESS).invoke()).result.wad
    assert amt == 0

    ltv = (await shrine.get_current_trove_ratio(shrine_user.address, 0).invoke()).result.ray
    assert ltv == 0

    is_healthy = (await shrine.is_healthy(shrine_user.address, 0).invoke()).result.bool
    assert is_healthy == TRUE


@pytest.mark.asyncio
async def test_shrine_forge_pass(users, shrine, shrine_forge):
    shrine_user = await users("shrine user")

    assert_event_emitted(shrine_forge, shrine.contract_address, "DebtTotalUpdated", [FORGE_AMT])

    assert_event_emitted(
        shrine_forge,
        shrine.contract_address,
        "TroveUpdated",
        [shrine_user.address, 0, FEED_LEN - 1, FORGE_AMT],
    )

    system_debt = (await shrine.get_shrine_debt().invoke()).result.wad
    assert system_debt == FORGE_AMT

    user_trove = (await shrine.get_trove(shrine_user.address, 0).invoke()).result.trove
    assert user_trove.debt == FORGE_AMT
    assert user_trove.charge_from == FEED_LEN - 1

    yang0_price = (await shrine.get_current_yang_price(YANG_0_ADDRESS).invoke()).result.price_wad
    trove_ltv = (await shrine.get_current_trove_ratio(shrine_user.address, 0).invoke()).result.ray
    adjusted_trove_ltv = Decimal(trove_ltv) / RAY_SCALE
    expected_ltv = Decimal(FORGE_AMT) / Decimal(10 * yang0_price)
    assert_equalish(adjusted_trove_ltv, expected_ltv)

    healthy = (await shrine.is_healthy(shrine_user.address, 0).invoke()).result.bool
    assert healthy == TRUE


@pytest.mark.asyncio
async def test_shrine_melt_pass(users, shrine, shrine_melt):
    shrine_user = await users("shrine user")

    assert_event_emitted(shrine_melt, shrine.contract_address, "DebtTotalUpdated", [0])

    assert_event_emitted(
        shrine_melt,
        shrine.contract_address,
        "TroveUpdated",
        [shrine_user.address, 0, FEED_LEN - 1, 0],
    )

    system_debt = (await shrine.get_shrine_debt().invoke()).result.wad
    assert system_debt == 0

    user_trove = (await shrine.get_trove(shrine_user.address, 0).invoke()).result.trove
    assert user_trove.debt == 0
    assert user_trove.charge_from == FEED_LEN - 1

    shrine_ltv = (await shrine.get_current_trove_ratio(shrine_user.address, 0).invoke()).result.ray
    assert shrine_ltv == 0

    healthy = (await shrine.is_healthy(shrine_user.address, 0).invoke()).result.bool
    assert healthy == TRUE


@pytest.mark.asyncio
async def test_estimate(users, shrine, estimate):
    shrine_user1 = await users("shrine user")
    shrine_user2 = await users("shrine user 2")

    user1_trove = (await shrine.get_trove(shrine_user1.address, 0).invoke()).result.trove
    assert user1_trove.charge_from == FEED_LEN - 1

    user2_trove = (await shrine.get_trove(shrine_user2.address, 0).invoke()).result.trove
    assert user2_trove.charge_from == FEED_LEN - 1

    last_updated = (await shrine.get_yang_price(YANG_0_ADDRESS, 2 * FEED_LEN - 1).invoke()).result.price_wad
    assert last_updated != 0
    
    estimated_user1_debt, estimated_user2_debt, expected_debt = estimate

    # Convert wad values to decimal
    adjusted_estimated_user1_debt = Decimal(estimated_user1_debt) / WAD_SCALE
    adjusted_estimated_user2_debt = Decimal(estimated_user2_debt) / WAD_SCALE
    
    # Check values
    assert_equalish(adjusted_estimated_user1_debt, expected_debt)
    assert_equalish(adjusted_estimated_user2_debt, expected_debt)

@pytest.mark.asyncio
@pytest.mark.parametrize(
    "method,calldata",
    [
        # -1 and -2 are placeholders for user addresses
        ("deposit", [YANG_0_ADDRESS, 0, -1, 0]),
        ("withdraw", [YANG_0_ADDRESS, 0, -1, 0]),
        ("forge", [0, -1, 0]),
        ("melt", [0, -1, 0]),
        ("move_yang", [YANG_0_ADDRESS, 0, -1, 0, -2, 0]),
    ],
)
async def test_charge(users, shrine, estimate, method, calldata):
    shrine_owner = await users("shrine owner")
    shrine_user1 = await users("shrine user")
    shrine_user2 = await users("shrine user 2")
    
    estimated_user1_debt, estimated_user2_debt, expected_debt = estimate

    # Calculate expected system debt
    if method == "move_yang":
        expected_system_debt = estimated_user1_debt + estimated_user2_debt
    else:
        expected_system_debt = estimated_user1_debt + FORGE_AMT

    # Replace placeholder values with user addresses in calldata
    calldata = [shrine_user1.address if i == -1 else (shrine_user2.address if i == -2 else i) for i in calldata]

    # Test `charge` by calling the method without any value
    tx = await shrine_owner.send_tx(shrine.contract_address, method, calldata)

    # Get updated system info
    new_system_debt = (await shrine.get_shrine_debt().invoke()).result.wad
    assert new_system_debt == expected_system_debt

    # Get updated trove information for user 1
    updated_user1_trove = (await shrine.get_trove(shrine_user1.address, 0).invoke()).result.trove
    adjusted_trove_debt = Decimal(updated_user1_trove.debt) / WAD_SCALE
    assert_equalish(adjusted_trove_debt, expected_debt)
    assert updated_user1_trove.charge_from == FEED_LEN * 2 - 1

    assert_event_emitted(tx, shrine.contract_address, "DebtTotalUpdated", [expected_system_debt])
    assert_event_emitted(
        tx,
        shrine.contract_address,
        "TroveUpdated",
        [shrine_user1.address, 0, updated_user1_trove.charge_from, updated_user1_trove.debt],
    )

    # `charge` should not have any effect if `Trove.charge_from` is the current interval
    redundant_tx = await shrine_owner.send_tx(shrine.contract_address, method, calldata)
    redundant_user1_trove = (await shrine.get_trove(shrine_user1.address, 0).invoke()).result.trove
    assert updated_user1_trove == redundant_user1_trove
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
        [shrine_user1.address, 0, updated_user1_trove.charge_from, updated_user1_trove.debt],
    )

    # Check user 2 trove if method is `move_yang`
    if method == "move_yang":
        # Get updated trove information for user 2
        updated_user2_trove = (await shrine.get_trove(shrine_user2.address, 0).invoke()).result.trove
        adjusted_trove_debt = Decimal(updated_user2_trove.debt) / WAD_SCALE
        assert_equalish(adjusted_trove_debt, expected_debt)
        assert updated_user2_trove.charge_from == FEED_LEN * 2 - 1

        assert_event_emitted(
            tx,
            shrine.contract_address,
            "TroveUpdated",
            [shrine_user2.address, 0, updated_user2_trove.charge_from, updated_user2_trove.debt],
        )

        # `charge` should not have any effect if `Trove.charge_from` is current interval + 1
        redundant_tx = await shrine_owner.send_tx(shrine.contract_address, method, calldata)
        redundant_user2_trove = (await shrine.get_trove(shrine_user2.address, 0).invoke()).result.trove
        assert updated_user2_trove == redundant_user2_trove
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
            [shrine_user1.address, 0, updated_user2_trove.charge_from, updated_user2_trove.debt],
        )
    

# Skip index 0 because initial price is set in `add_yang`
@pytest.mark.asyncio
@pytest.mark.parametrize(
    "update_feeds_intermittent",
    [0, 1, FEED_LEN - 2, FEED_LEN - 1],
    indirect=["update_feeds_intermittent"],
)
async def test_intermittent_charge(users, shrine, update_feeds_intermittent):
    """
    Test for `charge` with "missed" price and multiplier updates at the given index.

    The `update_feeds_intermittent` fixture returns a tuple of the index that is skipped,
    and a list for the price feed.

    The index is with reference to the second set of feeds.
    Therefore, writes to the contract takes in an additional offset of FEED_LEN for the initial
    set of feeds in `shrine` fixture.
    """
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    idx, price_feed = update_feeds_intermittent

    # Assert that value for skipped index is set to 0
    assert (await shrine.get_yang_price(YANG_0_ADDRESS, idx + FEED_LEN).invoke()).result.price_wad == 0
    assert (await shrine.get_multiplier(idx + FEED_LEN).invoke()).result.multiplier_ray == 0

    # Get yang price and multiplier value at `trove.charge_from`
    trove = (await shrine.get_trove(shrine_user.address, 0).invoke()).result.trove
    start_price = (await shrine.get_yang_price(YANG_0_ADDRESS, trove.charge_from).invoke()).result.price_wad
    start_multiplier = (await shrine.get_multiplier(trove.charge_from).invoke()).result.multiplier_ray

    # Modify feeds
    yang0_price_feed = [from_wad(start_price)] + price_feed
    multiplier_feed = [from_ray(start_multiplier)] + [Decimal("1")] * FEED_LEN

    # Add offset of 1 to account for last price of first set of feeds being appended as first value
    yang0_price_feed[idx + 1] = yang0_price_feed[idx]
    multiplier_feed[idx + 1] = multiplier_feed[idx]

    # Test 'charge' by calling deposit without any value
    await shrine_owner.send_tx(
        shrine.contract_address,
        "deposit",
        [YANG_0_ADDRESS, 0, shrine_user.address, 0],
    )
    updated_trove = (await shrine.get_trove(shrine_user.address, 0).invoke()).result.trove

    expected_debt = compound(
        [Decimal("10")], 
        [yang0_price_feed[0]], 
        [sum(yang0_price_feed)], 
        multiplier_feed[0], 
        sum(multiplier_feed), 
        0, 
        FEED_LEN*2 - 1, 
        Decimal("5000")
    )

    adjusted_trove_debt = Decimal(updated_trove.debt) / WAD_SCALE
    # Precision loss gets quite bad for the interest accumulation calculations due 
    # to the several multiplications and divisions, as well the `exp` function. 
    assert abs(adjusted_trove_debt - expected_debt) <= 0.1 

    assert updated_trove.charge_from == FEED_LEN * 2 - 1


@pytest.mark.asyncio
async def test_move_yang_pass(users, shrine, shrine_forge, collect_gas_cost):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    collect_gas_cost("shrine/forge", shrine_forge, 2, 1)
    # Move yang between two troves of the same user
    intra_user_tx = await shrine_owner.send_tx(
        shrine.contract_address,
        "move_yang",
        [YANG_0_ADDRESS, to_wad(1), shrine_user.address, 0, shrine_user.address, 1],
    )

    collect_gas_cost("shrine/move_yang", intra_user_tx, 6, 1)

    assert_event_emitted(
        intra_user_tx,
        shrine.contract_address,
        "DepositUpdated",
        [shrine_user.address, 0, YANG_0_ADDRESS, to_wad(9)],
    )
    assert_event_emitted(
        intra_user_tx,
        shrine.contract_address,
        "DepositUpdated",
        [shrine_user.address, 1, YANG_0_ADDRESS, to_wad(1)],
    )

    src_amt = (await shrine.get_deposit(shrine_user.address, 0, YANG_0_ADDRESS).invoke()).result.wad
    assert src_amt == to_wad(9)

    dst_amt = (await shrine.get_deposit(shrine_user.address, 1, YANG_0_ADDRESS).invoke()).result.wad
    assert dst_amt == to_wad(1)

    # Move yang between two different users
    shrine_guest = await users("shrine guest")
    intra_user_tx = await shrine_owner.send_tx(
        shrine.contract_address,
        "move_yang",
        [YANG_0_ADDRESS, to_wad(1), shrine_user.address, 0, shrine_guest.address, 0],
    )

    assert_event_emitted(
        intra_user_tx,
        shrine.contract_address,
        "DepositUpdated",
        [shrine_user.address, 0, YANG_0_ADDRESS, to_wad(8)],
    )
    assert_event_emitted(
        intra_user_tx,
        shrine.contract_address,
        "DepositUpdated",
        [shrine_guest.address, 0, YANG_0_ADDRESS, to_wad(1)],
    )

    src_amt = (await shrine.get_deposit(shrine_user.address, 0, YANG_0_ADDRESS).invoke()).result.wad
    assert src_amt == to_wad(8)

    dst_amt = (await shrine.get_deposit(shrine_guest.address, 0, YANG_0_ADDRESS).invoke()).result.wad
    assert dst_amt == to_wad(1)


@pytest.mark.asyncio
async def test_shrine_deposit_invalid_yang_fail(users, shrine):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    # Invalid yang ID that has not been added
    with pytest.raises(StarkException, match="Shrine: Yang does not exist"):
        await shrine_owner.send_tx(shrine.contract_address, "deposit", [789, to_wad(1), shrine_user.address, 0])


@pytest.mark.asyncio
async def test_shrine_withdraw_invalid_yang_fail(users, shrine):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    # Invalid yang ID that has not been added
    with pytest.raises(StarkException, match="Shrine: Yang does not exist"):
        await shrine_owner.send_tx(
            shrine.contract_address,
            "withdraw",
            [789, to_wad(1), shrine_user.address, 0],
        )


@pytest.mark.asyncio
async def test_shrine_withdraw_insufficient_yang_fail(users, shrine, shrine_deposit):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    with pytest.raises(StarkException, match="Shrine: Insufficient yang"):
        await shrine_owner.send_tx(
            shrine.contract_address,
            "withdraw",
            [YANG_0_ADDRESS, to_wad(11), shrine_user.address, 0],
        )


@pytest.mark.asyncio
async def test_shrine_withdraw_unsafe_fail(users, shrine, update_feeds):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    # Get latest price
    price = (await shrine.get_yang_price(YANG_0_ADDRESS, 2 * FEED_LEN - 1).invoke()).result.price_wad
    assert price != 0

    unsafe_amt = (5000 / Decimal("0.85")) / from_wad(price)
    withdraw_amt = Decimal("10") - unsafe_amt

    with pytest.raises(StarkException, match="Shrine: Trove LTV is too high"):
        await shrine_owner.send_tx(
            shrine.contract_address,
            "withdraw",
            [YANG_0_ADDRESS, to_wad(withdraw_amt), shrine_user.address, 0],
        )


@pytest.mark.asyncio
async def test_shrine_forge_zero_deposit_fail(users, shrine):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    # Forge without any yangs deposited
    with pytest.raises(StarkException, match="Shrine: Trove LTV is too high"):
        await shrine_owner.send_tx(shrine.contract_address, "forge", [to_wad(1_000), shrine_user.address, 0])


@pytest.mark.asyncio
async def test_shrine_forge_unsafe_fail(users, shrine, update_feeds):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    # Increase debt ceiling
    new_ceiling = to_wad(100_000)
    await shrine_owner.send_tx(shrine.contract_address, "set_ceiling", [new_ceiling])

    with pytest.raises(StarkException, match="Shrine: Trove LTV is too high"):
        await shrine_owner.send_tx(shrine.contract_address, "forge", [to_wad(14_000), shrine_user.address, 0])


@pytest.mark.asyncio
async def test_shrine_forge_ceiling_fail(users, shrine, update_feeds):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    # Deposit more yang
    await shrine_owner.send_tx(
        shrine.contract_address,
        "deposit",
        [YANG_0_ADDRESS, to_wad(10), shrine_user.address, 0],
    )
    updated_deposit = (await shrine.get_deposit(shrine_user.address, 0, YANG_0_ADDRESS).invoke()).result.wad
    assert updated_deposit == to_wad(20)

    with pytest.raises(StarkException, match="Shrine: Debt ceiling reached"):
        await shrine_owner.send_tx(shrine.contract_address, "forge", [to_wad(15_000), shrine_user.address, 0])


@pytest.mark.asyncio
async def test_move_yang_insufficient_fail(users, shrine, shrine_forge):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")
    shrine_guest = await users("shrine guest")

    with pytest.raises(StarkException, match="Shrine: Insufficient yang"):
        await shrine_owner.send_tx(
            shrine.contract_address,
            "move_yang",
            [
                YANG_0_ADDRESS,
                to_wad(11),
                shrine_user.address,
                0,
                shrine_guest.address,
                0,
            ],
        )


@pytest.mark.asyncio
async def test_move_yang_unsafe_fail(users, shrine, shrine_forge):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")
    shrine_guest = await users("shrine guest")

    # Get latest price
    price = (await shrine.get_current_yang_price(YANG_0_ADDRESS).invoke()).result.price_wad
    assert price != 0

    unsafe_amt = (5000 / Decimal("0.85")) / from_wad(price)
    withdraw_amt = Decimal("10") - unsafe_amt

    with pytest.raises(StarkException, match="Shrine: Trove LTV is too high"):
        await shrine_owner.send_tx(
            shrine.contract_address,
            "move_yang",
            [
                YANG_0_ADDRESS,
                to_wad(withdraw_amt),
                shrine_user.address,
                0,
                shrine_guest.address,
                0,
            ],
        )


@pytest.mark.asyncio
async def test_shrine_unhealthy(starknet, users, shrine, shrine_forge):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    # Calculate unsafe yang price
    yang_balance = from_wad((await shrine.get_deposit(shrine_user.address, 0, YANG_0_ADDRESS).invoke()).result.wad)
    debt = from_wad((await shrine.get_trove(shrine_user.address, 0).invoke()).result.trove.debt)
    unsafe_price = debt / Decimal("0.85") / yang_balance

    # Update yang price to unsafe level
    await shrine_owner.send_tx(
        shrine.contract_address,
        "advance",
        [YANG_0_ADDRESS, to_wad(unsafe_price)],
    )

    is_healthy = (await shrine.is_healthy(shrine_user.address, 0).invoke()).result.bool
    assert is_healthy == FALSE


@pytest.mark.asyncio
async def test_add_yang(users, shrine):
    shrine_owner = await users("shrine owner")

    g_count = len(YANGS)
    assert (await shrine.get_yangs_count().invoke()).result.ufelt == g_count

    new_yang_address = 987
    new_yang_max = to_wad(42_000)
    new_yang_threshold = to_wad(Decimal("0.6"))
    new_yang_start_price = to_wad(5)
    tx = await shrine_owner.send_tx(
        shrine.contract_address, "add_yang", [new_yang_address, new_yang_max, new_yang_threshold, new_yang_start_price]
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
    assert_event_emitted(tx, shrine.contract_address, "ThresholdUpdated", [new_yang_address, new_yang_threshold])

    # test calling the func unauthorized
    bad_guy = await users("bad guy")
    bad_guy_yang_address = 555
    bad_guy_yang_max = to_wad(10_000)
    bad_guy_yang_threshold = to_wad(Decimal("0.5"))
    bad_guy_yang_start_price = to_wad(10)
    with pytest.raises(StarkException):

        await bad_guy.send_tx(
            shrine.contract_address,
            "add_yang",
            [bad_guy_yang_address, bad_guy_yang_max, bad_guy_yang_threshold, bad_guy_yang_start_price],
        )

    # Test adding duplicate Yang
    with pytest.raises(StarkException, match="Shrine: Yang already exists"):
        await shrine_owner.send_tx(
            shrine.contract_address,
            "add_yang",
            [YANG_0_ADDRESS, new_yang_max, new_yang_threshold, new_yang_start_price],
        )


@pytest.mark.asyncio
async def test_update_yang_max(users, shrine):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    async def update_and_assert(new_yang_max):
        orig_yang = (await shrine.get_yang(YANG_0_ADDRESS).invoke()).result.yang
        tx = await shrine_owner.send_tx(shrine.contract_address, "update_yang_max", [YANG_0_ADDRESS, new_yang_max])
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
    await shrine_owner.send_tx(
        shrine.contract_address,
        "deposit",
        [YANG_0_ADDRESS, deposit_amt, shrine_user.address, 0],
    )  # Deposit 100 yang tokens

    new_yang_max = deposit_amt - to_wad(1)
    await update_and_assert(
        new_yang_max
    )  # update yang_max to a value smaller than the total amount currently deposited

    # This should fail, since yang.total exceeds yang.max
    with pytest.raises(
        StarkException,
        match="Shrine: Exceeds maximum amount of Yang allowed for system",
    ):
        await shrine_owner.send_tx(
            shrine.contract_address,
            "deposit",
            [YANG_0_ADDRESS, deposit_amt, shrine_user.address, 0],
        )

    # test calling with a non-existing yang_address
    faux_yang_address = 7890
    with pytest.raises(StarkException, match="Shrine: Yang does not exist"):
        await shrine_owner.send_tx(
            shrine.contract_address,
            "update_yang_max",
            [faux_yang_address, new_yang_max],
        )

    # test calling the func unauthorized
    bad_guy = await users("bad guy")
    with pytest.raises(StarkException):
        await bad_guy.send_tx(shrine.contract_address, "update_yang_max", [YANG_0_ADDRESS, 2**251])


@pytest.mark.asyncio
async def test_set_threshold(users, shrine):
    shrine_owner = await users("shrine owner")

    # test setting to normal value
    value = 9 * 10**26
    tx = await shrine_owner.send_tx(shrine.contract_address, "set_threshold", [YANGS[0]["address"], value])
    assert_event_emitted(tx, shrine.contract_address, "ThresholdUpdated", [YANGS[0]["address"], value])
    assert (await shrine.get_threshold(YANGS[0]["address"]).invoke()).result.ray == value

    # test setting to max value
    max = RAY_SCALE
    tx = await shrine_owner.send_tx(shrine.contract_address, "set_threshold", [YANGS[0]["address"], max])
    assert_event_emitted(tx, shrine.contract_address, "ThresholdUpdated", [YANGS[0]["address"], max])
    assert (await shrine.get_threshold(YANGS[0]["address"]).invoke()).result.ray == max

    # test setting over the limit
    with pytest.raises(StarkException, match="Shrine: Threshold exceeds 100%"):
        await shrine_owner.send_tx(shrine.contract_address, "set_threshold", [YANGS[0]["address"], max + 1])

    # test calling the func unauthorized
    bad_guy = await users("bad guy")
    with pytest.raises(StarkException):
        await bad_guy.send_tx(shrine.contract_address, "set_threshold", [YANGS[0]["address"], value])


@pytest.mark.asyncio
async def test_kill(users, shrine, update_feeds):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    tx = await shrine_owner.send_tx(shrine.contract_address, "kill", [])
    assert_event_emitted(tx, shrine.contract_address, "Killed")

    # Check deposit fails
    with pytest.raises(StarkException, match="Shrine: System is not live"):
        await shrine_owner.send_tx(
            shrine.contract_address,
            "deposit",
            [YANG_0_ADDRESS, to_wad(10), shrine_user.address, 0],
        )

    # Check forge fails
    with pytest.raises(StarkException, match="Shrine: System is not live"):
        await shrine_owner.send_tx(shrine.contract_address, "forge", [to_wad(100), shrine_user.address, 0])

    # Test withdraw pass
    await shrine_owner.send_tx(
        shrine.contract_address,
        "withdraw",
        [YANG_0_ADDRESS, to_wad(1), shrine_user.address, 0],
    )

    # Test melt pass
    await shrine_owner.send_tx(shrine.contract_address, "melt", [to_wad(100), shrine_user.address, 0])


@pytest.mark.asyncio
async def test_set_ceiling(users, shrine):
    shrine_owner = await users("shrine owner")

    new_ceiling = to_wad(20_000_000)
    tx = await shrine_owner.send_tx(shrine.contract_address, "set_ceiling", [new_ceiling])
    assert_event_emitted(tx, shrine.contract_address, "CeilingUpdated", [new_ceiling])
    assert (await shrine.get_ceiling().invoke()).result.wad == new_ceiling

    # test calling func unauthorized
    bad_guy = await users("bad guy")
    with pytest.raises(StarkException):
        await bad_guy.send_tx(shrine.contract_address, "set_ceiling", [1])


@pytest.mark.asyncio
async def test_get_trove_threshold(users, shrine, shrine_deposit_multiple):
    shrine_user = await users("shrine user")

    prices = []
    for d in DEPOSITS:
        price = (await shrine.get_current_yang_price(d["address"]).invoke()).result.price_wad
        prices.append(price)

    expected_threshold = calculate_trove_threshold(
        prices, [d["amount"] for d in DEPOSITS], [d["threshold"] for d in DEPOSITS]
    )

    # Getting actual threshold
    actual_threshold = (await shrine.get_trove_threshold(shrine_user.address, 0).invoke()).result.threshold_ray
    assert_equalish(from_ray(actual_threshold), expected_threshold)
