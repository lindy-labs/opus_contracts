from decimal import Decimal
from itertools import combinations

import pytest
from starkware.starknet.testing.contract import StarknetContract

from tests.roles import ShrineRoles
from tests.shrine.constants import MOCK_PURGER, YANG1_ADDRESS, YANG2_ADDRESS, YANG3_ADDRESS, YANG4_ADDRESS
from tests.utils import (
    SHRINE_OWNER,
    TROVE1_OWNER,
    TROVE2_OWNER,
    TROVE3_OWNER,
    TROVE_1,
    TROVE_2,
    TROVE_3,
    assert_equalish,
    assert_event_emitted,
    estimate_gas,
    from_wad,
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
        YANG4_ADDRESS: Decimal("1_500"),
    },
    TROVE_2: {
        YANG1_ADDRESS: Decimal("15"),
        YANG2_ADDRESS: Decimal("500"),
        YANG3_ADDRESS: Decimal("250_000"),
        YANG4_ADDRESS: Decimal("2_500"),
    },
    TROVE_3: {
        YANG1_ADDRESS: Decimal("7.5"),
        YANG2_ADDRESS: Decimal("277"),
        YANG3_ADDRESS: Decimal("123_456"),
        YANG4_ADDRESS: Decimal("3_678"),
    },
}

TROVES = (TROVE_1, TROVE_2, TROVE_3)
TROVE_OWNERS = (TROVE1_OWNER, TROVE2_OWNER, TROVE3_OWNER)
YANG_ADDRESSES = (YANG1_ADDRESS, YANG2_ADDRESS, YANG3_ADDRESS, YANG4_ADDRESS)

YANG_ADDR_COMBINATIONS = []
for i in range(1, len(YANG_ADDRESSES) + 1):
    j = [list(c) for c in combinations(YANG_ADDRESSES, i)]
    YANG_ADDR_COMBINATIONS.extend(j)

FIRST_REDISTRIBUTION_ID = 1
SECOND_REDISTRIBUTION_ID = 2

DUST_THRESHOLD = Decimal("1E-9")


#
# Fixtures
#


@pytest.fixture
async def shrine(shrine_with_feeds) -> StarknetContract:
    shrine, _ = shrine_with_feeds

    # Set debt ceiling
    await shrine.set_ceiling(to_wad(Decimal("1_000_000"))).execute(caller_address=SHRINE_OWNER)
    await shrine.grant_role(ShrineRoles.REDISTRIBUTE, MOCK_PURGER).execute(caller_address=SHRINE_OWNER)

    return shrine


@pytest.fixture
async def redistribution_setup(request) -> list[int]:
    """
    Wrapper fixture to set up the troves by depositing yang then forging debt,
    based on the list of yang addresses provided as arguments.

    Returns the list of yang addresses passed as arguments to this fixture via indirect
    parametrization.
    """
    yang_addresses = request.param
    shrine = request.getfixturevalue("shrine")

    # Set up troves
    for trove, trove_owner in zip(TROVES, TROVE_OWNERS):
        for yang_addr in yang_addresses:
            deposit_amt = to_wad(DEPOSITS[trove][yang_addr])
            await shrine.deposit(yang_addr, trove, deposit_amt).execute(caller_address=SHRINE_OWNER)

        max_forge_amt = (await shrine.get_max_forge(trove).execute()).result.max
        forge_amt = max_forge_amt // 2
        await shrine.forge(trove_owner, trove, forge_amt).execute(caller_address=SHRINE_OWNER)

    return request.param


#
# Tests
#


@pytest.mark.asyncio
async def test_redistribution_setup(shrine):
    assert (await shrine.get_redistributions_count().execute()).result.count == 0
    for trove in TROVES:
        assert (await shrine.get_trove_redistribution_id(trove).execute()).result.redistribution_id == 0


@pytest.mark.parametrize("redistribution_setup", YANG_ADDR_COMBINATIONS, indirect=["redistribution_setup"])
@pytest.mark.asyncio
async def test_shrine_one_redistribution(shrine, redistribution_setup):
    yang_addresses = redistribution_setup
    num_yangs = len(yang_addresses)

    before_yang_vals = []
    for yang_addr in yang_addresses:
        before_yang_bal = (await shrine.get_deposit(yang_addr, TROVE_1).execute()).result.balance
        assert before_yang_bal > 0

        yang_price = from_wad((await shrine.get_current_yang_price(yang_addr).execute()).result.price)
        before_yang_val = DEPOSITS[TROVE_1][yang_addr] * yang_price
        before_yang_vals.append(before_yang_val)

    before_trove_val = sum(before_yang_vals)

    estimated_trove1_debt = (await shrine.get_trove_info(TROVE_1).execute()).result.debt
    estimated_trove2_debt = (await shrine.get_trove_info(TROVE_2).execute()).result.debt

    # Simulate purge with 0 yin
    await shrine.melt(TROVE1_OWNER, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)
    redistribute_trove1 = await shrine.redistribute(TROVE_1).execute(caller_address=MOCK_PURGER)
    assert_event_emitted(
        redistribute_trove1,
        shrine.contract_address,
        "TroveRedistributed",
        # Assert property that redistributed debt is equal to estimated trove's debt before redistribution
        [FIRST_REDISTRIBUTION_ID, TROVE_1, estimated_trove1_debt],
    )
    # Storage keys updated:
    # - shrine_troves
    # - shrine_deposits * num_yangs
    # - shrine_yangs * num_yangs
    # - shrine_redistribution_count
    # - shrine_yang_redistribution (debt_per_yang + error) * num_yangs
    print(
        f"\nRedistribute ({num_yangs} yang, 1 trove) - redistribute: \n"
        f"{estimate_gas(redistribute_trove1, 2 + 3 * num_yangs, 1)}"
    )

    assert (await shrine.get_redistributions_count().execute()).result.count == FIRST_REDISTRIBUTION_ID

    expected_trove2_debt = from_wad(estimated_trove2_debt)
    for yang_addr, before_yang_val in zip(yang_addresses, before_yang_vals):
        after_yang_bal = (await shrine.get_deposit(yang_addr, TROVE_1).execute()).result.balance
        assert after_yang_bal == 0

        expected_yang_debt = (before_yang_val / before_trove_val) * from_wad(estimated_trove1_debt)
        expected_remaining_yang = DEPOSITS[TROVE_2][yang_addr] + DEPOSITS[TROVE_3][yang_addr]
        expected_unit_debt_for_yang = expected_yang_debt / expected_remaining_yang

        unit_debt_for_yang = from_wad(
            (
                await shrine.get_redistributed_unit_debt_for_yang(yang_addr, FIRST_REDISTRIBUTION_ID).execute()
            ).result.unit_debt
        )
        assert_equalish(unit_debt_for_yang, expected_unit_debt_for_yang)

        expected_trove2_debt += DEPOSITS[TROVE_2][yang_addr] * expected_unit_debt_for_yang

    # Check trove 2 debt
    trove2_debt = from_wad((await shrine.get_trove_info(TROVE_2).execute()).result.debt)
    assert_equalish(trove2_debt, expected_trove2_debt)

    assert (await shrine.get_trove_redistribution_id(TROVE_2).execute()).result.redistribution_id == 0
    # Check cost of update
    update_trove2 = await shrine.melt(TROVE2_OWNER, TROVE_2, 0).execute(caller_address=SHRINE_OWNER)

    assert (
        await shrine.get_trove_redistribution_id(TROVE_2).execute()
    ).result.redistribution_id == FIRST_REDISTRIBUTION_ID

    # Storage keys updated
    # - shrine_total_debt (via `estimate`)
    # - shrine_troves (via `estimate`)
    # - shrine_trove_redistribution
    print(f"\nRedistribute ({num_yangs} yang, 1 trove) - pull: \n{estimate_gas(update_trove2, 3, 1)}")


@pytest.mark.parametrize("redistribution_setup", YANG_ADDR_COMBINATIONS, indirect=["redistribution_setup"])
@pytest.mark.asyncio
async def test_shrine_two_redistributions(shrine, redistribution_setup):
    yang_addresses = redistribution_setup
    num_yangs = len(yang_addresses)

    # Skip to tests for 2nd redistribution
    # Simulate purge with 0 yin
    await shrine.melt(TROVE1_OWNER, TROVE_1, 0).execute(caller_address=SHRINE_OWNER)
    await shrine.redistribute(TROVE_1).execute(caller_address=MOCK_PURGER)

    updated_estimated_trove2_debt = (await shrine.get_trove_info(TROVE_2).execute()).result.debt

    updated_trove2_yang_vals = []
    for yang_addr in yang_addresses:
        updated_trove2_yang_bal = from_wad((await shrine.get_deposit(yang_addr, TROVE_2).execute()).result.balance)
        yang_price = from_wad((await shrine.get_current_yang_price(yang_addr).execute()).result.price)
        updated_trove2_yang_val = updated_trove2_yang_bal * yang_price

        updated_trove2_yang_vals.append(updated_trove2_yang_val)

    updated_trove2_val = sum(updated_trove2_yang_vals)

    estimated_trove3_debt = from_wad((await shrine.get_trove_info(TROVE_3).execute()).result.debt)

    await shrine.melt(TROVE2_OWNER, TROVE_2, 0).execute(caller_address=SHRINE_OWNER)
    redistribute_trove2 = await shrine.redistribute(TROVE_2).execute(caller_address=MOCK_PURGER)

    assert (await shrine.get_redistributions_count().execute()).result.count == SECOND_REDISTRIBUTION_ID

    assert_event_emitted(
        redistribute_trove2,
        shrine.contract_address,
        "TroveRedistributed",
        # Assert property that redistributed debt is equal to estimated trove's debt before redistribution
        [SECOND_REDISTRIBUTION_ID, TROVE_2, updated_estimated_trove2_debt],
    )

    expected_trove3_debt = estimated_trove3_debt
    for yang_addr, yang_val in zip(yang_addresses, updated_trove2_yang_vals):
        assert (await shrine.get_deposit(yang_addr, TROVE_2).execute()).result.balance == 0

        # Check distribution for yang 1 from trove 2
        expected_trove2_yang_debt = (yang_val / updated_trove2_val) * from_wad(updated_estimated_trove2_debt)
        unit_debt_for_yang = from_wad(
            (
                await shrine.get_redistributed_unit_debt_for_yang(yang_addr, SECOND_REDISTRIBUTION_ID).execute()
            ).result.unit_debt
        )
        expected_remaining_yang = DEPOSITS[TROVE_3][yang_addr]
        expected_unit_debt_for_yang = expected_trove2_yang_debt / expected_remaining_yang
        assert_equalish(unit_debt_for_yang, expected_unit_debt_for_yang)

        expected_trove3_debt += DEPOSITS[TROVE_3][yang_addr] * expected_unit_debt_for_yang

    trove3_debt = from_wad((await shrine.get_trove_info(TROVE_3).execute()).result.debt)
    assert_equalish(trove3_debt, expected_trove3_debt)

    assert (await shrine.get_trove_redistribution_id(TROVE_3).execute()).result.redistribution_id == 0
    # Check cost of update
    update_trove3 = await shrine.melt(TROVE3_OWNER, TROVE_3, 0).execute(caller_address=SHRINE_OWNER)

    assert (
        await shrine.get_trove_redistribution_id(TROVE_3).execute()
    ).result.redistribution_id == SECOND_REDISTRIBUTION_ID

    # Storage keys updated
    # - shrine_total_debt (via `estimate`)
    # - shrine_troves (via `estimate`)
    # - shrine_trove_redistribution
    print(f"\nRedistribute ({num_yangs} yangs, 2 troves) - pull: \n{estimate_gas(update_trove3, 3, 1)}")


@pytest.mark.asyncio
async def test_last_error(shrine):
    """
    This test asserts that the last error for a yang's redistribution is correctly retrieved even if there
    were intervening redistributions that did not involve a yang.

    For example, yang X is involved in redistribution ID 1 with a non-zero error, was not involved in
    redistribution IDs 2 to 4, and is next involved in redistribution ID 5. When retrieving the last error
    for yang X, the error should be that at redistribution ID 1.
    """
    # Set up troves
    for trove, trove_owner in zip(TROVES, TROVE_OWNERS):
        for yang_addr in YANG_ADDRESSES:

            # Skip YANG_1 for trove 2
            if yang_addr == YANG1_ADDRESS and trove == TROVE_2:
                continue

            deposit_amt = to_wad(DEPOSITS[trove][yang_addr])
            await shrine.deposit(yang_addr, trove, deposit_amt).execute(caller_address=SHRINE_OWNER)

        max_forge_amt = (await shrine.get_max_forge(trove).execute()).result.max
        forge_amt = max_forge_amt // 2
        await shrine.forge(trove_owner, trove, forge_amt).execute(caller_address=SHRINE_OWNER)

    redistribution_id = (await shrine.get_redistributions_count().execute()).result.count

    # Redistribute trove 1
    await shrine.redistribute(TROVE_1).execute(caller_address=MOCK_PURGER)

    # Check redistribution ID and error
    first_redistribution_id = (await shrine.get_redistributions_count().execute()).result.count
    assert first_redistribution_id == redistribution_id + 1

    yang1_id = 1
    yang1_redistribution1 = (
        await shrine.get_yang_redistribution(yang1_id, first_redistribution_id).execute()
    ).result.yang_redistribution
    yang1_redistribution1_last_error = (
        await shrine.get_recent_redistribution_error_for_yang(yang1_id, first_redistribution_id).execute()
    ).result.error

    assert yang1_redistribution1_last_error == yang1_redistribution1.error

    # Redistribute trove 2
    await shrine.redistribute(TROVE_2).execute(caller_address=MOCK_PURGER)

    # Check redistribution ID and error
    second_redistribution_id = (await shrine.get_redistributions_count().execute()).result.count
    assert second_redistribution_id == first_redistribution_id + 1

    yang1_redistribution2 = (
        await shrine.get_yang_redistribution(yang1_id, second_redistribution_id).execute()
    ).result.yang_redistribution
    yang1_redistribution2_last_error = (
        await shrine.get_recent_redistribution_error_for_yang(yang1_id, second_redistribution_id).execute()
    ).result.error

    assert yang1_redistribution2.error == 0
    assert yang1_redistribution2_last_error == yang1_redistribution1.error


@pytest.mark.asyncio
async def test_shrine_redistribute_with_dust_yang(shrine):
    yang_addresses = (YANG1_ADDRESS, YANG2_ADDRESS)

    # Set up the troves
    # Trove 1 is funded disproportionately by YANG2, since `redistribute_internal` iterates from
    # the last yang ID to the first.
    trove1_yang1_deposit_amt = to_wad(Decimal("1E-15"))
    trove1_yang2_deposit_amt = to_wad(1_000)

    for trove, trove_owner in zip(TROVES, TROVE_OWNERS):
        for yang_addr in yang_addresses:
            if trove == TROVE_1 and yang_addr == YANG1_ADDRESS:
                deposit_amt = trove1_yang1_deposit_amt
            elif trove == TROVE_1 and yang_addr == YANG2_ADDRESS:
                deposit_amt = trove1_yang2_deposit_amt
            else:
                deposit_amt = to_wad(DEPOSITS[trove][yang_addr])
            await shrine.deposit(yang_addr, trove, deposit_amt).execute(caller_address=SHRINE_OWNER)

        max_forge_amt = (await shrine.get_max_forge(trove).execute()).result.max
        forge_amt = max_forge_amt // 2
        await shrine.forge(trove_owner, trove, forge_amt).execute(caller_address=SHRINE_OWNER)

    before_yang_vals = []
    for yang_addr, amt in zip(yang_addresses, (trove1_yang1_deposit_amt, trove1_yang2_deposit_amt)):
        before_yang_bal = (await shrine.get_deposit(yang_addr, TROVE_1).execute()).result.balance
        assert before_yang_bal > 0

        yang_price = from_wad((await shrine.get_current_yang_price(yang_addr).execute()).result.price)
        before_yang_val = amt * yang_price
        before_yang_vals.append(before_yang_val)

    before_trove_val = sum(before_yang_vals)

    estimated_trove1_debt = (await shrine.get_trove_info(TROVE_1).execute()).result.debt
    estimated_trove2_debt = (await shrine.get_trove_info(TROVE_2).execute()).result.debt

    # sanity check that amount of debt attributed to YANG_1 falls below dust threshold,
    # and will therefore be attributed to YANG_2, the preceding yang in `redistribute_internal`
    assert (before_yang_vals[0] / before_trove_val) * from_wad(estimated_trove1_debt) < DUST_THRESHOLD

    redistribute_trove1 = await shrine.redistribute(TROVE_1).execute(caller_address=MOCK_PURGER)

    assert_event_emitted(
        redistribute_trove1,
        shrine.contract_address,
        "TroveRedistributed",
        # Assert property that redistributed debt is equal to estimated trove's debt before redistribution
        [FIRST_REDISTRIBUTION_ID, TROVE_1, estimated_trove1_debt],
    )

    # Check entire's trove 1's debt is distributed to YANG_2
    after_trove1_yang2_bal = (await shrine.get_deposit(YANG2_ADDRESS, TROVE_1).execute()).result.balance
    assert after_trove1_yang2_bal == 0

    expected_remaining_yang2 = DEPOSITS[TROVE_2][YANG2_ADDRESS] + DEPOSITS[TROVE_3][yang_addr]
    expected_unit_debt_for_yang2 = from_wad(estimated_trove1_debt) / expected_remaining_yang2

    unit_debt_for_yang2 = from_wad(
        (
            await shrine.get_redistributed_unit_debt_for_yang(YANG2_ADDRESS, FIRST_REDISTRIBUTION_ID).execute()
        ).result.unit_debt
    )
    assert_equalish(unit_debt_for_yang2, expected_unit_debt_for_yang2)
    expected_trove2_debt = (
        from_wad(estimated_trove2_debt) + expected_unit_debt_for_yang2 * DEPOSITS[TROVE_2][YANG2_ADDRESS]
    )

    # Check YANG 1 debt and yang is not updated
    after_trove1_yang1_bal = (await shrine.get_deposit(YANG1_ADDRESS, TROVE_1).execute()).result.balance
    assert after_trove1_yang1_bal == trove1_yang1_deposit_amt

    unit_debt_for_yang1 = (
        await shrine.get_redistributed_unit_debt_for_yang(YANG1_ADDRESS, FIRST_REDISTRIBUTION_ID).execute()
    ).result.unit_debt
    assert unit_debt_for_yang1 == 0

    # Check trove 2 debt
    trove2_debt = from_wad((await shrine.get_trove_info(TROVE_2).execute()).result.debt)
    assert_equalish(trove2_debt, expected_trove2_debt)