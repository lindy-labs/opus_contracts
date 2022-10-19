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
    estimate_gas,
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
# Helpers
#


def get_resources(tx):
    return tx.call_info.execution_resources


#
# Fixtures
#


@pytest.fixture
async def redistribution_setup(shrine):
    await shrine.set_ceiling(to_wad(Decimal("1_000_000"))).execute(caller_address=SHRINE_OWNER)
    await shrine.grant_role(ShrineRoles.REDISTRIBUTE, MOCK_PURGER).execute(caller_address=SHRINE_OWNER)


@pytest.fixture
async def update_feeds(starknet, shrine):

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


#
# Fixtures for 1 yang
#


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
    shrine_single_yang_trove1, shrine_single_yang_trove2, shrine_single_yang_trove3, update_feeds
):
    return


#
# Fixtures for 2 yang
#


DOUBLE_YANG_ADDRESSES = [YANG1_ADDRESS, YANG2_ADDRESS]


@pytest.fixture
async def shrine_double_yang_trove1(shrine):
    for a in DOUBLE_YANG_ADDRESSES:
        deposit_amt = to_wad(DEPOSITS[TROVE_1][a])
        await shrine.deposit(a, TROVE_1, deposit_amt).execute(caller_address=SHRINE_OWNER)
    max_forge_amt = (await shrine.get_max_forge(TROVE_1).execute()).result.max
    forge_amt = max_forge_amt // 2
    await shrine.forge(TROVE1_OWNER, TROVE_1, forge_amt).execute(caller_address=SHRINE_OWNER)


@pytest.fixture
async def shrine_double_yang_trove2(shrine):
    for a in DOUBLE_YANG_ADDRESSES:
        deposit_amt = to_wad(DEPOSITS[TROVE_2][a])
        await shrine.deposit(a, TROVE_2, deposit_amt).execute(caller_address=SHRINE_OWNER)
    max_forge_amt = (await shrine.get_max_forge(TROVE_2).execute()).result.max
    forge_amt = max_forge_amt // 2
    await shrine.forge(TROVE2_OWNER, TROVE_2, forge_amt).execute(caller_address=SHRINE_OWNER)


@pytest.fixture
async def shrine_double_yang_trove3(shrine):
    for a in DOUBLE_YANG_ADDRESSES:
        deposit_amt = to_wad(DEPOSITS[TROVE_3][a])
        await shrine.deposit(a, TROVE_3, deposit_amt).execute(caller_address=SHRINE_OWNER)
    max_forge_amt = (await shrine.get_max_forge(TROVE_3).execute()).result.max
    forge_amt = max_forge_amt // 2
    await shrine.forge(TROVE3_OWNER, TROVE_3, forge_amt).execute(caller_address=SHRINE_OWNER)


@pytest.fixture
async def update_feeds_double_yang(
    shrine_double_yang_trove1, shrine_double_yang_trove2, shrine_double_yang_trove3, update_feeds
):
    return


#
# Fixtures for 3 yang
#


TRIPLE_YANG_ADDRESSES = [YANG1_ADDRESS, YANG2_ADDRESS, YANG3_ADDRESS]


@pytest.fixture
async def shrine_triple_yang_trove1(shrine):
    for a in TRIPLE_YANG_ADDRESSES:
        deposit_amt = to_wad(DEPOSITS[TROVE_1][a])
        await shrine.deposit(a, TROVE_1, deposit_amt).execute(caller_address=SHRINE_OWNER)
    max_forge_amt = (await shrine.get_max_forge(TROVE_1).execute()).result.max
    forge_amt = max_forge_amt // 2
    await shrine.forge(TROVE1_OWNER, TROVE_1, forge_amt).execute(caller_address=SHRINE_OWNER)


@pytest.fixture
async def shrine_triple_yang_trove2(shrine):
    for a in TRIPLE_YANG_ADDRESSES:
        deposit_amt = to_wad(DEPOSITS[TROVE_2][a])
        await shrine.deposit(a, TROVE_2, deposit_amt).execute(caller_address=SHRINE_OWNER)
    max_forge_amt = (await shrine.get_max_forge(TROVE_2).execute()).result.max
    forge_amt = max_forge_amt // 2
    await shrine.forge(TROVE2_OWNER, TROVE_2, forge_amt).execute(caller_address=SHRINE_OWNER)


@pytest.fixture
async def shrine_triple_yang_trove3(shrine):
    for a in TRIPLE_YANG_ADDRESSES:
        deposit_amt = to_wad(DEPOSITS[TROVE_3][a])
        await shrine.deposit(a, TROVE_3, deposit_amt).execute(caller_address=SHRINE_OWNER)
    max_forge_amt = (await shrine.get_max_forge(TROVE_3).execute()).result.max
    forge_amt = max_forge_amt // 2
    await shrine.forge(TROVE3_OWNER, TROVE_3, forge_amt).execute(caller_address=SHRINE_OWNER)


@pytest.fixture
async def update_feeds_triple_yang(
    shrine_triple_yang_trove1, shrine_triple_yang_trove2, shrine_triple_yang_trove3, update_feeds
):
    return


#
# Tests - Single yang
#


@pytest.mark.usefixtures("redistribution_setup", "update_feeds_single_yang")
@pytest.mark.asyncio
async def test_shrine_single_yang_one_redistribution(shrine):

    before_yang_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert before_yang_bal > 0
    estimated_trove1_debt = (await shrine.estimate(TROVE_1).execute()).result.debt
    estimated_trove2_debt = (await shrine.estimate(TROVE_2).execute()).result.debt

    # Simulate purge with 0 yin
    await shrine.melt(TROVE1_OWNER, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)
    redistribute_trove_1 = await shrine.redistribute(TROVE_1).execute(caller_address=MOCK_PURGER)
    assert_event_emitted(
        redistribute_trove_1,
        shrine.contract_address,
        "TroveRedistributed",
        [TROVE_1, estimated_trove1_debt],
    )
    # Storage keys updated:
    # - shrine_troves
    # - shrine_deposits
    # - shrine_yangs
    # - shrine_yang_pending_debt
    # - shrine_yang_pending_debt_error
    print(f"\nRedistribute (1 yang, 1 trove) - redistribute: \n{get_resources(redistribute_trove_1)}")
    print(estimate_gas(redistribute_trove_1, 5, 1))

    after_yang_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert after_yang_bal == 0

    yang_pending_debt = (await shrine.get_pending_debt(YANG1_ADDRESS).execute()).result.pending_debt
    assert yang_pending_debt.total == estimated_trove1_debt

    expected_remaining_yang = DEPOSITS[TROVE_2][YANG1_ADDRESS] + DEPOSITS[TROVE_3][YANG1_ADDRESS]
    expected_debt_per_yang = from_wad(estimated_trove1_debt) / expected_remaining_yang
    assert_equalish(from_wad(yang_pending_debt.debt_per_yang), expected_debt_per_yang)

    # Check trove 2 debt
    expected_trove2_debt = from_wad(estimated_trove2_debt) + (DEPOSITS[TROVE_2][YANG1_ADDRESS] * expected_debt_per_yang)
    trove2_debt = from_wad((await shrine.estimate(TROVE_2).execute()).result.debt)
    assert_equalish(trove2_debt, expected_trove2_debt)

    # Check cost of update
    update_trove2 = await shrine.melt(TROVE2_OWNER, TROVE_2, 0).execute(caller_address=SHRINE_OWNER)

    # Storage keys updated
    # - shrine_total_debt (via `estimate`)
    # - shrine_troves (via `estimate`)
    # - shrine_yang_pending_debt
    # - shrine_trove_yang_pending_debt_snapshot
    print(f"\nRedistribute (1 yang, 1 trove) - pull: \n{get_resources(update_trove2)}")
    print(estimate_gas(update_trove2, 4, 1))


@pytest.mark.usefixtures("redistribution_setup", "update_feeds_single_yang")
@pytest.mark.asyncio
async def test_shrine_single_yang_two_redistribution(shrine):

    before_yang_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert before_yang_bal > 0
    estimated_trove1_debt = (await shrine.estimate(TROVE_1).execute()).result.debt
    estimated_trove2_debt = (await shrine.estimate(TROVE_2).execute()).result.debt
    estimated_trove3_debt = (await shrine.estimate(TROVE_3).execute()).result.debt

    # Simulate purge with 0 yin
    await shrine.melt(TROVE1_OWNER, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)
    await shrine.redistribute(TROVE_1).execute(caller_address=MOCK_PURGER)

    await shrine.melt(TROVE2_OWNER, TROVE_2, 0).execute(caller_address=SHRINE_OWNER)
    await shrine.redistribute(TROVE_2).execute(caller_address=MOCK_PURGER)

    assert (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance == 0
    assert (await shrine.get_deposit(YANG1_ADDRESS, TROVE_2).execute()).result.balance == 0

    yang_pending_debt = (await shrine.get_pending_debt(YANG1_ADDRESS).execute()).result.pending_debt
    expected_redistributed_debt = estimated_trove1_debt + estimated_trove2_debt
    assert yang_pending_debt.total == expected_redistributed_debt

    expected_remaining_yang = DEPOSITS[TROVE_3][YANG1_ADDRESS]
    expected_debt_per_yang = from_wad(expected_redistributed_debt) / expected_remaining_yang
    assert_equalish(from_wad(yang_pending_debt.debt_per_yang), expected_debt_per_yang)

    # Check trove 3 debt
    expected_trove3_debt = from_wad(estimated_trove3_debt) + (DEPOSITS[TROVE_3][YANG1_ADDRESS] * expected_debt_per_yang)
    trove3_debt = from_wad((await shrine.estimate(TROVE_3).execute()).result.debt)
    assert_equalish(trove3_debt, expected_trove3_debt)

    # Check cost of update
    update_trove3 = await shrine.melt(TROVE3_OWNER, TROVE_3, 0).execute(caller_address=SHRINE_OWNER)

    # Storage keys updated
    # - shrine_total_debt (via `estimate`)
    # - shrine_troves (via `estimate`)
    # - shrine_yang_pending_debt
    # - shrine_trove_yang_pending_debt_snapshot
    print(f"\nRedistribute (1 yang, 2 troves) - pull: \n{get_resources(update_trove3)}")
    print(estimate_gas(update_trove3, 4, 1))


#
# Tests - Double yang
#


@pytest.mark.usefixtures("redistribution_setup", "update_feeds_double_yang")
@pytest.mark.asyncio
async def test_shrine_double_yang_one_redistribution(shrine):
    before_yang1_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert before_yang1_bal > 0

    before_yang2_bal = (await shrine.get_deposit(YANG2_ADDRESS, TROVE_1).execute()).result.balance
    assert before_yang2_bal > 0

    yang1_price = from_wad((await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result.price)
    yang2_price = from_wad((await shrine.get_current_yang_price(YANG2_ADDRESS).execute()).result.price)

    estimated_trove1_debt = (await shrine.estimate(TROVE_1).execute()).result.debt
    estimated_trove2_debt = (await shrine.estimate(TROVE_2).execute()).result.debt

    before_yang1_val = DEPOSITS[TROVE_1][YANG1_ADDRESS] * yang1_price
    before_yang2_val = DEPOSITS[TROVE_1][YANG2_ADDRESS] * yang2_price
    before_trove_val = before_yang1_val + before_yang2_val

    # Simulate purge with 0 yin
    await shrine.melt(TROVE1_OWNER, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)
    redistribute_trove_1 = await shrine.redistribute(TROVE_1).execute(caller_address=MOCK_PURGER)
    assert_event_emitted(
        redistribute_trove_1,
        shrine.contract_address,
        "TroveRedistributed",
        [TROVE_1, estimated_trove1_debt],
    )
    # Storage keys updated:
    # - shrine_troves
    # - shrine_deposits * 2
    # - shrine_yangs * 2
    # - shrine_yang_pending_debt * 2
    # - shrine_yang_pending_debt_error * 2
    print(f"\nRedistribute (2 yang, 1 trove) - redistribute: \n{get_resources(redistribute_trove_1)}")
    print(estimate_gas(redistribute_trove_1, 9, 1))

    after_yang1_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert after_yang1_bal == 0

    after_yang2_bal = (await shrine.get_deposit(YANG2_ADDRESS, TROVE_1).execute()).result.balance
    assert after_yang2_bal == 0

    # Check yang 1
    yang1_pending_debt = (await shrine.get_pending_debt(YANG1_ADDRESS).execute()).result.pending_debt
    expected_yang1_debt = (before_yang1_val / before_trove_val) * from_wad(estimated_trove1_debt)
    assert_equalish(from_wad(yang1_pending_debt.total), expected_yang1_debt)

    expected_remaining_yang1 = DEPOSITS[TROVE_2][YANG1_ADDRESS] + DEPOSITS[TROVE_3][YANG1_ADDRESS]
    expected_debt_per_yang1 = expected_yang1_debt / expected_remaining_yang1
    assert_equalish(from_wad(yang1_pending_debt.debt_per_yang), expected_debt_per_yang1)

    # Check yang 2
    yang2_pending_debt = (await shrine.get_pending_debt(YANG2_ADDRESS).execute()).result.pending_debt
    expected_yang2_debt = (before_yang2_val / before_trove_val) * from_wad(estimated_trove1_debt)
    assert_equalish(from_wad(yang2_pending_debt.total), expected_yang2_debt)

    expected_remaining_yang2 = DEPOSITS[TROVE_2][YANG2_ADDRESS] + DEPOSITS[TROVE_3][YANG2_ADDRESS]
    expected_debt_per_yang2 = expected_yang2_debt / expected_remaining_yang2
    assert_equalish(from_wad(yang2_pending_debt.debt_per_yang), expected_debt_per_yang2)

    # Check trove 2 debt
    expected_trove2_debt = (
        from_wad(estimated_trove2_debt)
        + (DEPOSITS[TROVE_2][YANG1_ADDRESS] * expected_debt_per_yang1)
        + (DEPOSITS[TROVE_2][YANG2_ADDRESS] * expected_debt_per_yang2)
    )
    trove2_debt = from_wad((await shrine.estimate(TROVE_2).execute()).result.debt)
    assert_equalish(trove2_debt, expected_trove2_debt)

    # Check cost of update
    update_trove2 = await shrine.melt(TROVE2_OWNER, TROVE_2, 0).execute(caller_address=SHRINE_OWNER)

    # Storage keys updated
    # - shrine_total_debt (via `estimate`)
    # - shrine_troves (via `estimate`)
    # - shrine_yang_pending_debt * 2
    # - shrine_trove_yang_pending_debt_snapshot
    print(f"\nRedistribute (2 yangs, 1 trove) - pull: \n{get_resources(update_trove2)}")
    print(estimate_gas(update_trove2, 6, 1))


@pytest.mark.usefixtures("redistribution_setup", "update_feeds_double_yang")
@pytest.mark.asyncio
async def test_shrine_double_yang_two_redistributions(shrine):

    before_trove1_yang1_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert before_trove1_yang1_bal > 0

    before_trove1_yang2_bal = (await shrine.get_deposit(YANG2_ADDRESS, TROVE_1).execute()).result.balance
    assert before_trove1_yang2_bal > 0

    before_trove2_yang1_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_2).execute()).result.balance
    assert before_trove2_yang1_bal > 0

    before_trove2_yang2_bal = (await shrine.get_deposit(YANG2_ADDRESS, TROVE_2).execute()).result.balance
    assert before_trove2_yang2_bal > 0

    yang1_price = from_wad((await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result.price)
    yang2_price = from_wad((await shrine.get_current_yang_price(YANG2_ADDRESS).execute()).result.price)

    estimated_trove1_debt = (await shrine.estimate(TROVE_1).execute()).result.debt
    estimated_trove3_debt = (await shrine.estimate(TROVE_3).execute()).result.debt

    before_trove1_yang1_val = DEPOSITS[TROVE_1][YANG1_ADDRESS] * yang1_price
    before_trove1_yang2_val = DEPOSITS[TROVE_1][YANG2_ADDRESS] * yang2_price
    before_trove1_val = before_trove1_yang1_val + before_trove1_yang2_val

    # Simulate purge with 0 yin
    await shrine.melt(TROVE1_OWNER, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)
    await shrine.redistribute(TROVE_1).execute(caller_address=MOCK_PURGER)

    after_trove1_yang1_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert after_trove1_yang1_bal == 0

    after_trove1_yang2_bal = (await shrine.get_deposit(YANG2_ADDRESS, TROVE_1).execute()).result.balance
    assert after_trove1_yang2_bal == 0

    yang1_pending_debt = (await shrine.get_pending_debt(YANG1_ADDRESS).execute()).result.pending_debt
    expected_trove2_yang1_val_adjustment = DEPOSITS[TROVE_2][YANG1_ADDRESS] * from_wad(yang1_pending_debt.debt_per_yang)

    yang2_pending_debt = (await shrine.get_pending_debt(YANG2_ADDRESS).execute()).result.pending_debt
    expected_trove2_yang2_val_adjustment = DEPOSITS[TROVE_2][YANG2_ADDRESS] * from_wad(yang2_pending_debt.debt_per_yang)

    updated_trove2_yang1_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_2).execute()).result.balance
    updated_trove2_yang2_bal = (await shrine.get_deposit(YANG2_ADDRESS, TROVE_2).execute()).result.balance
    updated_trove2_yang1_val = from_wad(updated_trove2_yang1_bal) * yang1_price
    updated_trove2_yang2_val = from_wad(updated_trove2_yang2_bal) * yang2_price
    updated_trove2_val = updated_trove2_yang1_val + updated_trove2_yang2_val
    updated_estimated_trove2_debt = (await shrine.estimate(TROVE_2).execute()).result.debt

    await shrine.melt(TROVE2_OWNER, TROVE_2, 0).execute(caller_address=SHRINE_OWNER)
    await shrine.redistribute(TROVE_2).execute(caller_address=MOCK_PURGER)

    after_trove2_yang1_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_2).execute()).result.balance
    assert after_trove2_yang1_bal == 0

    after_trove2_yang2_bal = (await shrine.get_deposit(YANG2_ADDRESS, TROVE_2).execute()).result.balance
    assert after_trove2_yang2_bal == 0

    # Check yang 1
    yang1_pending_debt = (await shrine.get_pending_debt(YANG1_ADDRESS).execute()).result.pending_debt
    expected_trove1_yang1_debt = (
        (before_trove1_yang1_val / before_trove1_val) * from_wad(estimated_trove1_debt)
    ) - expected_trove2_yang1_val_adjustment
    expected_trove2_yang1_debt = (updated_trove2_yang1_val / updated_trove2_val) * from_wad(
        updated_estimated_trove2_debt
    )
    expected_yang1_debt = expected_trove1_yang1_debt + expected_trove2_yang1_debt
    assert_equalish(from_wad(yang1_pending_debt.total), expected_yang1_debt)

    expected_remaining_yang1 = DEPOSITS[TROVE_3][YANG1_ADDRESS]
    expected_debt_per_yang1 = expected_yang1_debt / expected_remaining_yang1
    assert_equalish(from_wad(yang1_pending_debt.debt_per_yang), expected_debt_per_yang1)

    # Check yang 2
    yang2_pending_debt = (await shrine.get_pending_debt(YANG2_ADDRESS).execute()).result.pending_debt
    expected_trove1_yang2_debt = (before_trove1_yang2_val / before_trove1_val) * from_wad(
        estimated_trove1_debt
    ) - expected_trove2_yang2_val_adjustment
    expected_trove2_yang2_debt = (updated_trove2_yang2_val / updated_trove2_val) * from_wad(
        updated_estimated_trove2_debt
    )
    expected_yang2_debt = expected_trove1_yang2_debt + expected_trove2_yang2_debt
    assert_equalish(from_wad(yang2_pending_debt.total), expected_yang2_debt)

    expected_remaining_yang2 = DEPOSITS[TROVE_3][YANG2_ADDRESS]
    expected_debt_per_yang2 = expected_yang2_debt / expected_remaining_yang2
    assert_equalish(from_wad(yang2_pending_debt.debt_per_yang), expected_debt_per_yang2)

    # Check trove 3 debt
    expected_trove3_debt = (
        from_wad(estimated_trove3_debt)
        + (DEPOSITS[TROVE_3][YANG1_ADDRESS] * expected_debt_per_yang1)
        + (DEPOSITS[TROVE_3][YANG2_ADDRESS] * expected_debt_per_yang2)
    )
    trove3_debt = from_wad((await shrine.estimate(TROVE_3).execute()).result.debt)
    assert_equalish(trove3_debt, expected_trove3_debt)

    # Check cost of update
    update_trove3 = await shrine.melt(TROVE3_OWNER, TROVE_3, 0).execute(caller_address=SHRINE_OWNER)

    # Storage keys updated
    # - shrine_total_debt (via `estimate`)
    # - shrine_troves (via `estimate`)
    # - shrine_yang_pending_debt * 2
    # - shrine_trove_yang_pending_debt_snapshot * 2
    print(f"\nRedistribute (2 yangs, 2 troves) - pull: \n{get_resources(update_trove3)}")
    print(estimate_gas(update_trove3, 6, 1))


#
# Tests - Triple yang
#


@pytest.mark.usefixtures("redistribution_setup", "update_feeds_triple_yang")
@pytest.mark.asyncio
async def test_shrine_triple_yang_one_redistribution(shrine):

    before_yang1_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert before_yang1_bal > 0

    before_yang2_bal = (await shrine.get_deposit(YANG2_ADDRESS, TROVE_1).execute()).result.balance
    assert before_yang2_bal > 0

    before_yang3_bal = (await shrine.get_deposit(YANG3_ADDRESS, TROVE_1).execute()).result.balance
    assert before_yang3_bal > 0

    yang1_price = from_wad((await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result.price)
    yang2_price = from_wad((await shrine.get_current_yang_price(YANG2_ADDRESS).execute()).result.price)
    yang3_price = from_wad((await shrine.get_current_yang_price(YANG3_ADDRESS).execute()).result.price)

    estimated_trove1_debt = (await shrine.estimate(TROVE_1).execute()).result.debt
    estimated_trove2_debt = (await shrine.estimate(TROVE_2).execute()).result.debt

    before_yang1_val = DEPOSITS[TROVE_1][YANG1_ADDRESS] * yang1_price
    before_yang2_val = DEPOSITS[TROVE_1][YANG2_ADDRESS] * yang2_price
    before_yang3_val = DEPOSITS[TROVE_1][YANG3_ADDRESS] * yang3_price
    before_trove_val = before_yang1_val + before_yang2_val + before_yang3_val

    # Simulate purge with 0 yin
    await shrine.melt(TROVE1_OWNER, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)
    redistribute_trove_1 = await shrine.redistribute(TROVE_1).execute(caller_address=MOCK_PURGER)
    assert_event_emitted(
        redistribute_trove_1,
        shrine.contract_address,
        "TroveRedistributed",
        [TROVE_1, estimated_trove1_debt],
    )
    # Storage keys updated:
    # - shrine_troves
    # - shrine_deposits * 3
    # - shrine_yangs * 3
    # - shrine_yang_pending_debt * 3
    # - shrine_yang_pending_debt_error * 3
    print(f"\nRedistribute (3 yang, 1 trove) - redistribute: \n{get_resources(redistribute_trove_1)}")
    print(estimate_gas(redistribute_trove_1, 13, 1))

    after_yang1_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert after_yang1_bal == 0

    after_yang2_bal = (await shrine.get_deposit(YANG2_ADDRESS, TROVE_1).execute()).result.balance
    assert after_yang2_bal == 0

    after_yang3_bal = (await shrine.get_deposit(YANG3_ADDRESS, TROVE_1).execute()).result.balance
    assert after_yang3_bal == 0

    # Check yang 1
    yang1_pending_debt = (await shrine.get_pending_debt(YANG1_ADDRESS).execute()).result.pending_debt
    expected_yang1_debt = (before_yang1_val / before_trove_val) * from_wad(estimated_trove1_debt)
    assert_equalish(from_wad(yang1_pending_debt.total), expected_yang1_debt)

    expected_remaining_yang1 = DEPOSITS[TROVE_2][YANG1_ADDRESS] + DEPOSITS[TROVE_3][YANG1_ADDRESS]
    expected_debt_per_yang1 = expected_yang1_debt / expected_remaining_yang1
    assert_equalish(from_wad(yang1_pending_debt.debt_per_yang), expected_debt_per_yang1)

    # Check yang 2
    yang2_pending_debt = (await shrine.get_pending_debt(YANG2_ADDRESS).execute()).result.pending_debt
    expected_yang2_debt = (before_yang2_val / before_trove_val) * from_wad(estimated_trove1_debt)
    assert_equalish(from_wad(yang2_pending_debt.total), expected_yang2_debt)

    expected_remaining_yang2 = DEPOSITS[TROVE_2][YANG2_ADDRESS] + DEPOSITS[TROVE_3][YANG2_ADDRESS]
    expected_debt_per_yang2 = expected_yang2_debt / expected_remaining_yang2
    assert_equalish(from_wad(yang2_pending_debt.debt_per_yang), expected_debt_per_yang2)

    # Check yang 3
    yang3_pending_debt = (await shrine.get_pending_debt(YANG3_ADDRESS).execute()).result.pending_debt
    expected_yang3_debt = (before_yang3_val / before_trove_val) * from_wad(estimated_trove1_debt)
    assert_equalish(from_wad(yang3_pending_debt.total), expected_yang3_debt)

    expected_remaining_yang3 = DEPOSITS[TROVE_2][YANG3_ADDRESS] + DEPOSITS[TROVE_3][YANG3_ADDRESS]
    expected_debt_per_yang3 = expected_yang3_debt / expected_remaining_yang3
    assert_equalish(from_wad(yang3_pending_debt.debt_per_yang), expected_debt_per_yang3)

    # Check trove 2 debt
    expected_trove2_debt = (
        from_wad(estimated_trove2_debt)
        + (DEPOSITS[TROVE_2][YANG1_ADDRESS] * expected_debt_per_yang1)
        + (DEPOSITS[TROVE_2][YANG2_ADDRESS] * expected_debt_per_yang2)
        + (DEPOSITS[TROVE_2][YANG3_ADDRESS] * expected_debt_per_yang3)
    )
    trove2_debt = from_wad((await shrine.estimate(TROVE_2).execute()).result.debt)
    assert_equalish(trove2_debt, expected_trove2_debt)

    # Check cost of update
    update_trove2 = await shrine.melt(TROVE2_OWNER, TROVE_2, 0).execute(caller_address=SHRINE_OWNER)

    # Storage keys updated
    # - shrine_total_debt (via `estimate`)
    # - shrine_troves (via `estimate`)
    # - shrine_yang_pending_debt * 3
    # - shrine_trove_yang_pending_debt_snapshot * 3
    print(f"\nRedistribute (3 yangs, 1 trove) - pull: \n{get_resources(update_trove2)}")
    print(estimate_gas(update_trove2, 8, 1))


@pytest.mark.usefixtures("redistribution_setup", "update_feeds_triple_yang")
@pytest.mark.asyncio
async def test_shrine_triple_yang_two_redistributions(shrine):

    before_trove1_yang1_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert before_trove1_yang1_bal > 0

    before_trove1_yang2_bal = (await shrine.get_deposit(YANG2_ADDRESS, TROVE_1).execute()).result.balance
    assert before_trove1_yang2_bal > 0

    before_trove1_yang3_bal = (await shrine.get_deposit(YANG3_ADDRESS, TROVE_1).execute()).result.balance
    assert before_trove1_yang3_bal > 0

    before_trove2_yang1_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_2).execute()).result.balance
    assert before_trove2_yang1_bal > 0

    before_trove2_yang2_bal = (await shrine.get_deposit(YANG2_ADDRESS, TROVE_2).execute()).result.balance
    assert before_trove2_yang2_bal > 0

    before_trove2_yang3_bal = (await shrine.get_deposit(YANG3_ADDRESS, TROVE_2).execute()).result.balance
    assert before_trove2_yang3_bal > 0

    yang1_price = from_wad((await shrine.get_current_yang_price(YANG1_ADDRESS).execute()).result.price)
    yang2_price = from_wad((await shrine.get_current_yang_price(YANG2_ADDRESS).execute()).result.price)
    yang3_price = from_wad((await shrine.get_current_yang_price(YANG3_ADDRESS).execute()).result.price)

    estimated_trove1_debt = (await shrine.estimate(TROVE_1).execute()).result.debt
    estimated_trove3_debt = (await shrine.estimate(TROVE_3).execute()).result.debt

    before_trove1_yang1_val = DEPOSITS[TROVE_1][YANG1_ADDRESS] * yang1_price
    before_trove1_yang2_val = DEPOSITS[TROVE_1][YANG2_ADDRESS] * yang2_price
    before_trove1_yang3_val = DEPOSITS[TROVE_1][YANG3_ADDRESS] * yang3_price
    before_trove1_val = before_trove1_yang1_val + before_trove1_yang2_val + before_trove1_yang3_val

    # Simulate purge with 0 yin
    await shrine.melt(TROVE1_OWNER, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)
    await shrine.redistribute(TROVE_1).execute(caller_address=MOCK_PURGER)

    after_trove1_yang1_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert after_trove1_yang1_bal == 0

    after_trove1_yang2_bal = (await shrine.get_deposit(YANG2_ADDRESS, TROVE_1).execute()).result.balance
    assert after_trove1_yang2_bal == 0

    after_trove1_yang3_bal = (await shrine.get_deposit(YANG3_ADDRESS, TROVE_1).execute()).result.balance
    assert after_trove1_yang3_bal == 0

    yang1_pending_debt = (await shrine.get_pending_debt(YANG1_ADDRESS).execute()).result.pending_debt
    expected_trove2_yang1_val_adjustment = DEPOSITS[TROVE_2][YANG1_ADDRESS] * from_wad(yang1_pending_debt.debt_per_yang)

    yang2_pending_debt = (await shrine.get_pending_debt(YANG2_ADDRESS).execute()).result.pending_debt
    expected_trove2_yang2_val_adjustment = DEPOSITS[TROVE_2][YANG2_ADDRESS] * from_wad(yang2_pending_debt.debt_per_yang)

    yang3_pending_debt = (await shrine.get_pending_debt(YANG3_ADDRESS).execute()).result.pending_debt
    expected_trove2_yang3_val_adjustment = DEPOSITS[TROVE_2][YANG3_ADDRESS] * from_wad(yang3_pending_debt.debt_per_yang)

    updated_trove2_yang1_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_2).execute()).result.balance
    updated_trove2_yang2_bal = (await shrine.get_deposit(YANG2_ADDRESS, TROVE_2).execute()).result.balance
    updated_trove2_yang3_bal = (await shrine.get_deposit(YANG3_ADDRESS, TROVE_2).execute()).result.balance
    updated_trove2_yang1_val = from_wad(updated_trove2_yang1_bal) * yang1_price
    updated_trove2_yang2_val = from_wad(updated_trove2_yang2_bal) * yang2_price
    updated_trove2_yang3_val = from_wad(updated_trove2_yang3_bal) * yang3_price
    updated_trove2_val = updated_trove2_yang1_val + updated_trove2_yang2_val + updated_trove2_yang3_val
    updated_estimated_trove2_debt = (await shrine.estimate(TROVE_2).execute()).result.debt

    await shrine.melt(TROVE2_OWNER, TROVE_2, 0).execute(caller_address=SHRINE_OWNER)
    await shrine.redistribute(TROVE_2).execute(caller_address=MOCK_PURGER)

    after_trove2_yang1_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_2).execute()).result.balance
    assert after_trove2_yang1_bal == 0

    after_trove2_yang2_bal = (await shrine.get_deposit(YANG2_ADDRESS, TROVE_2).execute()).result.balance
    assert after_trove2_yang2_bal == 0

    after_trove2_yang3_bal = (await shrine.get_deposit(YANG3_ADDRESS, TROVE_2).execute()).result.balance
    assert after_trove2_yang3_bal == 0

    # Check yang 1
    yang1_pending_debt = (await shrine.get_pending_debt(YANG1_ADDRESS).execute()).result.pending_debt
    expected_trove1_yang1_debt = (
        (before_trove1_yang1_val / before_trove1_val) * from_wad(estimated_trove1_debt)
    ) - expected_trove2_yang1_val_adjustment
    expected_trove2_yang1_debt = (updated_trove2_yang1_val / updated_trove2_val) * from_wad(
        updated_estimated_trove2_debt
    )
    expected_yang1_debt = expected_trove1_yang1_debt + expected_trove2_yang1_debt
    assert_equalish(from_wad(yang1_pending_debt.total), expected_yang1_debt)

    expected_remaining_yang1 = DEPOSITS[TROVE_3][YANG1_ADDRESS]
    expected_debt_per_yang1 = expected_yang1_debt / expected_remaining_yang1
    assert_equalish(from_wad(yang1_pending_debt.debt_per_yang), expected_debt_per_yang1)

    # Check yang 2
    yang2_pending_debt = (await shrine.get_pending_debt(YANG2_ADDRESS).execute()).result.pending_debt
    expected_trove1_yang2_debt = (before_trove1_yang2_val / before_trove1_val) * from_wad(
        estimated_trove1_debt
    ) - expected_trove2_yang2_val_adjustment
    expected_trove2_yang2_debt = (updated_trove2_yang2_val / updated_trove2_val) * from_wad(
        updated_estimated_trove2_debt
    )
    expected_yang2_debt = expected_trove1_yang2_debt + expected_trove2_yang2_debt
    assert_equalish(from_wad(yang2_pending_debt.total), expected_yang2_debt)

    expected_remaining_yang2 = DEPOSITS[TROVE_3][YANG2_ADDRESS]
    expected_debt_per_yang2 = expected_yang2_debt / expected_remaining_yang2
    assert_equalish(from_wad(yang2_pending_debt.debt_per_yang), expected_debt_per_yang2)

    # Check yang 2
    yang3_pending_debt = (await shrine.get_pending_debt(YANG3_ADDRESS).execute()).result.pending_debt
    expected_trove1_yang3_debt = (before_trove1_yang3_val / before_trove1_val) * from_wad(
        estimated_trove1_debt
    ) - expected_trove2_yang3_val_adjustment
    expected_trove2_yang3_debt = (updated_trove2_yang3_val / updated_trove2_val) * from_wad(
        updated_estimated_trove2_debt
    )
    expected_yang3_debt = expected_trove1_yang3_debt + expected_trove2_yang3_debt
    assert_equalish(from_wad(yang3_pending_debt.total), expected_yang3_debt)

    expected_remaining_yang3 = DEPOSITS[TROVE_3][YANG3_ADDRESS]
    expected_debt_per_yang3 = expected_yang3_debt / expected_remaining_yang3
    assert_equalish(from_wad(yang3_pending_debt.debt_per_yang), expected_debt_per_yang3)

    # Check trove 3 debt
    expected_trove3_debt = (
        from_wad(estimated_trove3_debt)
        + (DEPOSITS[TROVE_3][YANG1_ADDRESS] * expected_debt_per_yang1)
        + (DEPOSITS[TROVE_3][YANG2_ADDRESS] * expected_debt_per_yang2)
        + (DEPOSITS[TROVE_3][YANG3_ADDRESS] * expected_debt_per_yang3)
    )
    trove3_debt = from_wad((await shrine.estimate(TROVE_3).execute()).result.debt)
    assert_equalish(trove3_debt, expected_trove3_debt)

    # Check cost of update
    update_trove3 = await shrine.melt(TROVE3_OWNER, TROVE_3, 0).execute(caller_address=SHRINE_OWNER)

    # Storage keys updated
    # - shrine_total_debt (via `estimate`)
    # - shrine_troves (via `estimate`)
    # - shrine_yang_pending_debt * 3
    # - shrine_trove_yang_pending_debt_snapshot * 3
    print(f"\nRedistribute (3 yangs, 2 troves) - pull: \n{get_resources(update_trove3)}")
    print(estimate_gas(update_trove3, 8, 1))
