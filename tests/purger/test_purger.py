from decimal import Decimal
from typing import List

import pytest
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

from tests.purger.constants import *  # noqa: F403
from tests.roles import GateRoles, PurgerRoles, ShrineRoles
from tests.shrine.constants import FEED_LEN, MAX_PRICE_CHANGE, MULTIPLIER_FEED
from tests.utils import (
    ABBOT_OWNER,
    AURA_USER,
    FALSE,
    GATE_OWNER,
    PURGER_OWNER,
    RAY_SCALE,
    SHRINE_OWNER,
    STETH_OWNER,
    TIME_INTERVAL,
    TROVE_1,
    TRUE,
    YangConfig,
    assert_equalish,
    assert_event_emitted,
    calculate_max_forge,
    compile_contract,
    create_feed,
    from_ray,
    from_uint,
    from_wad,
    max_approve,
    price_bounds,
    set_block_timestamp,
    to_wad,
)

#
# Helpers
#


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
        current_price = (await shrine.get_current_yang_price(yang_address).execute()).result.price_wad

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


def get_penalty(ltv: Decimal) -> Decimal:
    """
    Returns the penalty given the LTV.
    """
    return ltv * Decimal("0.05")


def get_freed_percentage(ltv: Decimal, close_amt: Decimal, trove_debt: Decimal, trove_value: Decimal) -> Decimal:
    """
    If LTV <= 100%, return the freed percentage based on (close amount + penalty amount) / total value of trove
    If LTV > 100%, return the freed percentage based on close amount / total debt of trove.
    """
    if ltv > Decimal("1"):
        return close_amt / trove_debt

    penalty = get_penalty(ltv)
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
    starknet, abbot_with_yangs, shrine, steth_yang: YangConfig, doge_yang: YangConfig
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

        await shrine.update_multiplier(MULTIPLIER_FEED[i]).execute(caller_address=SHRINE_OWNER)

    return feeds


@pytest.fixture
async def aura_user_with_first_trove(
    shrine,
    shrine_feeds,
    abbot,
    abbot_with_yangs,
    steth_yang: YangConfig,
    doge_yang: YangConfig,
) -> int:
    # Get stETH price
    steth_price = (await shrine.get_current_yang_price(steth_yang.contract_address).execute()).result.price_wad

    # Get Doge price
    doge_price = (await shrine.get_current_yang_price(doge_yang.contract_address).execute()).result.price_wad

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
    ).execute(caller_address=AURA_USER)

    return forge_amt


@pytest.fixture
async def funded_searcher(shrine, shrine_feeds, abbot, abbot_with_yangs, steth_token, steth_yang: YangConfig):
    # fund the user with bags
    await steth_token.transfer(SEARCHER, (SEARCHER_STETH_WAD, 0)).execute(caller_address=STETH_OWNER)

    # user approves Aura gates to spend bags
    await max_approve(steth_token, SEARCHER, steth_yang.gate_address)

    await abbot.open_trove(SEARCHER_FORGE_AMT_WAD, [steth_yang.contract_address], [SEARCHER_STETH_WAD]).execute(
        caller_address=SEARCHER
    )


@pytest.fixture
async def purger(request, starknet, shrine, abbot, yin, steth_gate, doge_gate) -> StarknetContract:
    purger_contract = compile_contract("contracts/purger/purger.cairo", request)
    purger = await starknet.deploy(
        contract_class=purger_contract,
        constructor_calldata=[
            PURGER_OWNER,
            shrine.contract_address,
            abbot.contract_address,
            yin.contract_address,
        ],
    )

    # Approve purger to call `seize` in Shrine
    purger_roles = ShrineRoles.MELT + ShrineRoles.SEIZE
    await shrine.grant_role(purger_roles, purger.contract_address).execute(caller_address=SHRINE_OWNER)

    # Approve purger to call `withdraw` in Gate
    await steth_gate.grant_role(GateRoles.WITHDRAW, purger.contract_address).execute(caller_address=GATE_OWNER)
    await doge_gate.grant_role(GateRoles.WITHDRAW, purger.contract_address).execute(caller_address=GATE_OWNER)

    # Approve purger contract for `restricted_purge`
    await purger.grant_role(PurgerRoles.RESTRICTED_PURGE, SEARCHER).execute(caller_address=PURGER_OWNER)

    return purger


#
# Tests
#


@pytest.mark.usefixtures("abbot_with_yangs")
@pytest.mark.asyncio
async def test_abbot_setup(abbot, steth_yang: YangConfig, doge_yang: YangConfig):
    assert (await abbot.get_admin().execute()).result.address == ABBOT_OWNER
    yang_addrs = (await abbot.get_yang_addresses().execute()).result.addresses
    assert len(yang_addrs) == 2
    assert steth_yang.contract_address in yang_addrs
    assert doge_yang.contract_address in yang_addrs


@pytest.mark.usefixtures("abbot_with_yangs")
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


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user")
@pytest.mark.asyncio
async def test_aura_user_setup(shrine, purger, aura_user_with_first_trove):
    # Check
    forge_amt = aura_user_with_first_trove
    trove = (await shrine.get_trove(TROVE_1).execute()).result.trove
    assert trove.debt == forge_amt


@pytest.mark.parametrize("price_change", [Decimal("-0.08"), Decimal("-0.1"), Decimal("-0.12"), Decimal("-0.2")])
@pytest.mark.parametrize("max_close_percentage", [Decimal("0.01"), Decimal("0.1"), Decimal("1")])
@pytest.mark.parametrize("purge_fn", ["purge", "restricted_purge"])
@pytest.mark.usefixtures(
    "abbot_with_yangs",
    "funded_aura_user",
    "aura_user_with_first_trove",
    "funded_searcher",
)
@pytest.mark.asyncio
async def test_purge(
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
    purge_fn,
):

    yangs = [steth_yang, doge_yang]
    await advance_yang_prices_by_percentage(starknet, shrine, yangs, price_change)

    # Assert trove is not healthy
    is_healthy = (await shrine.is_healthy(TROVE_1).execute()).result.bool
    assert is_healthy == FALSE

    # Get LTV
    before_ltv = from_ray((await shrine.get_current_trove_ratio(TROVE_1).execute()).result.ray)

    # Check purge penalty
    purge_penalty = from_ray((await purger.get_purge_penalty(TROVE_1).execute()).result.ray)
    expected_purge_penalty = get_penalty(before_ltv)
    assert_equalish(purge_penalty, expected_purge_penalty)

    # Check maximum close amount
    estimated_debt = from_wad((await shrine.estimate(TROVE_1).execute()).result.wad)
    expected_maximum_close_amt = get_max_close_amount(estimated_debt, before_ltv)
    maximum_close_amt_wad = (await purger.get_max_close_amount(TROVE_1).execute()).result.wad
    assert_equalish(from_wad(maximum_close_amt_wad), expected_maximum_close_amt)

    # Calculate close amount based on parametrization
    close_amt_wad = int(max_close_percentage * maximum_close_amt_wad)
    close_amt = from_wad(close_amt_wad)

    # Sanity check: searcher has sufficient yin
    searcher_yin_balance = (await yin.balanceOf(SEARCHER).execute()).result.wad
    assert searcher_yin_balance > close_amt_wad

    # Get yang balance of searcher
    before_searcher_steth_bal = from_wad(from_uint((await steth_token.balanceOf(SEARCHER).execute()).result.balance))
    before_searcher_doge_bal = from_wad(from_uint((await doge_token.balanceOf(SEARCHER).execute()).result.balance))

    # Get freed percentage
    trove_value = from_wad((await shrine.get_trove_threshold(TROVE_1).execute()).result.value_wad)
    trove_debt = from_wad((await shrine.estimate(TROVE_1).execute()).result.wad)
    freed_percentage = get_freed_percentage(before_ltv, close_amt, trove_debt, trove_value)

    # Get yang balance of trove
    before_trove_steth_yang_wad = (await shrine.get_deposit(steth_token.contract_address, TROVE_1).execute()).result.wad
    before_trove_steth_bal_wad = (await steth_gate.preview_withdraw(before_trove_steth_yang_wad).execute()).result.wad
    expected_freed_steth = freed_percentage * from_wad(before_trove_steth_bal_wad)

    before_trove_doge_yang_wad = (await shrine.get_deposit(doge_token.contract_address, TROVE_1).execute()).result.wad
    before_trove_doge_bal_wad = (await doge_gate.preview_withdraw(before_trove_doge_yang_wad).execute()).result.wad
    expected_freed_doge = freed_percentage * from_wad(before_trove_doge_bal_wad)

    # Call purge
    method = purger.get_contract_function(purge_fn)
    purge_args = [TROVE_1, close_amt_wad, SEARCHER]
    if purge_fn == "restricted_purge":
        purge_args.append(SEARCHER)

    purge = await method(*purge_args).execute(caller_address=SEARCHER)

    # Check event
    assert_event_emitted(
        purge,
        purger.contract_address,
        "Purged",
        lambda d: d[:2] == [TROVE_1, close_amt_wad] and d[3:] == [SEARCHER, SEARCHER],
    )

    # Check that LTV has improved
    after_ltv = from_ray((await shrine.get_current_trove_ratio(TROVE_1).execute()).result.ray)
    assert after_ltv < before_ltv

    # Check yang balance of searcher
    after_searcher_steth_bal = from_wad(from_uint((await steth_token.balanceOf(SEARCHER).execute()).result.balance))
    assert_equalish(after_searcher_steth_bal, before_searcher_steth_bal + expected_freed_steth)

    after_searcher_doge_bal = from_wad(from_uint((await doge_token.balanceOf(SEARCHER).execute()).result.balance))
    assert_equalish(after_searcher_doge_bal, before_searcher_doge_bal + expected_freed_doge)


@pytest.mark.parametrize("purge_fn", ["purge", "restricted_purge"])
@pytest.mark.usefixtures(
    "abbot_with_yangs",
    "funded_aura_user",
    "aura_user_with_first_trove",
    "funded_searcher",
)
@pytest.mark.asyncio
async def test_purge_fail_trove_healthy(shrine, purger, purge_fn):
    # Check close amount is 0
    max_close_amt = (await purger.get_max_close_amount(TROVE_1).execute()).result.wad
    assert max_close_amt == 0

    # Check purge penalty is 0
    purge_penalty = (await purger.get_purge_penalty(TROVE_1).execute()).result.ray
    assert purge_penalty == 0

    # Check trove is healthy
    is_healthy = (await shrine.is_healthy(TROVE_1).execute()).result.bool
    assert is_healthy == TRUE

    # Get trove debt
    purge_amt = (await shrine.estimate(TROVE_1).execute()).result.wad // 2

    method = purger.get_contract_function(purge_fn)
    purge_args = [TROVE_1, purge_amt, SEARCHER]
    if purge_fn == "restricted_purge":
        purge_args.append(SEARCHER)

    with pytest.raises(StarkException, match="Purger: Trove is not liquidatable"):
        await method(*purge_args).execute(caller_address=SEARCHER)


@pytest.mark.parametrize("purge_fn", ["purge", "restricted_purge"])
@pytest.mark.usefixtures(
    "abbot_with_yangs",
    "funded_aura_user",
    "aura_user_with_first_trove",
    "funded_searcher",
)
@pytest.mark.asyncio
async def test_purge_fail_exceed_max_close(
    starknet,
    shrine,
    purger,
    steth_yang: YangConfig,
    doge_yang: YangConfig,
    purge_fn,
):

    yangs = [steth_yang, doge_yang]
    price_change = Decimal("-0.1")
    await advance_yang_prices_by_percentage(starknet, shrine, yangs, price_change)

    # Assert max close amount is positive
    max_close_amt = (await purger.get_max_close_amount(TROVE_1).execute()).result.wad
    assert max_close_amt > 0

    method = purger.get_contract_function(purge_fn)
    purge_args = [TROVE_1, max_close_amt + 1, SEARCHER]
    if purge_fn == "restricted_purge":
        purge_args.append(SEARCHER)

    with pytest.raises(StarkException, match="Purger: Maximum close amount exceeded"):
        await method(*purge_args).execute(caller_address=SEARCHER)


@pytest.mark.parametrize("purge_fn", ["purge", "restricted_purge"])
@pytest.mark.usefixtures(
    "abbot_with_yangs",
    "funded_aura_user",
    "aura_user_with_first_trove",
)
@pytest.mark.asyncio
async def test_purge_fail_insufficient_yin(
    starknet,
    shrine,
    purger,
    yin,
    steth_yang: YangConfig,
    doge_yang: YangConfig,
    purge_fn,
):

    yangs = [steth_yang, doge_yang]
    price_change = Decimal("-0.1")
    await advance_yang_prices_by_percentage(starknet, shrine, yangs, price_change)

    # Drain funded searcher's account and leave 10 yin
    # remaining_bal = to_wad(10)
    # searcher_yin_wad = (await yin.balanceOf(SEARCHER).execute()).result.wad
    # await yin.transfer(SHRINE_OWNER, searcher_yin_wad - remaining_bal).execute(caller_address=SEARCHER)

    # Assert max close amount is positive
    max_close_amt = (await purger.get_max_close_amount(TROVE_1).execute()).result.wad
    assert max_close_amt > 0

    method = purger.get_contract_function(purge_fn)
    purge_args = [TROVE_1, max_close_amt, SEARCHER]
    if purge_fn == "restricted_purge":
        purge_args.append(SEARCHER)

    with pytest.raises(StarkException):
        await method(*purge_args).execute(caller_address=SEARCHER)
