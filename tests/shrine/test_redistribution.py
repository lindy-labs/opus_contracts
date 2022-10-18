from decimal import Decimal

import pytest

from tests.shrine.constants import *  # noqa: F403
from tests.utils import (
    SHRINE_OWNER,
    TIME_INTERVAL,
    TROVE1_OWNER,
    TROVE2_OWNER,
    TROVE3_OWNER,
    TROVE_1,
    TROVE_2,
    TROVE_3,
    assert_equalish,
    assert_event_emitted,
    create_feed,
    from_wad,
    get_block_timestamp,
    set_block_timestamp,
    to_ray,
    to_wad,
)

#
# Constants
#

DEPOSITS = {
    TROVE_1: {
        YANG1_ADDRESS: Decimal("5"),
        YANG2_ADDRESS: Decimal("100"),
        YANG3_ADDRESS: Decimal("100_000"),
    },
    TROVE_2: {
        YANG1_ADDRESS: Decimal("15"),
        YANG2_ADDRESS: Decimal("500"),
        YANG3_ADDRESS: Decimal("250_000"),
    },
    TROVE_3: {
        YANG1_ADDRESS: Decimal("7.5"),
        YANG2_ADDRESS: Decimal("277"),
        YANG3_ADDRESS: Decimal("123_456"),
    },
}

#
# Fixtures
#


@pytest.fixture
async def redistribution_setup(shrine):
    await shrine.set_ceiling(to_wad(Decimal("1_000_000"))).execute(caller_address=SHRINE_OWNER)
    await shrine.grant_role(ShrineRoles.REDISTRIBUTE, MOCK_PURGER).execute(caller_address=SHRINE_OWNER)


# Trove fixtures with 1 yang
@pytest.fixture
async def shrine_single_yang_trove1(shrine):
    deposit_amt = to_wad(DEPOSITS[TROVE_1][YANG1_ADDRESS])
    await shrine.deposit(YANG1_ADDRESS, TROVE_1, deposit_amt).execute(caller_address=SHRINE_OWNER)
    max_forge_amt = (await shrine.get_max_forge(TROVE_1).execute()).result.max
    forge_amt = max_forge_amt // 2
    await shrine.forge(TROVE1_OWNER, TROVE_1, forge_amt).execute(caller_address=SHRINE_OWNER)


@pytest.fixture
async def shrine_single_yang_trove2(shrine):
    deposit_amt = to_wad(DEPOSITS[TROVE_2][YANG1_ADDRESS])
    await shrine.deposit(YANG1_ADDRESS, TROVE_2, deposit_amt).execute(caller_address=SHRINE_OWNER)
    max_forge_amt = (await shrine.get_max_forge(TROVE_2).execute()).result.max
    forge_amt = max_forge_amt // 2
    await shrine.forge(TROVE2_OWNER, TROVE_2, forge_amt).execute(caller_address=SHRINE_OWNER)


@pytest.fixture
async def shrine_single_yang_trove3(shrine):
    deposit_amt = to_wad(DEPOSITS[TROVE_3][YANG1_ADDRESS])
    await shrine.deposit(YANG1_ADDRESS, TROVE_3, deposit_amt).execute(caller_address=SHRINE_OWNER)
    max_forge_amt = (await shrine.get_max_forge(TROVE_3).execute()).result.max
    forge_amt = max_forge_amt // 2
    await shrine.forge(TROVE3_OWNER, TROVE_3, forge_amt).execute(caller_address=SHRINE_OWNER)


@pytest.fixture
async def update_feeds_single_yang(
    starknet, shrine, shrine_single_yang_trove1, shrine_single_yang_trove2, shrine_single_yang_trove3
):

    yang1_start_price = from_wad((await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result.price)
    yang2_start_price = from_wad((await shrine.get_current_yang_price(YANG2_ADDRESS).execute()).result.price)
    yang3_start_price = from_wad((await shrine.get_current_yang_price(YANG3_ADDRESS).execute()).result.price)

    start_prices = [yang1_start_price, yang2_start_price, yang3_start_price]
    feeds = [create_feed(p, FEED_LEN, MAX_PRICE_CHANGE) for p in start_prices]

    # Putting the price feeds in the `shrine_yang_price_storage` storage variable
    for i in range(1, FEED_LEN):
        timestamp = get_block_timestamp(starknet)
        new_timestamp = timestamp + i * TIME_INTERVAL
        set_block_timestamp(starknet, new_timestamp)

        for j in range(len(YANGS)):
            await shrine.advance(YANGS[j]["address"], feeds[j][i]).execute(caller_address=SHRINE_OWNER)

        await shrine.update_multiplier(to_ray(Decimal("1"))).execute(caller_address=SHRINE_OWNER)


@pytest.mark.usefixtures("redistribution_setup", "update_feeds_single_yang")
@pytest.mark.asyncio
async def test_shrine_single_yang_one_redistribution(shrine):

    before_yang_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert before_yang_bal > 0
    estimated_debt = (await shrine.estimate(TROVE_1).execute()).result.debt

    redistribute_trove_1 = await shrine.redistribute(TROVE_1).execute(caller_address=MOCK_PURGER)
    assert_event_emitted(
        redistribute_trove_1,
        shrine.contract_address,
        "TroveRedistributed",
        [TROVE_1, estimated_debt],
    )

    after_yang_bal = (await shrine.get_deposit(YANG_0_ADDRESS, TROVE_1).execute()).result.balance
    assert after_yang_bal == 0

    yang_pending_debt = (await shrine.get_pending_debt(YANG_0_ADDRESS).execute()).result.pending_debt
    assert yang_pending_debt.total == estimated_debt

    expected_remaining_yang = DEPOSITS[TROVE_2][YANG1_ADDRESS] + DEPOSITS[TROVE_3][YANG1_ADDRESS]
    expected_debt_per_yang = from_wad(estimated_debt) / expected_remaining_yang
    assert_equalish(from_wad(yang_pending_debt.debt_per_yang), expected_debt_per_yang)
