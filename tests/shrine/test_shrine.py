from collections import namedtuple
from decimal import Decimal, localcontext
from typing import List

import pytest

from starkware.starkware_utils.error_handling import StarkException
from starkware.starknet.testing.objects import StarknetTransactionExecutionInfo

from utils import (
    assert_event_emitted,
    create_feed,
    set_block_timestamp,
    to_wad,
    assert_equalish,
    from_ray,
    from_wad,
    WAD_SCALE,
    RAY_SCALE,
    TRUE,
    FALSE,
)

from constants import *  # noqa: F403

#
# Structs
#

Gage = namedtuple("Gage", ["total", "max"])


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
    gages_amt: List[Decimal],
    gages_price: [List[List[Decimal]]],
    multiplier: List[Decimal],
    debt: Decimal,
) -> Decimal:
    """
    Helper function to calculate the compounded debt.

    Arguments
    ---------
    gages_amt : List[Decimal]
        Ordered list of the amount of each Gage
    gages_price: List[List[Decimal]]
        For each Gage in `gages_amt` in the same order, an ordered list of prices
        beginning from the start interval to the end interval.
    multiplier: List[Decimal]
        List of multiplier values from the start interval to the end interval
    debt : Decimal
        Amount of debt at the start interval

    Returns
    -------
    Value of the compounded debt from start interval to end interval in
    Decimal with ray precision of 27 decimals.
    """
    # Sanity check on input data
    assert len(gages_amt) == len(gages_price)
    for i in range(len(gages_amt)):
        assert len(gages_price[i]) == len(multiplier)

    # Get number of iterations
    total_intervals = len(gages_price[0])

    # Loop through each interval
    for i in range(total_intervals):
        total_gage_val = 0

        # Loop through each gage
        for j in range(len(gages_amt)):
            total_gage_val += gages_amt[j] * gages_price[j][i]

            # Override decimal context using ray precision of 27 decimals
            with localcontext() as ctx:
                ctx.prec = 27
                # Calculate LTV
                ltv = Decimal(debt) / Decimal(total_gage_val)

                # Calculate base rate
                b = base_rate(ltv)

                # Calculate interest rate
                ir = b * multiplier[i]

                # Account for interval length
                real_ir = ir * TIME_INTERVAL_DIV_YEAR

                # Get chargeable interest
                charge = real_ir * debt

                # Add to debt
                debt += charge

    return debt


#
# Fixtures
#


@pytest.fixture
async def shrine_deposit(users, shrine) -> StarknetTransactionExecutionInfo:
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    deposit = await shrine_owner.send_tx(shrine.contract_address, "deposit", [0, to_wad(10), shrine_user.address, 0])
    return deposit


@pytest.fixture
async def shrine_forge(users, shrine, shrine_deposit) -> StarknetTransactionExecutionInfo:
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    forge = await shrine_owner.send_tx(shrine.contract_address, "forge", [shrine_user.address, 0, to_wad(5000)])
    return forge


@pytest.fixture
async def shrine_melt(users, shrine, shrine_forge) -> StarknetTransactionExecutionInfo:
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    estimated_debt = (await shrine.estimate(shrine_user.address, 0).invoke()).result.amount
    melt = await shrine_owner.send_tx(shrine.contract_address, "melt", [shrine_user.address, 0, estimated_debt])

    return melt


@pytest.fixture
async def shrine_withdrawal(users, shrine, shrine_deposit) -> StarknetTransactionExecutionInfo:
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    withdrawal = await shrine_owner.send_tx(
        shrine.contract_address, "withdraw", [0, to_wad(10), shrine_user.address, 0]
    )
    return withdrawal


@pytest.fixture
async def update_feeds(starknet, users, shrine, shrine_forge) -> List[Decimal]:
    """
    Additional price feeds for gage 0 after `shrine_forge`
    """
    shrine_owner = await users("shrine owner")

    gage0_feed = create_feed(GAGES[0]["start_price"], FEED_LEN, MAX_PRICE_CHANGE)

    for i in range(FEED_LEN):
        # Add offset for initial feeds in `shrine`
        timestamp = (i + FEED_LEN) * 30 * SECONDS_PER_MINUTE
        set_block_timestamp(starknet.state, timestamp)
        await shrine_owner.send_tx(shrine.contract_address, "advance", [0, gage0_feed[i], timestamp])
        await shrine_owner.send_tx(
            shrine.contract_address,
            "update_multiplier",
            [MULTIPLIER_FEED[i], timestamp],
        )

    return list(map(from_wad, gage0_feed))


#
# Tests
#


@pytest.mark.asyncio
async def test_shrine_setup(shrine):
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
    assert gage_count == len(GAGES)

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
async def test_shrine_deposit(users, shrine, shrine_deposit):
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
async def test_shrine_withdrawal_pass(users, shrine, shrine_withdrawal):
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
async def test_shrine_forge_pass(users, shrine, shrine_forge):
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
    trove_ltv = (await shrine.trove_ratio_current(shrine_user.address, 0).invoke()).result.ratio
    adjusted_trove_ltv = Decimal(trove_ltv) / RAY_SCALE
    expected_ltv = Decimal(to_wad(5000)) / Decimal(10 * gage0_price)
    assert_equalish(adjusted_trove_ltv, expected_ltv)

    healthy = (await shrine.is_healthy(shrine_user.address, 0).invoke()).result.healthy
    assert healthy == 1


@pytest.mark.asyncio
async def test_shrine_melt_pass(users, shrine, shrine_melt):
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
        [shrine_user.address, 0, FEED_LEN, 0],
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
async def test_charge(users, shrine, update_feeds):
    shrine_user = await users("shrine user")

    trove = (await shrine.get_trove(shrine_user.address, 0).invoke()).result.trove
    assert trove.last == FEED_LEN - 1

    last_updated = (await shrine.get_series(0, 39).invoke()).result.price
    assert last_updated != 0

    # Get gage price and multipler value at `trove.last`
    start_price = (await shrine.get_series(0, trove.last).invoke()).result.price
    start_multiplier = (await shrine.get_multiplier(trove.last).invoke()).result.rate

    tx = await shrine_user.send_tx(shrine.contract_address, "charge", [shrine_user.address, 0])

    updated_trove = (await shrine.get_trove(shrine_user.address, 0).invoke()).result.trove

    expected_debt = compound(
        [Decimal("10")],
        [[from_wad(start_price)] + update_feeds],
        [from_ray(start_multiplier)] + [Decimal("1")] * FEED_LEN,
        Decimal("5000"),
    )

    adjusted_trove_debt = Decimal(updated_trove.debt) / WAD_SCALE
    assert_equalish(adjusted_trove_debt, expected_debt)
    assert updated_trove.last == FEED_LEN * 2

    assert_event_emitted(tx, shrine.contract_address, "SyntheticTotalUpdated", [updated_trove.debt])
    assert_event_emitted(
        tx,
        shrine.contract_address,
        "TroveUpdated",
        [shrine_user.address, 0, updated_trove.last, updated_trove.debt],
    )

    # `charge` should not have any effect if `Trove.last` is current interval + 1
    redundant_tx = await shrine_user.send_tx(shrine.contract_address, "charge", [shrine_user.address, 0])
    redundant_trove = (await shrine.get_trove(shrine_user.address, 0).invoke()).result.trove
    assert updated_trove == redundant_trove
    assert_event_emitted(
        redundant_tx,
        shrine.contract_address,
        "SyntheticTotalUpdated",
        [updated_trove.debt],
    )
    assert_event_emitted(
        redundant_tx,
        shrine.contract_address,
        "TroveUpdated",
        [shrine_user.address, 0, updated_trove.last, updated_trove.debt],
    )


@pytest.mark.asyncio
async def test_move_gage_pass(users, shrine, shrine_forge):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    # Move gage between two troves of the same user
    intra_user_tx = await shrine_owner.send_tx(
        shrine.contract_address,
        "move_gage",
        [0, to_wad(1), shrine_user.address, 0, shrine_user.address, 1],
    )

    assert_event_emitted(
        intra_user_tx,
        shrine.contract_address,
        "DepositUpdated",
        [shrine_user.address, 0, 0, to_wad(9)],
    )
    assert_event_emitted(
        intra_user_tx,
        shrine.contract_address,
        "DepositUpdated",
        [shrine_user.address, 1, 0, to_wad(1)],
    )

    src_amt = (await shrine.get_deposit(shrine_user.address, 0, 0).invoke()).result.amount
    assert src_amt == to_wad(9)

    dst_amt = (await shrine.get_deposit(shrine_user.address, 1, 0).invoke()).result.amount
    assert dst_amt == to_wad(1)

    # Move gage between two different users
    shrine_guest = await users("shrine guest")
    intra_user_tx = await shrine_owner.send_tx(
        shrine.contract_address,
        "move_gage",
        [0, to_wad(1), shrine_user.address, 0, shrine_guest.address, 0],
    )

    assert_event_emitted(
        intra_user_tx,
        shrine.contract_address,
        "DepositUpdated",
        [shrine_user.address, 0, 0, to_wad(8)],
    )
    assert_event_emitted(
        intra_user_tx,
        shrine.contract_address,
        "DepositUpdated",
        [shrine_guest.address, 0, 0, to_wad(1)],
    )

    src_amt = (await shrine.get_deposit(shrine_user.address, 0, 0).invoke()).result.amount
    assert src_amt == to_wad(8)

    dst_amt = (await shrine.get_deposit(shrine_guest.address, 0, 0).invoke()).result.amount
    assert dst_amt == to_wad(1)


@pytest.mark.asyncio
async def test_shrine_withdrawal_unsafe_fail(users, shrine, update_feeds):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    with pytest.raises(StarkException, match="Shrine: Trove is at risk after gage withdrawal"):
        await shrine_owner.send_tx(shrine.contract_address, "withdraw", [0, to_wad(7), shrine_user.address, 0])


@pytest.mark.asyncio
async def test_shrine_forge_unsafe_fail(users, shrine, update_feeds):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    # Increase debt ceiling
    new_ceiling = to_wad(100_000)
    await shrine_owner.send_tx(shrine.contract_address, "set_ceiling", [new_ceiling])

    with pytest.raises(StarkException, match="Shrine: Trove is at risk after forge"):
        await shrine_owner.send_tx(shrine.contract_address, "forge", [shrine_user.address, 0, to_wad(12_000)])


@pytest.mark.asyncio
async def test_shrine_forge_ceiling_fail(users, shrine, update_feeds):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    # Deposit more gage
    await shrine_owner.send_tx(shrine.contract_address, "deposit", [0, to_wad(10), shrine_user.address, 0])
    updated_deposit = (await shrine.get_deposit(shrine_user.address, 0, 0).invoke()).result.amount
    assert updated_deposit == to_wad(20)

    with pytest.raises(StarkException, match="Shrine: Debt ceiling reached"):
        await shrine_owner.send_tx(shrine.contract_address, "forge", [shrine_user.address, 0, to_wad(15_000)])


@pytest.mark.asyncio
async def test_add_gage(users, shrine):
    shrine_owner = await users("shrine owner")

    g_count = len(GAGES)
    assert (await shrine.get_num_gages().invoke()).result.num == g_count

    new_gage_max = to_wad(42_000)
    tx = await shrine_owner.send_tx(shrine.contract_address, "add_gage", [new_gage_max])
    assert (await shrine.get_num_gages().invoke()).result.num == g_count + 1
    assert_event_emitted(tx, shrine.contract_address, "GageAdded", [g_count, new_gage_max])
    assert_event_emitted(tx, shrine.contract_address, "NumGagesUpdated", [g_count + 1])

    # test calling the func unauthorized
    bad_guy = await users("bad guy")
    with pytest.raises(StarkException):
        await bad_guy.send_tx(shrine.contract_address, "add_gage", [1])


@pytest.mark.asyncio
async def test_update_gage_max(users, shrine):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    gage_id = 0
    orig_gage_max = GAGES[0]["ceiling"]

    async def update_and_assert(new_gage_max):
        orig_gage = (await shrine.get_gage(gage_id).invoke()).result.gage
        tx = await shrine_owner.send_tx(shrine.contract_address, "update_gage_max", [gage_id, new_gage_max])
        assert_event_emitted(tx, shrine.contract_address, "GageMaxUpdated", [gage_id, new_gage_max])

        updated_gage = (await shrine.get_gage(gage_id).invoke()).result.gage
        assert updated_gage.total == orig_gage.total
        assert updated_gage.max == new_gage_max

    # test increasing the max
    new_gage_max = orig_gage_max * 2
    await update_and_assert(new_gage_max)

    # test decreasing the max
    new_gage_max = orig_gage_max - 1
    await update_and_assert(new_gage_max)

    # test decreasing the max below gage.total
    deposit_amt = to_wad(100)
    await shrine_owner.send_tx(
        shrine.contract_address, "deposit", [0, deposit_amt, shrine_user.address, 0]
    )  # Deposit 20 gage tokens

    new_gage_max = deposit_amt - to_wad(1)
    await update_and_assert(
        new_gage_max
    )  # update gage_max to a value smaller than the total amount currently deposited

    # This should fail, since gage.total exceeds gage.max
    with pytest.raises(StarkException):
        await shrine_owner.send_tx(shrine.contract_address, "deposit", [0, deposit_amt, shrine_user.address, 0])

    # test calling with a non-existing gage_id
    # faux_gage_id = 7890
    # with pytest.raises(StarkException):
    #     await shrine_owner.send_tx(shrine.contract_address, "update_gage_max", [faux_gage_id, new_gage_max])

    # test calling the func unauthorized
    bad_guy = await users("bad guy")
    with pytest.raises(StarkException):
        await bad_guy.send_tx(shrine.contract_address, "update_gage_max", [0, 2**251])


@pytest.mark.asyncio
async def test_set_threshold(users, shrine):
    shrine_owner = await users("shrine owner")

    # test setting to normal value
    value = 9 * 10**17
    tx = await shrine_owner.send_tx(shrine.contract_address, "set_threshold", [value])
    assert_event_emitted(tx, shrine.contract_address, "ThresholdUpdated", [value])
    assert (await shrine.get_threshold().invoke()).result.threshold == value

    # test setting to max value
    max = WAD_SCALE
    tx = await shrine_owner.send_tx(shrine.contract_address, "set_threshold", [max])
    assert_event_emitted(tx, shrine.contract_address, "ThresholdUpdated", [max])
    assert (await shrine.get_threshold().invoke()).result.threshold == max

    # test setting over the limit
    with pytest.raises(StarkException, match="Shrine: Threshold exceeds 100%"):
        await shrine_owner.send_tx(shrine.contract_address, "set_threshold", [max + 1])

    # test calling the func unauthorized
    bad_guy = await users("bad guy")
    with pytest.raises(StarkException):
        await bad_guy.send_tx(shrine.contract_address, "set_threshold", [value])


@pytest.mark.asyncio
async def test_kill(users, shrine, update_feeds):
    shrine_owner = await users("shrine owner")
    shrine_user = await users("shrine user")

    tx = await shrine_owner.send_tx(shrine.contract_address, "kill", [])
    assert_event_emitted(tx, shrine.contract_address, "Killed")

    # Check deposit fails
    with pytest.raises(StarkException, match="Shrine: System is not live"):
        await shrine_owner.send_tx(shrine.contract_address, "deposit", [0, to_wad(10), shrine_user.address, 0])

    # Check forge fails
    with pytest.raises(StarkException, match="Shrine: System is not live"):
        await shrine_owner.send_tx(shrine.contract_address, "forge", [shrine_user.address, 0, to_wad(100)])

    # Test withdraw pass
    await shrine_owner.send_tx(shrine.contract_address, "withdraw", [0, to_wad(1), shrine_user.address, 0])

    # Test melt pass
    await shrine_owner.send_tx(shrine.contract_address, "melt", [shrine_user.address, 0, to_wad(100)])


@pytest.mark.asyncio
async def test_set_ceiling(users, shrine):
    shrine_owner = await users("shrine owner")

    new_ceiling = to_wad(20_000_000)
    tx = await shrine_owner.send_tx(shrine.contract_address, "set_ceiling", [new_ceiling])
    assert_event_emitted(tx, shrine.contract_address, "CeilingUpdated", [new_ceiling])
    assert (await shrine.get_ceiling().invoke()).result.ceiling == new_ceiling

    # test calling func unauthorized
    bad_guy = await users("bad guy")
    with pytest.raises(StarkException):
        await bad_guy.send_tx(shrine.contract_address, "add_gage", [1])
