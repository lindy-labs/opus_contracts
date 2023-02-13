from decimal import ROUND_DOWN, Decimal

import pytest
from flaky import flaky
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

from tests.purger.constants import *  # noqa: F403
from tests.roles import EmpiricRoles, SentinelRoles
from tests.shrine.constants import FEED_LEN, MAX_PRICE_CHANGE, MULTIPLIER_FEED
from tests.utils import (
    ABSORBER_OWNER,
    EMPIRIC_DECIMALS,
    EMPIRIC_OWNER,
    FALSE,
    RAY_DECIMALS,
    RAY_SCALE,
    SENTINEL_OWNER,
    SHRINE_OWNER,
    SHRINE_ROLE_FOR_PURGER,
    TIME_INTERVAL,
    TROVE1_OWNER,
    TROVE2_OWNER,
    TROVE3_OWNER,
    TROVE_1,
    TROVE_2,
    TROVE_3,
    TRUE,
    WAD_RAY_OOB_VALUES,
    YangConfig,
    assert_equalish,
    assert_event_emitted,
    calculate_max_forge,
    compile_code,
    compile_contract,
    create_feed,
    custom_error_margin,
    estimate_gas,
    from_fixed_point,
    from_ray,
    from_uint,
    from_wad,
    get_block_timestamp,
    get_contract_code_with_replacement,
    max_approve,
    price_bounds,
    set_block_timestamp,
    to_empiric,
    to_ray,
    to_uint,
    to_wad,
)

#
# Constants
#

TROVES = (TROVE_1, TROVE_2, TROVE_3)

#
# Helpers
#


async def advance_yang_prices_by_percentage(
    starknet: Starknet,
    shrine: StarknetContract,
    yangs: tuple[YangConfig],
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

    return Decimal("0")


def get_freed_percentage(
    threshold: Decimal, ltv: Decimal, trove_value: Decimal, trove_debt: Decimal, close_amt: Decimal
) -> Decimal:
    """
    If LTV <= 100%, return the freed percentage based on (close amount + penalty amount) / total value of trove
    If LTV > 100%, return the freed percentage based on close amount / total debt of trove.
    """
    if close_amt == 0:
        return Decimal("0")

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
async def shrine_feeds(starknet, sentinel_with_yangs, shrine, yangs) -> list[list[int]]:
    # Creating the price feeds
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
async def forged_troves(shrine, shrine_feeds, abbot, sentinel_with_yangs, yangs, funded_trove_owners) -> list[int]:
    forged_amts = []

    trove_owners = [TROVE1_OWNER, TROVE2_OWNER, TROVE3_OWNER]
    for trove, owner in zip(TROVES, trove_owners):
        prices = []

        for yang in yangs:
            price = from_wad((await shrine.get_current_yang_price(yang.contract_address).execute()).result.price)
            prices.append(price)

        # Get maximum forge amount
        deposit_amts = [USER_STETH_DEPOSIT_WAD, USER_DOGE_DEPOSIT_WAD, USER_WBTC_DEPOSIT_AMT]

        # Add some variation to trove
        if trove == TROVE_3:
            deposit_amts = [i // 2 for i in deposit_amts]

        amounts = [from_fixed_point(amt, yang.decimals) for amt, yang in zip(deposit_amts, yangs)]

        thresholds = [from_ray(yang.threshold) for yang in yangs]
        max_forge_amt = calculate_max_forge(prices, amounts, thresholds)

        forge_amt = to_wad(max_forge_amt - 1)

        await abbot.open_trove(
            forge_amt,
            [yang.contract_address for yang in yangs],
            deposit_amts,
        ).execute(caller_address=owner)

        forged_amts.append(forge_amt)

    return forged_amts


@pytest.fixture
async def funded_searcher(shrine, shrine_feeds, abbot, sentinel_with_yangs, steth_token, steth_yang: YangConfig):
    # fund the searcher with bags
    await steth_token.mint(SEARCHER, to_uint(SEARCHER_STETH_WAD)).execute(caller_address=SEARCHER)

    # Searcher approves Aura gates to spend bags
    await max_approve(steth_token, SEARCHER, steth_yang.gate_address)

    await abbot.open_trove(SEARCHER_FORGE_AMT_WAD, [steth_yang.contract_address], [SEARCHER_STETH_WAD]).execute(
        caller_address=SEARCHER
    )


@pytest.fixture
async def prefunded_absorber_provider(
    shrine, shrine_feeds, abbot, sentinel_with_yangs, absorber, steth_yang: YangConfig, steth_token
):
    # fund the absorber with bags
    await steth_token.mint(ABSORBER_PROVIDER, to_uint(ABSORBER_PROVIDER_STETH_WAD)).execute(
        caller_address=ABSORBER_PROVIDER
    )

    # Absorber approves the Aura gates to spend bags
    await max_approve(steth_token, ABSORBER_PROVIDER, steth_yang.gate_address)

    await abbot.open_trove(
        ABSORBER_PROVIDER_FORGE_AMT_WAD, [steth_yang.contract_address], [ABSORBER_PROVIDER_STETH_WAD]
    ).execute(caller_address=ABSORBER_PROVIDER)

    await max_approve(shrine, ABSORBER_PROVIDER, absorber.contract_address)


@pytest.fixture
async def funded_absorber(absorber, prefunded_absorber_provider):
    await absorber.provide(ABSORBER_PROVIDER_FORGE_AMT_WAD).execute(caller_address=ABSORBER_PROVIDER)


@pytest.fixture
async def absorber(starknet, shrine, sentinel):
    absorber_contract = compile_contract("contracts/absorber/absorber.cairo")
    absorber = await starknet.deploy(
        contract_class=absorber_contract,
        constructor_calldata=[
            ABSORBER_OWNER,
            shrine.contract_address,
            sentinel.contract_address,
        ],
    )

    return absorber


@pytest.fixture
async def purger(starknet, shrine, sentinel, empiric, absorber) -> StarknetContract:
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
            absorber.contract_address,
            empiric.contract_address,
        ],
    )

    # Approve purger to call `seize` in Shrine
    await shrine.grant_role(SHRINE_ROLE_FOR_PURGER, purger.contract_address).execute(caller_address=SHRINE_OWNER)

    # Approve purger to call `exit` in Gate
    await sentinel.grant_role(SentinelRoles.EXIT, purger.contract_address).execute(caller_address=SENTINEL_OWNER)

    # Approve purger to call `update_prices` in Empiric
    await empiric.grant_role(EmpiricRoles.UPDATE_PRICES, purger.contract_address).execute(caller_address=EMPIRIC_OWNER)

    # Set purger in absorber
    await absorber.set_purger(purger.contract_address).execute(caller_address=ABSORBER_OWNER)

    return purger


#
# Tests - Setup
#


@pytest.mark.usefixtures("sentinel_with_yangs")
@pytest.mark.asyncio
async def test_sentinel_setup(sentinel, yangs):
    assert (await sentinel.get_admin().execute()).result.admin == SENTINEL_OWNER
    yang_addrs = (await sentinel.get_yang_addresses().execute()).result.addresses
    assert len(yang_addrs) == len(yangs)
    for yang in yangs:
        assert yang.contract_address in yang_addrs


@pytest.mark.usefixtures("sentinel_with_yangs")
@pytest.mark.asyncio
async def test_shrine_setup(shrine, shrine_feeds, yangs):
    # Check price feeds
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


@pytest.mark.usefixtures("sentinel_with_yangs")
@pytest.mark.asyncio
async def test_troves_setup(shrine, purger, forged_troves):
    forged_amts = forged_troves
    for trove, forged_amt in zip(TROVES, forged_amts):
        trove_debt = (await shrine.get_trove_info(trove).execute()).result.debt
        assert trove_debt == forged_amt


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
    "max_close_multiplier", [Decimal("0.001"), Decimal("0.01"), Decimal("0.1"), Decimal("1"), Decimal("1.01")]
)
@pytest.mark.usefixtures("sentinel_with_yangs", "forged_troves", "funded_searcher")
@pytest.mark.asyncio
async def test_liquidate_pass(
    starknet,
    shrine,
    sentinel,
    purger,
    yang_tokens,
    yangs,
    price_change,
    max_close_multiplier,
):
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
    close_amt_wad = input_close_amt_wad = int(max_close_multiplier * maximum_close_amt_wad)
    if input_close_amt_wad > maximum_close_amt_wad:
        close_amt_wad = maximum_close_amt_wad

    close_amt = from_wad(close_amt_wad)

    # Sanity check: searcher has sufficient yin
    searcher_yin_balance = (await shrine.balanceOf(SEARCHER).execute()).result.balance
    assert from_uint(searcher_yin_balance) > close_amt_wad

    # Get freed percentage
    freed_percentage = get_freed_percentage(
        before_trove_threshold, before_trove_ltv, before_trove_value, before_trove_debt, close_amt
    )

    yangs_info = {}

    for token, yang in zip(yang_tokens, yangs):
        # Get yang token balance of searcher
        adjusted_bal = from_fixed_point(
            from_uint((await token.balanceOf(SEARCHER).execute()).result.balance), yang.decimals
        )

        # Get yang balance of trove and calculate amount expected to be freed
        before_trove_yang_wad = (await shrine.get_deposit(token.contract_address, TROVE_1).execute()).result.balance
        before_trove_asset_bal_wad = (
            await sentinel.preview_exit(yang.contract_address, before_trove_yang_wad).execute()
        ).result.asset_amt
        expected_freed_yang = freed_percentage * from_wad(before_trove_yang_wad)
        expected_freed_asset = freed_percentage * from_fixed_point(before_trove_asset_bal_wad, yang.decimals)

        yangs_info[yang.contract_address] = {
            "before_searcher_bal": adjusted_bal,
            "before_trove_yang_wad": before_trove_yang_wad,
            "expected_freed_yang": expected_freed_yang,
            "expected_freed_asset": expected_freed_asset,
        }

    # Sanity check that expected trove LTV does not increase
    expected_after_trove_debt = before_trove_debt - close_amt
    expected_after_trove_value = before_trove_value * (1 - freed_percentage)

    if input_close_amt_wad >= before_trove_debt:
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
    expected_yang_addresses = [yang.contract_address for yang in yangs]
    assert liquidate.result.yangs == expected_yang_addresses

    actual_freed_assets = liquidate.result.freed_assets_amt
    for actual, yang in zip(actual_freed_assets, yangs):
        error_margin = custom_error_margin(yang.decimals)
        expected = yangs_info[yang.contract_address]["expected_freed_asset"]
        assert_equalish(from_fixed_point(actual, yang.decimals), expected, error_margin)

    # Check event
    assert_event_emitted(
        liquidate,
        purger.contract_address,
        "Purged",
        lambda d: d[:4] == [TROVE_1, close_amt_wad, SEARCHER, SEARCHER]
        and d[5:] == [len(yangs), *expected_yang_addresses, len(yangs), *actual_freed_assets],
    )

    # Check that LTV has improved (before LTV < 100%) or stayed the same (before LTV >= 100%)
    after_trove_info = (await shrine.get_trove_info(TROVE_1).execute()).result
    after_trove_ltv = from_ray(after_trove_info.ltv)
    after_trove_debt = from_wad(after_trove_info.debt)
    after_trove_value = from_wad(after_trove_info.value)

    assert after_trove_ltv <= before_trove_ltv
    assert_equalish(after_trove_value, expected_after_trove_value)
    assert_equalish(after_trove_debt, expected_after_trove_debt)

    for token, yang in zip(yang_tokens, yangs):
        # Check collateral tokens balance of searcher
        error_margin = custom_error_margin(yang.decimals)
        after_searcher_bal = from_fixed_point(
            from_uint((await token.balanceOf(SEARCHER).execute()).result.balance), yang.decimals
        )
        before_searcher_bal = yangs_info[yang.contract_address]["before_searcher_bal"]
        expected_freed_asset = yangs_info[yang.contract_address]["expected_freed_asset"]
        assert_equalish(after_searcher_bal, before_searcher_bal + expected_freed_asset, error_margin)

        # Get yang balance of trove
        after_trove_yang = from_wad(
            (await shrine.get_deposit(token.contract_address, TROVE_1).execute()).result.balance
        )
        before_trove_yang_wad = yangs_info[yang.contract_address]["before_trove_yang_wad"]
        expected_freed_yang = yangs_info[yang.contract_address]["expected_freed_yang"]
        assert_equalish(after_trove_yang, from_wad(before_trove_yang_wad) - expected_freed_yang)


@pytest.mark.parametrize("fn", ["liquidate", "absorb"])
@pytest.mark.usefixtures("sentinel_with_yangs", "forged_troves", "funded_searcher")
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


@pytest.mark.usefixtures("sentinel_with_yangs", "forged_troves")
@pytest.mark.asyncio
async def test_liquidate_fail_insufficient_yin(starknet, shrine, purger, yangs):
    # SEARCHER is not funded because `funded_searcher` fixture was omitted
    price_change = Decimal("-0.1")
    await advance_yang_prices_by_percentage(starknet, shrine, yangs, price_change)

    # Assert max close amount is positive
    max_close_amt = (await purger.get_max_close_amount(TROVE_1).execute()).result.amount
    assert max_close_amt > 0

    with pytest.raises(StarkException):
        await purger.liquidate(TROVE_1, max_close_amt, SEARCHER).execute(caller_address=SEARCHER)


@pytest.mark.parametrize("price_change", [Decimal("-0.2"), Decimal("-0.5"), Decimal("-0.9")])
@pytest.mark.usefixtures("sentinel_with_yangs", "forged_troves", "funded_absorber")
@pytest.mark.asyncio
async def test_full_absorb_pass(starknet, shrine, sentinel, absorber, purger, yang_tokens, yangs, price_change):
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
    if before_trove_ltv < Decimal("1"):
        expected_penalty = get_penalty(before_trove_threshold, before_trove_ltv, before_trove_value, before_trove_debt)
        assert_equalish(penalty, expected_penalty)

    # Sanity check: absorber has sufficient yin
    absorber_yin_balance = (await shrine.balanceOf(absorber.contract_address).execute()).result.balance
    assert from_wad(from_uint(absorber_yin_balance)) > before_trove_debt

    yangs_info = {}

    for token, yang in zip(yang_tokens, yangs):
        # Get yang token balance of absorber
        adjusted_bal = from_fixed_point(
            from_uint((await token.balanceOf(absorber.contract_address).execute()).result.balance), yang.decimals
        )

        # Get yang balance of trove and calculate amount expected to be freed
        expected_freed_yang = (await shrine.get_deposit(token.contract_address, TROVE_1).execute()).result.balance
        expected_freed_asset = from_fixed_point(
            (await sentinel.preview_exit(yang.contract_address, expected_freed_yang).execute()).result.asset_amt,
            yang.decimals,
        )

        yangs_info[yang.contract_address] = {
            "before_absorber_bal": adjusted_bal,
            "expected_freed_asset": expected_freed_asset,
        }

    # Call absorb
    absorb = await purger.absorb(TROVE_1).execute(caller_address=SEARCHER)

    # Check return data
    expected_yang_addresses = [yang.contract_address for yang in yangs]
    assert absorb.result.yangs == expected_yang_addresses

    actual_freed_assets = absorb.result.freed_assets_amt
    for actual, yang in zip(actual_freed_assets, yangs):
        error_margin = custom_error_margin(yang.decimals)
        expected = yangs_info[yang.contract_address]["expected_freed_asset"]
        assert_equalish(from_fixed_point(actual, yang.decimals), expected, error_margin)

    # Check event
    assert_event_emitted(
        absorb,
        purger.contract_address,
        "Purged",
        lambda d: d[:4] == [TROVE_1, before_trove_info.debt, absorber.contract_address, absorber.contract_address]
        and d[5:] == [len(yangs), *expected_yang_addresses, len(yangs), *actual_freed_assets],
    )

    assert_event_emitted(
        absorb,
        absorber.contract_address,
        "Gain",
        lambda d: d[:8] == [len(yangs), *expected_yang_addresses, len(yangs), *actual_freed_assets],
    )

    # Check that LTV is 0 after all debt is repaid
    after_trove_info = (await shrine.get_trove_info(TROVE_1).execute()).result
    after_trove_ltv = from_ray(after_trove_info.ltv)
    after_trove_debt = from_wad(after_trove_info.debt)

    assert after_trove_ltv == 0

    for token, yang in zip(yang_tokens, yangs):
        # Check collateral tokens balance of absorber
        error_margin = custom_error_margin(yang.decimals)
        after_absorber_bal = from_fixed_point(
            from_uint((await token.balanceOf(absorber.contract_address).execute()).result.balance), yang.decimals
        )
        before_absorber_bal = yangs_info[yang.contract_address]["before_absorber_bal"]
        expected_freed_asset = yangs_info[yang.contract_address]["expected_freed_asset"]
        assert_equalish(after_absorber_bal, before_absorber_bal + expected_freed_asset, error_margin)

        # Get yang balance of trove
        after_trove_yang = from_wad(
            (await shrine.get_deposit(token.contract_address, TROVE_1).execute()).result.balance
        )
        assert after_trove_yang == 0

    # Check trove debt
    assert after_trove_debt == 0


# Percentage of trove's debt that can be covered by the stability pool
@pytest.mark.parametrize("percentage_absorbed", [Decimal("0"), Decimal("0.5"), Decimal("0.9")])
@pytest.mark.parametrize("price_change", [Decimal("-0.2"), Decimal("-0.5"), Decimal("-0.9")])
@pytest.mark.usefixtures("sentinel_with_yangs", "forged_troves", "prefunded_absorber_provider")
@pytest.mark.asyncio
async def test_partial_absorb_with_redistribution_pass(
    starknet,
    shrine,
    abbot,
    sentinel,
    absorber,
    purger,
    empiric,
    mock_empiric_impl,
    yang_tokens,
    yangs,
    yang_gates,
    percentage_absorbed,
    price_change,
):
    liquidated_trove = TROVE_1
    other_troves = tuple([t for t in TROVES if t != liquidated_trove])

    await advance_yang_prices_by_percentage(starknet, shrine, yangs, price_change)

    ts = get_block_timestamp(starknet)
    num_sources = 3

    # Update mock Empiric oracle with the latest prices
    for yang in yangs:
        yang_price = from_wad((await shrine.get_current_yang_price(yang.contract_address).execute()).result.price)
        price = to_empiric(yang_price)
        await mock_empiric_impl.next_get_spot_median(
            yang.empiric_id, price, EMPIRIC_DECIMALS, ts, num_sources
        ).execute()

    # Assert trove is not healthy
    assert (await shrine.is_healthy(liquidated_trove).execute()).result.healthy is FALSE

    # Update trove 2 and trove 3 so that interest is accrued to current interval
    # in order to assert correctness after adding redistributed debt without interest
    # calculation interfering due to the change in price resulting from rebasing of assets
    for trove in other_troves:
        await shrine.melt(ABSORBER_PROVIDER, trove, 0).execute(caller_address=SHRINE_OWNER)

    # Get info of all troves
    before_troves_info = {}
    for trove in TROVES:
        before_trove_info = (await shrine.get_trove_info(trove).execute()).result
        before_trove_debt = from_wad(before_trove_info.debt)
        before_troves_info[trove] = {
            "before_trove_threshold": from_ray(before_trove_info.threshold),
            "before_trove_ltv": from_ray(before_trove_info.ltv),
            "before_trove_value": from_wad(before_trove_info.value),
            "before_trove_debt": before_trove_debt,
        }

    is_undercollateralized = False
    if before_troves_info[liquidated_trove]["before_trove_ltv"] > Decimal("1"):
        is_undercollateralized = True

    # Check purge penalty
    has_penalty = before_troves_info[liquidated_trove]["before_trove_ltv"] < Decimal("1")
    penalty = from_ray((await purger.get_penalty(liquidated_trove).execute()).result.penalty)
    if has_penalty is True:
        expected_penalty = get_penalty(
            before_troves_info[liquidated_trove]["before_trove_threshold"],
            before_troves_info[liquidated_trove]["before_trove_ltv"],
            before_troves_info[liquidated_trove]["before_trove_value"],
            before_troves_info[liquidated_trove]["before_trove_debt"],
        )
        assert_equalish(penalty, expected_penalty)

    # Fund absorber with a percentage of the debt of trove 1 so that redistribution is triggered
    liquidated_trove_debt = before_troves_info[liquidated_trove]["before_trove_debt"]
    absorber_forge_amt_wad = to_wad(percentage_absorbed * liquidated_trove_debt)
    if percentage_absorbed > 0:
        await absorber.provide(absorber_forge_amt_wad).execute(caller_address=ABSORBER_PROVIDER)

    # Sanity check
    assert (
        from_uint((await shrine.balanceOf(absorber.contract_address).execute()).result.balance)
        == absorber_forge_amt_wad
    )

    freed_percentage = get_freed_percentage(
        before_troves_info[liquidated_trove]["before_trove_threshold"],
        before_troves_info[liquidated_trove]["before_trove_ltv"],
        before_troves_info[liquidated_trove]["before_trove_value"],
        before_troves_info[liquidated_trove]["before_trove_debt"],
        from_wad(absorber_forge_amt_wad),
    )

    yangs_info = {}

    for token, yang, gate in zip(yang_tokens, yangs, yang_gates):
        # Get yang token balance of absorber
        adjusted_bal = from_fixed_point(
            from_uint((await token.balanceOf(absorber.contract_address).execute()).result.balance), yang.decimals
        )

        # Get yang balance of trove and calculate amount expected to be freed
        before_trove_yang_wad = (
            await shrine.get_deposit(yang.contract_address, liquidated_trove).execute()
        ).result.balance
        before_trove_asset_bal = (
            await sentinel.preview_exit(yang.contract_address, before_trove_yang_wad).execute()
        ).result.asset_amt

        expected_freed_asset = freed_percentage * from_fixed_point(before_trove_asset_bal, yang.decimals)

        before_gate_yang = from_wad((await shrine.get_yang_total(yang.contract_address).execute()).result.total)
        before_gate_asset_bal = from_fixed_point(
            from_uint((await token.balanceOf(yang.gate_address).execute()).result.balance), yang.decimals
        )

        yang_price = from_wad((await shrine.get_current_yang_price(yang.contract_address).execute()).result.price)
        yang_perc_value = (from_wad(before_trove_yang_wad) * yang_price) / before_troves_info[liquidated_trove][
            "before_trove_value"
        ]

        yangs_info[yang.contract_address] = {
            "yang_price": yang_price,
            "before_absorber_bal": adjusted_bal,
            "before_trove_yang_wad": before_trove_yang_wad,
            "expected_freed_asset": expected_freed_asset,
            "before_gate_yang": before_gate_yang,
            "before_gate_asset_bal": before_gate_asset_bal,
            "yang_perc_value": yang_perc_value,
        }

    # Call liquidate
    partial_absorb = await purger.absorb(liquidated_trove).execute(caller_address=SEARCHER)

    # Check return data
    expected_yang_addresses = [yang.contract_address for yang in yangs]
    assert partial_absorb.result.yangs == expected_yang_addresses

    actual_freed_assets = partial_absorb.result.freed_assets_amt
    for actual, yang in zip(actual_freed_assets, yangs):
        error_margin = custom_error_margin(yang.decimals // 2)
        expected = yangs_info[yang.contract_address]["expected_freed_asset"]
        assert_equalish(from_fixed_point(actual, yang.decimals), expected, error_margin)

    # Check events
    assert_event_emitted(
        partial_absorb,
        purger.contract_address,
        "Purged",
        lambda d: d[:4]
        == [liquidated_trove, absorber_forge_amt_wad, absorber.contract_address, absorber.contract_address]
        and d[5:] == [len(yangs), *expected_yang_addresses, len(yangs), *actual_freed_assets],
    )

    expected_redistribution_id = 1
    expected_redistributed_debt_wad = (
        to_wad(before_troves_info[liquidated_trove]["before_trove_debt"]) - absorber_forge_amt_wad
    )
    assert_event_emitted(
        partial_absorb,
        shrine.contract_address,
        "TroveRedistributed",
        # Assert property that redistributed debt is equal to estimated trove's debt before redistribution
        [expected_redistribution_id, liquidated_trove, expected_redistributed_debt_wad],
    )

    assert_event_emitted(
        partial_absorb,
        empiric.contract_address,
        "PricesUpdated",
    )

    for yang in yangs:
        assert_event_emitted(
            partial_absorb,
            shrine.contract_address,
            "YangTotalUpdated",
            lambda d: d[0] == yang.contract_address,
        )

        assert_event_emitted(
            partial_absorb,
            shrine.contract_address,
            "DepositUpdated",
            lambda d: d[:2] == [yang.contract_address, liquidated_trove],
        )

        # Gate will only emit `Exit` if the amount of assets to be withdrawn is greater than 0
        if percentage_absorbed > 0:
            assert_event_emitted(
                partial_absorb,
                yang.gate_address,
                "Exit",
                lambda d: d[0] == absorber.contract_address,
            )

    if percentage_absorbed > 0:
        assert_event_emitted(
            partial_absorb,
            absorber.contract_address,
            "Gain",
            lambda d: d[:8] == [len(yangs), *expected_yang_addresses, len(yangs), *actual_freed_assets],
        )

    assert (await shrine.get_redistributions_count().execute()).result.count == expected_redistribution_id

    after_troves_info = {}
    for trove in TROVES:
        after_trove_info = (await shrine.get_trove_info(trove).execute()).result
        after_troves_info[trove] = {
            "after_trove_threshold": from_ray(after_trove_info.threshold),
            "after_trove_ltv": from_ray(after_trove_info.ltv),
            "after_trove_value": from_wad(after_trove_info.value),
            "after_trove_debt": from_wad(after_trove_info.debt),
        }

        if trove != liquidated_trove:
            # starting value to calculate expected debt and value below
            after_troves_info[trove]["expected_trove_debt"] = before_troves_info[trove]["before_trove_debt"]

    # Check that all values of liquidated trove are set to zero
    assert all(i == 0 for i in after_troves_info[liquidated_trove].values()) is True

    for token, yang, gate in zip(yang_tokens, yangs, yang_gates):
        # Relax the error margin slightly due to python calculations in decimal
        # vs fixed point calculations in Cairo
        error_margin = custom_error_margin(yang.decimals) * 2

        # Token: Check collateral tokens balance of absorber
        after_absorber_bal = from_fixed_point(
            from_uint((await token.balanceOf(absorber.contract_address).execute()).result.balance), yang.decimals
        )
        before_absorber_bal = yangs_info[yang.contract_address]["before_absorber_bal"]
        expected_freed_asset = yangs_info[yang.contract_address]["expected_freed_asset"]
        assert_equalish(after_absorber_bal, before_absorber_bal + expected_freed_asset, error_margin)

        # Shrine: Yang balance of trove should be zero
        after_trove_yang = from_wad(
            (await shrine.get_deposit(token.contract_address, liquidated_trove).execute()).result.balance
        )
        assert after_trove_yang == 0

        # Gate/Token: Asset balance should be decremented by the amount freed to the absorber
        before_gate_asset_bal = yangs_info[yang.contract_address]["before_gate_asset_bal"]
        freed_asset_bal = yangs_info[yang.contract_address]["expected_freed_asset"]
        expected_gate_asset_bal = before_gate_asset_bal - freed_asset_bal

        after_gate_asset_bal = from_fixed_point(
            from_uint((await token.balanceOf(yang.gate_address).execute()).result.balance), yang.decimals
        )
        assert_equalish(after_gate_asset_bal, expected_gate_asset_bal, error_margin)

        # Shrine: Yang total should be decremented by trove's balance pre-absorb
        before_gate_yang = yangs_info[yang.contract_address]["before_gate_yang"]
        before_trove_yang = from_wad(yangs_info[yang.contract_address]["before_trove_yang_wad"])
        expected_yang = before_gate_yang - before_trove_yang

        after_gate_yang = from_wad((await shrine.get_yang_total(yang.contract_address).execute()).result.total)
        assert_equalish(after_gate_yang, expected_yang)

        # Shrine: Yang price should have increased due to rebasing
        before_yang_price = yangs_info[yang.contract_address]["yang_price"]
        after_yang_price = from_wad((await shrine.get_current_yang_price(yang.contract_address).execute()).result.price)
        assert after_yang_price > before_yang_price

        # Gate: Ratio of asset to yang should be updated
        after_gate_asset_amt_per_yang = from_wad((await gate.get_asset_amt_per_yang().execute()).result.amt)
        expected_gate_asset_amt_per_yang = expected_gate_asset_bal / expected_yang
        assert_equalish(after_gate_asset_amt_per_yang, expected_gate_asset_amt_per_yang, error_margin)

        # Shrine: Check redistribution in Shrine
        percentage_debt_redistributed = yangs_info[yang.contract_address]["yang_perc_value"]
        yang_debt_redistributed = percentage_debt_redistributed * from_wad(expected_redistributed_debt_wad)
        expected_unit_debt_for_yang = yang_debt_redistributed / expected_yang

        unit_debt_for_yang = from_wad(
            (
                await shrine.get_redistributed_unit_debt_for_yang(
                    yang.contract_address, expected_redistribution_id
                ).execute()
            ).result.unit_debt
        )
        assert_equalish(unit_debt_for_yang, expected_unit_debt_for_yang)

        # Shrine: Calculate the expected debt for troves that received the distribution
        for trove in other_troves:
            deposited_yang = from_wad((await shrine.get_deposit(yang.contract_address, trove).execute()).result.balance)
            debt_increment = deposited_yang * unit_debt_for_yang
            after_troves_info[trove]["expected_trove_debt"] += debt_increment

    # Check troves that received the redistribution
    for trove in other_troves:
        after_trove_debt = after_troves_info[trove]["after_trove_debt"]
        expected_debt = after_troves_info[trove]["expected_trove_debt"]
        assert_equalish(after_trove_debt, expected_debt)

        before_trove_ltv = before_troves_info[trove]["before_trove_ltv"]
        after_trove_ltv = after_troves_info[trove]["after_trove_ltv"]

        # If liquidated trove is undercollateralized, LTV of other troves must be same or worse off after redistribution
        # Otherwise, LTV could be slightly better/worse off or remain the same.
        if is_undercollateralized:
            assert after_trove_ltv >= before_trove_ltv
        else:
            ltv_error_margin = RAY_DECIMALS // 2
            assert_equalish(after_trove_ltv, before_trove_ltv, ltv_error_margin)

    assert (await shrine.get_trove_redistribution_id(TROVE_2).execute()).result.redistribution_id == 0
    await shrine.melt(TROVE2_OWNER, TROVE_2, 0).execute(caller_address=SHRINE_OWNER)
    assert (
        await shrine.get_trove_redistribution_id(TROVE_2).execute()
    ).result.redistribution_id == expected_redistribution_id

    # Storage keys updated:
    # Shrine
    # - shrine_troves
    # - shrine_deposits * num_yangs
    # - shrine_yangs * num_yangs
    # - shrine_redistribution_count
    # - shrine_yang_redistribution (debt_per_yang + error) * num_yangs
    # - shrine_yang_price * num_yangs
    #
    # Gate (None)
    #
    # Asset ERC-20
    # - Balance of gate * num_yangs
    # - Balance of absorber * num_yangs
    #
    # Empiric
    # - Last price update
    print(f"\nPartial absorb: (3 yangs, 1 trove) - redistribute: \n" f"{estimate_gas(partial_absorb, 3 + 6 * 3, 3)}")


@pytest.mark.parametrize("price_change", [Decimal("-0.05"), Decimal("-0.1")])
@pytest.mark.usefixtures("sentinel_with_yangs", "forged_troves", "funded_absorber")
@pytest.mark.asyncio
async def test_absorb_fail_ltv_too_low(starknet, shrine, purger, yangs, price_change):
    """
    Failing tests for `absorb` when threshold <= LTV <= max penalty LTV
    """
    await advance_yang_prices_by_percentage(starknet, shrine, yangs, price_change)

    # Assert trove is not healthy
    is_healthy = (await shrine.is_healthy(TROVE_1).execute()).result.healthy
    assert is_healthy == FALSE

    # Get LTV
    before_ltv = from_ray((await shrine.get_trove_info(TROVE_1).execute()).result.ltv)
    assert before_ltv <= MAX_PENALTY_LTV

    with pytest.raises(StarkException, match=f"Purger: Trove {TROVE_1} is not absorbable"):
        await purger.absorb(TROVE_1).execute(caller_address=SEARCHER)
