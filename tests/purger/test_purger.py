from decimal import ROUND_DOWN, Decimal
from typing import List

import pytest
from flaky import flaky
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

from tests.purger.constants import *  # noqa: F403
from tests.roles import GateRoles, ShrineRoles
from tests.shrine.constants import FEED_LEN, MAX_PRICE_CHANGE, MULTIPLIER_FEED
from tests.utils import (
    AURA_USER_1,
    FALSE,
    GATE_OWNER,
    RAY_SCALE,
    SENTINEL_OWNER,
    SHRINE_OWNER,
    STETH_OWNER,
    TIME_INTERVAL,
    TROVE_1,
    TRUE,
    WAD_RAY_OOB_VALUES,
    YangConfig,
    assert_equalish,
    assert_event_emitted,
    calculate_max_forge,
    compile_code,
    create_feed,
    from_ray,
    from_uint,
    from_wad,
    get_contract_code_with_replacement,
    max_approve,
    price_bounds,
    set_block_timestamp,
    to_ray,
    to_wad,
)

#
# Helpers
#

PURGE_FUNCTIONS = ("purge", "restricted_purge")


async def advance_yang_prices_by_percentage(
    starknet: Starknet,
    shrine: StarknetContract,
    yangs: List[YangConfig],
    price_change: Decimal,
):
    """
    Helper function to set the prices for a list of yangs for the next interval,
    based on a change from the price at the current interval.
    """
    current_timestamp = starknet.state.state.block_info.block_timestamp
    next_timestamp = current_timestamp + TIME_INTERVAL
    set_block_timestamp(starknet, next_timestamp)

    for yang in yangs:
        yang_address = yang.contract_address

        # Get current price
        current_price = (await shrine.get_current_yang_price(yang_address).execute()).result.price

        # Update price
        new_price = int((Decimal("1") + price_change) * current_price)

        await shrine.advance(yang_address, new_price).execute(caller_address=SHRINE_OWNER)


def get_close_factor(ltv: Decimal) -> Decimal:
    """
    Helper function to calculate the close factor based on the LTV in Decimal.
    """
    factor_one = Decimal("2.7") * ltv ** Decimal("2")
    factor_two = Decimal("2") * ltv
    close_factor = factor_one - factor_two + Decimal("0.22")
    return close_factor


def get_max_close_amount(debt: Decimal, ltv: Decimal) -> Decimal:
    """
    Returns the maximum close amount for a debt given the LTV.
    """
    close_factor = get_close_factor(ltv)
    maximum_close_amt = close_factor * debt

    if debt < maximum_close_amt:
        return debt

    return maximum_close_amt


def get_penalty_fn(threshold: Decimal) -> tuple[Decimal, Decimal]:
    """
    Returns `m` and `b` for y = mx + b
    """
    m = (MAX_PENALTY - MIN_PENALTY) / (MAX_PENALTY_LTV - threshold)
    b = MIN_PENALTY - (threshold * m)
    return (m, b)


def get_penalty(threshold: Decimal, ltv: Decimal, trove_value: Decimal, trove_debt: Decimal) -> Decimal:
    """
    Returns the penalty given the LTV.
    """
    if ltv <= MAX_PENALTY_LTV:
        m, b = get_penalty_fn(threshold)
        return m * ltv + b
    elif MAX_PENALTY_LTV < ltv <= Decimal("1"):
        return (trove_value - trove_debt) / trove_debt

    return 0


def get_freed_percentage(
    threshold: Decimal, ltv: Decimal, trove_value: Decimal, trove_debt: Decimal, close_amt: Decimal
) -> Decimal:
    """
    If LTV <= 100%, return the freed percentage based on (close amount + penalty amount) / total value of trove
    If LTV > 100%, return the freed percentage based on close amount / total debt of trove.
    """
    if ltv > Decimal("1"):
        return close_amt / trove_debt

    penalty = get_penalty(threshold, ltv, trove_value, trove_debt)
    freed_amt = (Decimal("1") + penalty) * close_amt
    return freed_amt / trove_value


#
# Fixtures
#


@pytest.fixture
async def shrine(shrine_deploy) -> StarknetContract:
    # Update debt ceiling
    shrine = shrine_deploy
    await shrine.set_ceiling(DEBT_CEILING_WAD).execute(caller_address=SHRINE_OWNER)
    return shrine


@pytest.fixture
async def shrine_feeds(
    starknet, sentinel_with_yangs, shrine, steth_yang: YangConfig, doge_yang: YangConfig
) -> List[List[int]]:
    # Creating the price feeds
    yangs = (steth_yang, doge_yang)
    feeds = [create_feed(from_wad(yang.price_wad), FEED_LEN, MAX_PRICE_CHANGE) for yang in yangs]

    # Putting the price feeds in the `shrine_yang_price_storage` storage variable
    # Skipping over the first element in `feeds` since the start price is set in `add_yang`
    for i in range(1, FEED_LEN):
        timestamp = i * TIME_INTERVAL
        set_block_timestamp(starknet, timestamp)

        for j in range(len(yangs)):
            await shrine.advance(yangs[j].contract_address, feeds[j][i]).execute(caller_address=SHRINE_OWNER)

        await shrine.set_multiplier(MULTIPLIER_FEED[i]).execute(caller_address=SHRINE_OWNER)

    return feeds


@pytest.fixture
async def aura_user_1_with_trove_id_1(
    shrine,
    shrine_feeds,
    abbot,
    sentinel_with_yangs,
    steth_yang: YangConfig,
    doge_yang: YangConfig,
) -> int:
    # Get stETH price
    steth_price = (await shrine.get_current_yang_price(steth_yang.contract_address).execute()).result.price

    # Get Doge price
    doge_price = (await shrine.get_current_yang_price(doge_yang.contract_address).execute()).result.price

    # Get maximum forge amount
    prices = [steth_price, doge_price]
    amounts = [USER_STETH_DEPOSIT_WAD, USER_DOGE_DEPOSIT_WAD]
    thresholds = [steth_yang.threshold, doge_yang.threshold]
    max_forge_amt = calculate_max_forge(prices, amounts, thresholds)

    forge_amt = to_wad(max_forge_amt - 1)

    await abbot.open_trove(
        forge_amt,
        [steth_yang.contract_address, doge_yang.contract_address],
        [USER_STETH_DEPOSIT_WAD, USER_DOGE_DEPOSIT_WAD],
    ).execute(caller_address=AURA_USER_1)

    return forge_amt


@pytest.fixture
async def funded_searcher(shrine, shrine_feeds, abbot, sentinel_with_yangs, steth_token, steth_yang: YangConfig):
    # fund the user with bags
    await steth_token.transfer(SEARCHER, (SEARCHER_STETH_WAD, 0)).execute(caller_address=STETH_OWNER)

    # user approves Aura gates to spend bags
    await max_approve(steth_token, SEARCHER, steth_yang.gate_address)

    await abbot.open_trove(SEARCHER_FORGE_AMT_WAD, [steth_yang.contract_address], [SEARCHER_STETH_WAD]).execute(
        caller_address=SEARCHER
    )


@pytest.fixture
async def funded_absorber(shrine, shrine_feeds, abbot, sentinel_with_yangs, steth_token, steth_yang: YangConfig):
    # fund the user with bags
    await steth_token.transfer(MOCK_ABSORBER, (MOCK_ABSORBER_STETH_WAD, 0)).execute(caller_address=STETH_OWNER)

    # user approves the Aura gates to spend bags
    await max_approve(steth_token, MOCK_ABSORBER, steth_yang.gate_address)

    await abbot.open_trove(
        MOCK_ABSORBER_FORGE_AMT_WAD, [steth_yang.contract_address], [MOCK_ABSORBER_STETH_WAD]
    ).execute(caller_address=MOCK_ABSORBER)


@pytest.fixture
async def purger(starknet, shrine, sentinel, steth_gate, doge_gate) -> StarknetContract:
    purger_code = get_contract_code_with_replacement(
        "contracts/purger/purger.cairo",
        {"func get_penalty_internal": "@view\nfunc get_penalty_internal"},
    )
    purger_contract = compile_code(purger_code)
    purger = await starknet.deploy(
        contract_class=purger_contract,
        constructor_calldata=[
            shrine.contract_address,
            sentinel.contract_address,
            MOCK_ABSORBER,
        ],
    )

    # Approve purger to call `seize` in Shrine
    purger_roles = ShrineRoles.MELT + ShrineRoles.SEIZE
    await shrine.grant_role(purger_roles, purger.contract_address).execute(caller_address=SHRINE_OWNER)

    # Approve purger to call `exit` in Gate
    await steth_gate.grant_role(GateRoles.EXIT, purger.contract_address).execute(caller_address=GATE_OWNER)
    await doge_gate.grant_role(GateRoles.EXIT, purger.contract_address).execute(caller_address=GATE_OWNER)

    return purger


#
# Tests - Setup
#


@pytest.mark.usefixtures("sentinel_with_yangs")
@pytest.mark.asyncio
async def test_sentinel_setup(sentinel, steth_yang: YangConfig, doge_yang: YangConfig):
    assert (await sentinel.get_admin().execute()).result.admin == SENTINEL_OWNER
    yang_addrs = (await sentinel.get_yang_addresses().execute()).result.addresses
    assert len(yang_addrs) == 2
    assert steth_yang.contract_address in yang_addrs
    assert doge_yang.contract_address in yang_addrs


@pytest.mark.usefixtures("sentinel_with_yangs")
@pytest.mark.asyncio
async def test_shrine_setup(shrine, shrine_feeds, steth_yang: YangConfig, doge_yang: YangConfig):
    # Check price feeds
    yangs = (steth_yang, doge_yang)
    for i in range(len(yangs)):
        yang_address = yangs[i].contract_address

        start_price, start_cumulative_price = (await shrine.get_yang_price(yang_address, 0).execute()).result
        assert start_price == yangs[i].price_wad
        assert start_cumulative_price == yangs[i].price_wad

        end_price, end_cumulative_price = (await shrine.get_yang_price(yang_address, FEED_LEN - 1).execute()).result
        lo, hi = price_bounds(start_price, FEED_LEN, MAX_PRICE_CHANGE)
        assert lo <= end_price <= hi
        assert end_cumulative_price == sum(shrine_feeds[i])

    # Check multiplier feed
    start_multiplier, start_cumulative_multiplier = (await shrine.get_multiplier(0).execute()).result
    assert start_multiplier == RAY_SCALE
    assert start_cumulative_multiplier == RAY_SCALE

    end_multiplier, end_cumulative_multiplier = (await shrine.get_multiplier(FEED_LEN - 1).execute()).result
    assert end_multiplier != 0
    assert end_cumulative_multiplier == RAY_SCALE * (FEED_LEN)


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_aura_user_1")
@pytest.mark.asyncio
async def test_aura_user_setup(shrine, purger, aura_user_1_with_trove_id_1):
    forge_amt = aura_user_1_with_trove_id_1
    trove_debt = (await shrine.get_trove_info(TROVE_1).execute()).result.debt
    assert trove_debt == forge_amt


#
# Tests - Purger
#


@pytest.mark.parametrize(
    "threshold, ltv, expected",
    [
        (Decimal("0.5"), Decimal("0.5"), MIN_PENALTY),
        (Decimal("0.5"), Decimal("0.8888"), MAX_PENALTY),
        (Decimal("0.5"), Decimal("0.95"), Decimal("0.05") / Decimal("0.95")),
        (Decimal("0.5"), Decimal("1"), Decimal("0")),
        (Decimal("0.5"), Decimal("1.1"), Decimal("0")),
        (Decimal("0.8"), Decimal("0.8"), MIN_PENALTY),
        (Decimal("0.8"), Decimal("0.8888"), MAX_PENALTY),
        (Decimal("0.7654321"), Decimal("0.7654321"), MIN_PENALTY),
        (Decimal("0.7654321"), Decimal("0.8888"), MAX_PENALTY),
    ],
)
@pytest.mark.asyncio
async def test_penalty_parametrized(purger, threshold, ltv, expected):
    value = Decimal("1_000")
    debt = ltv * value

    penalty = from_ray(
        (
            await purger.get_penalty_internal(to_ray(threshold), to_ray(ltv), to_wad(value), to_wad(debt)).execute()
        ).result.penalty
    )
    assert_equalish(penalty, expected)


# HealthCheck is suppressed as a view function is being tested
@settings(max_examples=50, deadline=None, suppress_health_check=[HealthCheck.function_scoped_fixture])
@given(
    threshold=st.decimals(min_value=Decimal("0.5"), max_value=Decimal("0.9"), places=27),
    ltv_offset=st.decimals(min_value=Decimal("0"), max_value=Decimal("1"), places=27),
)
@pytest.mark.asyncio
async def test_penalty_fuzzing(purger, threshold, ltv_offset):
    ltv = threshold + (Decimal("1") - threshold) * ltv_offset
    trove_value = Decimal("1_000")
    trove_debt = ltv * trove_value

    expected_penalty = get_penalty(threshold, ltv, trove_value, trove_debt)
    penalty = from_ray(
        (
            await purger.get_penalty_internal(
                to_ray(threshold), to_ray(ltv), to_wad(trove_value), to_wad(trove_debt)
            ).execute()
        ).result.penalty
    )
    assert_equalish(penalty, expected_penalty)


@flaky
@pytest.mark.parametrize("price_change", [Decimal("-0.1"), Decimal("-0.2"), Decimal("-0.5"), Decimal("-0.9")])
@pytest.mark.parametrize(
    "max_close_percentage", [Decimal("0.001"), Decimal("0.01"), Decimal("0.1"), Decimal("1"), Decimal("1.01")]
)
@pytest.mark.usefixtures(
    "sentinel_with_yangs",
    "funded_aura_user_1",
    "aura_user_1_with_trove_id_1",
    "funded_searcher",
)
@pytest.mark.asyncio
async def test_liquidate_pass(
    starknet,
    shrine,
    purger,
    yin,
    steth_token,
    doge_token,
    steth_gate,
    doge_gate,
    steth_yang: YangConfig,
    doge_yang: YangConfig,
    price_change,
    max_close_percentage,
):
    yangs = [steth_yang, doge_yang]
    await advance_yang_prices_by_percentage(starknet, shrine, yangs, price_change)

    # Assert trove is not healthy
    is_healthy = (await shrine.is_healthy(TROVE_1).execute()).result.healthy
    assert is_healthy == FALSE

    # Get LTV
    before_trove_info = (await shrine.get_trove_info(TROVE_1).execute()).result
    before_trove_value = from_wad(before_trove_info.value)
    before_trove_threshold = from_ray(before_trove_info.threshold)
    before_trove_debt = from_wad(before_trove_info.debt)
    before_trove_ltv = from_ray(before_trove_info.ltv)

    # Check purge penalty
    penalty = from_ray((await purger.get_penalty(TROVE_1).execute()).result.penalty)
    if before_trove_ltv > Decimal("1"):
        expected_penalty = get_penalty(before_trove_threshold, before_trove_ltv, before_trove_value, before_trove_debt)
        assert_equalish(penalty, expected_penalty)

    # Check maximum close amount
    expected_maximum_close_amt = get_max_close_amount(before_trove_debt, before_trove_ltv)
    maximum_close_amt_wad = (await purger.get_max_close_amount(TROVE_1).execute()).result.amount
    assert_equalish(from_wad(maximum_close_amt_wad), expected_maximum_close_amt)

    # Calculate close amount based on parametrization
    close_amt_wad = input_close_amt_wad = int(max_close_percentage * maximum_close_amt_wad)
    if input_close_amt_wad > maximum_close_amt_wad:
        close_amt_wad = maximum_close_amt_wad

    close_amt = from_wad(close_amt_wad)

    # Sanity check: searcher has sufficient yin
    searcher_yin_balance = (await yin.balanceOf(SEARCHER).execute()).result.balance
    assert from_uint(searcher_yin_balance) > close_amt_wad

    # Get yang balance of searcher
    before_searcher_steth_bal = from_wad(from_uint((await steth_token.balanceOf(SEARCHER).execute()).result.balance))
    before_searcher_doge_bal = from_wad(from_uint((await doge_token.balanceOf(SEARCHER).execute()).result.balance))

    # Get freed percentage
    freed_percentage = get_freed_percentage(
        before_trove_threshold, before_trove_ltv, before_trove_value, before_trove_debt, close_amt
    )

    # Get yang balance of trove
    before_trove_steth_yang_wad = (
        await shrine.get_deposit(steth_token.contract_address, TROVE_1).execute()
    ).result.balance
    before_trove_steth_bal_wad = (await steth_gate.preview_exit(before_trove_steth_yang_wad).execute()).result.preview
    expected_freed_steth_yang = freed_percentage * from_wad(before_trove_steth_yang_wad)
    expected_freed_steth = freed_percentage * from_wad(before_trove_steth_bal_wad)

    before_trove_doge_yang_wad = (
        await shrine.get_deposit(doge_token.contract_address, TROVE_1).execute()
    ).result.balance
    before_trove_doge_bal_wad = (await doge_gate.preview_exit(before_trove_doge_yang_wad).execute()).result.preview
    expected_freed_doge_yang = freed_percentage * from_wad(before_trove_doge_yang_wad)
    expected_freed_doge = freed_percentage * from_wad(before_trove_doge_bal_wad)

    # Sanity check that expected trove LTV does not increase
    expected_after_trove_debt = before_trove_debt - close_amt
    expected_after_trove_value = before_trove_value * (1 - freed_percentage)

    if max_close_percentage >= Decimal("1"):
        # Catch zero division error
        expected_after_trove_ltv = Decimal("0")
    else:
        # Truncate to 27 decimals to match precision of `ray`
        expected_after_trove_ltv = (expected_after_trove_debt / expected_after_trove_value).quantize(
            Decimal("1E-27"), rounding=ROUND_DOWN
        )

    assert expected_after_trove_ltv <= before_trove_ltv

    # Call liquidate
    liquidate = await purger.liquidate(TROVE_1, input_close_amt_wad, SEARCHER).execute(caller_address=SEARCHER)

    # Check return data
    assert liquidate.result.yangs == [steth_yang.contract_address, doge_yang.contract_address]
    freed_steth = liquidate.result.freed_assets_amt[0]
    freed_doge = liquidate.result.freed_assets_amt[1]
    assert_equalish(from_wad(freed_steth), expected_freed_steth)
    assert_equalish(from_wad(freed_doge), expected_freed_doge)

    # Check event
    assert_event_emitted(
        liquidate,
        purger.contract_address,
        "Purged",
        lambda d: d[:4] == [TROVE_1, close_amt_wad, SEARCHER, SEARCHER]
        and d[5:]
        == [len(yangs), steth_yang.contract_address, doge_yang.contract_address, len(yangs), freed_steth, freed_doge],
    )

    # Check that LTV has improved (before LTV < 100%) or stayed the same (before LTV >= 100%)
    after_trove_info = (await shrine.get_trove_info(TROVE_1).execute()).result
    after_trove_ltv = from_ray(after_trove_info.ltv)
    after_trove_debt = from_wad(after_trove_info.debt)
    after_trove_value = from_wad(after_trove_info.value)

    assert after_trove_ltv <= before_trove_ltv
    assert_equalish(after_trove_value, expected_after_trove_value)
    assert_equalish(after_trove_debt, expected_after_trove_debt)

    # Check collateral tokens balance of searcher
    after_searcher_steth_bal = from_wad(from_uint((await steth_token.balanceOf(SEARCHER).execute()).result.balance))
    assert_equalish(after_searcher_steth_bal, before_searcher_steth_bal + expected_freed_steth)

    after_searcher_doge_bal = from_wad(from_uint((await doge_token.balanceOf(SEARCHER).execute()).result.balance))
    assert_equalish(after_searcher_doge_bal, before_searcher_doge_bal + expected_freed_doge)

    # Get yang balance of trove
    after_trove_steth_yang = from_wad(
        (await shrine.get_deposit(steth_token.contract_address, TROVE_1).execute()).result.balance
    )
    assert_equalish(after_trove_steth_yang, from_wad(before_trove_steth_yang_wad) - expected_freed_steth_yang)

    after_trove_doge_yang = from_wad(
        (await shrine.get_deposit(doge_token.contract_address, TROVE_1).execute()).result.balance
    )
    assert_equalish(after_trove_doge_yang, from_wad(before_trove_doge_yang_wad) - expected_freed_doge_yang)


@pytest.mark.parametrize("fn", ["liquidate", "absorb"])
@pytest.mark.usefixtures(
    "sentinel_with_yangs",
    "funded_aura_user_1",
    "aura_user_1_with_trove_id_1",
    "funded_searcher",
)
@pytest.mark.asyncio
async def test_liquidate_purge_fail_trove_healthy(shrine, purger, fn):
    """
    Failing tests for `absorb` and `liquidate` when LTV < threshold
    """
    # Check close amount is 0
    max_close_amt = (await purger.get_max_close_amount(TROVE_1).execute()).result.amount
    assert max_close_amt == 0

    # Check purge penalty is 0
    penalty = (await purger.get_penalty(TROVE_1).execute()).result.penalty
    assert penalty == 0

    # Check trove is healthy
    is_healthy = (await shrine.is_healthy(TROVE_1).execute()).result.healthy
    assert is_healthy == TRUE

    # Get trove debt
    purge_amt = (await shrine.get_trove_info(TROVE_1).execute()).result.debt // 2

    with pytest.raises(StarkException, match=f"Purger: Trove {TROVE_1} is not liquidatable"):
        if fn == "liquidate":
            await purger.liquidate(TROVE_1, purge_amt, SEARCHER).execute(caller_address=SEARCHER)
        elif fn == "absorb":
            await purger.absorb(TROVE_1).execute(caller_address=SEARCHER)


@pytest.mark.parametrize("liquidate_amt", WAD_RAY_OOB_VALUES)
@pytest.mark.asyncio
async def test_liquidate_fail_out_of_bounds(purger, liquidate_amt):
    with pytest.raises(StarkException, match=r"Purger: Value of `purge_amt` \(-?\d+\) is out of bounds"):
        await purger.liquidate(TROVE_1, liquidate_amt, SEARCHER).execute(caller_address=SEARCHER)


@pytest.mark.usefixtures(
    "sentinel_with_yangs",
    "funded_aura_user_1",
    "aura_user_1_with_trove_id_1",
)
@pytest.mark.asyncio
async def test_liquidate_fail_insufficient_yin(
    starknet,
    shrine,
    purger,
    steth_yang: YangConfig,
    doge_yang: YangConfig,
):
    # SEARCHER is not funded because `funded_searcher` fixture was omitted
    yangs = [steth_yang, doge_yang]
    price_change = Decimal("-0.1")
    await advance_yang_prices_by_percentage(starknet, shrine, yangs, price_change)

    # Assert max close amount is positive
    max_close_amt = (await purger.get_max_close_amount(TROVE_1).execute()).result.amount
    assert max_close_amt > 0

    with pytest.raises(StarkException):
        await purger.liquidate(TROVE_1, max_close_amt, SEARCHER).execute(caller_address=SEARCHER)


@pytest.mark.parametrize("price_change", [Decimal("-0.2"), Decimal("-0.5"), Decimal("-0.9")])
@pytest.mark.usefixtures(
    "sentinel_with_yangs",
    "funded_aura_user_1",
    "aura_user_1_with_trove_id_1",
    "funded_absorber",
)
@pytest.mark.asyncio
async def test_absorb_pass(
    starknet,
    shrine,
    purger,
    yin,
    steth_token,
    doge_token,
    steth_gate,
    doge_gate,
    steth_yang: YangConfig,
    doge_yang: YangConfig,
    price_change,
):
    yangs = [steth_yang, doge_yang]
    await advance_yang_prices_by_percentage(starknet, shrine, yangs, price_change)

    # Assert trove is not healthy
    is_healthy = (await shrine.is_healthy(TROVE_1).execute()).result.healthy
    assert is_healthy == FALSE

    # Get LTV
    before_trove_info = (await shrine.get_trove_info(TROVE_1).execute()).result
    before_trove_value = from_wad(before_trove_info.value)
    before_trove_threshold = from_ray(before_trove_info.threshold)
    before_trove_debt = from_wad(before_trove_info.debt)
    before_trove_ltv = from_ray(before_trove_info.ltv)

    # Check purge penalty
    penalty = from_ray((await purger.get_penalty(TROVE_1).execute()).result.penalty)
    if before_trove_ltv > Decimal("1"):
        expected_penalty = get_penalty(before_trove_threshold, before_trove_ltv, before_trove_value, before_trove_debt)
        assert_equalish(penalty, expected_penalty)

    # Sanity check: absorber has sufficient yin
    absorber_yin_balance = (await yin.balanceOf(MOCK_ABSORBER).execute()).result.balance
    assert from_uint(absorber_yin_balance) > before_trove_debt

    # Get yang balance of absorber
    before_absorber_steth_bal = from_wad(
        from_uint((await steth_token.balanceOf(MOCK_ABSORBER).execute()).result.balance)
    )
    before_absorber_doge_bal = from_wad(from_uint((await doge_token.balanceOf(MOCK_ABSORBER).execute()).result.balance))

    # Get freed percentage
    freed_percentage = get_freed_percentage(
        before_trove_threshold, before_trove_ltv, before_trove_value, before_trove_debt, before_trove_debt
    )

    # Get yang balance of trove
    before_trove_steth_yang_wad = (
        await shrine.get_deposit(steth_token.contract_address, TROVE_1).execute()
    ).result.balance
    before_trove_steth_bal_wad = (await steth_gate.preview_exit(before_trove_steth_yang_wad).execute()).result.preview
    expected_freed_steth_yang = freed_percentage * from_wad(before_trove_steth_yang_wad)
    expected_freed_steth = freed_percentage * from_wad(before_trove_steth_bal_wad)

    before_trove_doge_yang_wad = (
        await shrine.get_deposit(doge_token.contract_address, TROVE_1).execute()
    ).result.balance
    before_trove_doge_bal_wad = (await doge_gate.preview_exit(before_trove_doge_yang_wad).execute()).result.preview
    expected_freed_doge_yang = freed_percentage * from_wad(before_trove_doge_yang_wad)
    expected_freed_doge = freed_percentage * from_wad(before_trove_doge_bal_wad)

    # Call absorb
    absorb = await purger.absorb(TROVE_1).execute(caller_address=SEARCHER)

    # Check return data
    assert absorb.result.yangs == [steth_yang.contract_address, doge_yang.contract_address]
    freed_steth = absorb.result.freed_assets_amt[0]
    freed_doge = absorb.result.freed_assets_amt[1]
    assert_equalish(from_wad(freed_steth), expected_freed_steth)
    assert_equalish(from_wad(freed_doge), expected_freed_doge)

    # Check event
    assert_event_emitted(
        absorb,
        purger.contract_address,
        "Purged",
        lambda d: d[:4] == [TROVE_1, before_trove_info.debt, MOCK_ABSORBER, MOCK_ABSORBER]
        and d[5:]
        == [len(yangs), steth_yang.contract_address, doge_yang.contract_address, len(yangs), freed_steth, freed_doge],
    )

    # Check that LTV is 0 after all debt is repaid
    after_trove_info = (await shrine.get_trove_info(TROVE_1).execute()).result
    after_trove_ltv = from_ray(after_trove_info.ltv)
    after_trove_debt = from_wad(after_trove_info.debt)

    assert after_trove_ltv == 0

    # Check collateral tokens balance of absorber
    after_absorber_steth_bal = from_wad(
        from_uint((await steth_token.balanceOf(MOCK_ABSORBER).execute()).result.balance)
    )
    assert_equalish(after_absorber_steth_bal, before_absorber_steth_bal + expected_freed_steth)

    after_absorber_doge_bal = from_wad(from_uint((await doge_token.balanceOf(MOCK_ABSORBER).execute()).result.balance))
    assert_equalish(after_absorber_doge_bal, before_absorber_doge_bal + expected_freed_doge)

    # Get yang balance of trove
    after_trove_steth_yang = from_wad(
        (await shrine.get_deposit(steth_token.contract_address, TROVE_1).execute()).result.balance
    )
    assert_equalish(after_trove_steth_yang, from_wad(before_trove_steth_yang_wad) - expected_freed_steth_yang)

    after_trove_doge_yang = from_wad(
        (await shrine.get_deposit(doge_token.contract_address, TROVE_1).execute()).result.balance
    )
    assert_equalish(after_trove_doge_yang, from_wad(before_trove_doge_yang_wad) - expected_freed_doge_yang)

    # Check trove debt
    assert after_trove_debt == 0


@pytest.mark.parametrize("price_change", [Decimal("-0.05"), Decimal("-0.1")])
@pytest.mark.usefixtures(
    "yin",
    "steth_token",
    "doge_token",
    "steth_gate",
    "doge_gate",
    "sentinel_with_yangs",
    "funded_aura_user_1",
    "aura_user_1_with_trove_id_1",
    "funded_absorber",
)
@pytest.mark.asyncio
async def test_absorb_fail_ltv_too_low(
    starknet,
    shrine,
    purger,
    steth_yang: YangConfig,
    doge_yang: YangConfig,
    price_change,
):
    """
    Failing tests for `absorb` when threshold <= LTV <= max penalty LTV
    """
    yangs = [steth_yang, doge_yang]
    await advance_yang_prices_by_percentage(starknet, shrine, yangs, price_change)

    # Assert trove is not healthy
    is_healthy = (await shrine.is_healthy(TROVE_1).execute()).result.healthy
    assert is_healthy == FALSE

    # Get LTV
    before_ltv = from_ray((await shrine.get_trove_info(TROVE_1).execute()).result.ltv)
    assert before_ltv <= MAX_PENALTY_LTV

    with pytest.raises(StarkException, match=f"Purger: Trove {TROVE_1} is not absorbable"):
        await purger.absorb(TROVE_1).execute(caller_address=SEARCHER)
