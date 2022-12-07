from decimal import Decimal

import pytest
from starkware.starknet.testing.contract import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.oracle.constants import (
    EMPIRIC_FRESHNESS_THRESHOLD,
    EMPIRIC_LOWER_FRESHNESS_BOUND,
    EMPIRIC_LOWER_SOURCES_BOUND,
    EMPIRIC_LOWER_UPDATE_INTERVAL_BOUND,
    EMPIRIC_SOURCES_THRESHOLD,
    EMPIRIC_UPDATE_INTERVAL,
    EMPIRIC_UPPER_FRESHNESS_BOUND,
    EMPIRIC_UPPER_SOURCES_BOUND,
    EMPIRIC_UPPER_UPDATE_INTERVAL_BOUND,
    INIT_BLOCK_TS,
    INITIAL_ASSET_AMT_PER_YANG,
)
from tests.roles import EmpiricRoles
from tests.utils import (
    BAD_GUY,
    EMPIRIC_OWNER,
    GATE_OWNER,
    GATE_ROLE_FOR_SENTINEL,
    RAY_PERCENT,
    SENTINEL_OWNER,
    TIME_INTERVAL,
    TROVE1_OWNER,
    assert_event_emitted,
    max_approve,
    set_block_timestamp,
    signed_int_to_felt,
    str_to_felt,
    to_fixed_point,
    to_uint,
    to_wad,
)

BTC_EMPIRIC_ID = str_to_felt("BTC/USD")
BTC_INIT_PRICE = 19520
BTC_CEILING = to_wad(10_000_000)
BTC_THRESHOLD = 85 * RAY_PERCENT
BTC_DEPOSIT = to_fixed_point(10, 8)

ETH_EMPIRIC_ID = str_to_felt("ETH/USD")
ETH_INIT_PRICE = 1283
ETH_CEILING = to_wad(15_000_000)
ETH_THRESHOLD = 80 * RAY_PERCENT
ETH_DEPOSIT = to_wad(100)


def to_empiric(value: int) -> int:
    """
    Empiric reports the pairs used in this test suite with 8 decimals.
    This function converts a "regular" numeric value to an Empiric native
    one, i.e. as if it was returned from Empiric.
    """
    return value * (10**8)


#
# fixtures
#


@pytest.fixture
async def btc_token(tokens) -> StarknetContract:
    return await tokens("Bitcoin", "BTC", 8)


@pytest.fixture
async def eth_token(tokens) -> StarknetContract:
    return await tokens("Ether", "ETH", 18)


@pytest.fixture
async def btc_gate(starknet, shrine, sentinel, btc_token, gates) -> StarknetContract:
    gate = await gates(shrine, btc_token)
    await gate.grant_role(GATE_ROLE_FOR_SENTINEL, sentinel.contract_address).execute(caller_address=GATE_OWNER)
    return gate


@pytest.fixture
async def eth_gate(starknet, shrine, sentinel, eth_token, gates) -> StarknetContract:
    gate = await gates(shrine, eth_token)
    await gate.grant_role(GATE_ROLE_FOR_SENTINEL, sentinel.contract_address).execute(caller_address=GATE_OWNER)
    return gate


@pytest.fixture
async def with_btc(starknet, shrine, sentinel, empiric, btc_token, btc_gate, mock_empiric_impl):
    await mock_empiric_impl.next_get_spot_median(BTC_EMPIRIC_ID, 20_000, 8, 5000, 6).execute()

    await empiric.add_yang(BTC_EMPIRIC_ID, btc_token.contract_address).execute(caller_address=EMPIRIC_OWNER)

    await sentinel.add_yang(
        btc_token.contract_address, BTC_CEILING, BTC_THRESHOLD, to_wad(BTC_INIT_PRICE), btc_gate.contract_address
    ).execute(caller_address=SENTINEL_OWNER)


@pytest.fixture
async def with_yangs(starknet, shrine, sentinel, empiric, eth_token, eth_gate, mock_empiric_impl, with_btc):
    await mock_empiric_impl.next_get_spot_median(ETH_EMPIRIC_ID, 1300, 8, 5000, 6).execute()

    await empiric.add_yang(ETH_EMPIRIC_ID, eth_token.contract_address).execute(caller_address=EMPIRIC_OWNER)

    await sentinel.add_yang(
        eth_token.contract_address, ETH_CEILING, ETH_THRESHOLD, to_wad(ETH_INIT_PRICE), eth_gate.contract_address
    ).execute(caller_address=SENTINEL_OWNER)


@pytest.fixture
async def funded_gates(shrine, abbot, btc_token, eth_token, btc_gate, eth_gate, with_yangs):
    await btc_token.mint(TROVE1_OWNER, (BTC_DEPOSIT, 0)).execute(caller_address=TROVE1_OWNER)
    await eth_token.mint(TROVE1_OWNER, (ETH_DEPOSIT, 0)).execute(caller_address=TROVE1_OWNER)

    await max_approve(btc_token, TROVE1_OWNER, btc_gate.contract_address)
    await max_approve(eth_token, TROVE1_OWNER, eth_gate.contract_address)

    await abbot.open_trove(
        0,
        [btc_token.contract_address, eth_token.contract_address],
        [BTC_DEPOSIT, ETH_DEPOSIT],
    ).execute(caller_address=TROVE1_OWNER)


#
# tests
#


@pytest.mark.asyncio
async def test_setup(empiric, mock_empiric_impl):
    tx = empiric.deploy_call_info

    assert_event_emitted(tx, empiric.contract_address, "OracleAddressUpdated", [0, mock_empiric_impl.contract_address])
    assert_event_emitted(tx, empiric.contract_address, "UpdateIntervalUpdated", [0, EMPIRIC_UPDATE_INTERVAL])
    assert_event_emitted(
        tx,
        empiric.contract_address,
        "PriceValidityThresholdsUpdated",
        [0, 0, EMPIRIC_FRESHNESS_THRESHOLD, EMPIRIC_SOURCES_THRESHOLD],
    )

    admin_roles = (
        EmpiricRoles.ADD_YANG
        + EmpiricRoles.SET_ORACLE_ADDRESS
        + EmpiricRoles.SET_PRICE_VALIDITY_THRESHOLDS
        + EmpiricRoles.SET_UPDATE_INTERVAL
    )
    assert (await empiric.has_role(admin_roles, EMPIRIC_OWNER).execute()).result.has_role == 1


@pytest.mark.asyncio
async def test_set_price_validity_thresholds(empiric):
    new_freshness = 5 * 60
    new_sources = 8

    tx = await empiric.set_price_validity_thresholds(new_freshness, new_sources).execute(caller_address=EMPIRIC_OWNER)

    assert_event_emitted(
        tx,
        empiric.contract_address,
        "PriceValidityThresholdsUpdated",
        [EMPIRIC_FRESHNESS_THRESHOLD, EMPIRIC_SOURCES_THRESHOLD, new_freshness, new_sources],
    )


@pytest.mark.asyncio
async def test_set_price_validity_thresholds_failures(empiric):
    # test for freshness within bounds
    for bound in (EMPIRIC_LOWER_FRESHNESS_BOUND - 1, EMPIRIC_UPPER_FRESHNESS_BOUND + 1):
        with pytest.raises(StarkException, match="Empiric: Freshness threshold out of bounds"):
            await empiric.set_price_validity_thresholds(bound, EMPIRIC_SOURCES_THRESHOLD).execute(
                caller_address=EMPIRIC_OWNER
            )

    # test for sources within bounds
    for bound in (EMPIRIC_LOWER_SOURCES_BOUND - 1, EMPIRIC_UPPER_SOURCES_BOUND + 1):
        with pytest.raises(StarkException, match="Empiric: Sources threshold out of bounds"):
            await empiric.set_price_validity_thresholds(EMPIRIC_FRESHNESS_THRESHOLD, bound).execute(
                caller_address=EMPIRIC_OWNER
            )

    # test unauthorized setting of thresholds fails
    with pytest.raises(StarkException):
        await empiric.set_price_validity_thresholds(EMPIRIC_FRESHNESS_THRESHOLD, EMPIRIC_SOURCES_THRESHOLD).execute(
            caller_address=BAD_GUY
        )


@pytest.mark.asyncio
async def test_set_oracle_address(empiric, mock_empiric_impl):
    new_address = str_to_felt("new oracle")
    tx = await empiric.set_oracle_address(new_address).execute(caller_address=EMPIRIC_OWNER)
    assert_event_emitted(
        tx, empiric.contract_address, "OracleAddressUpdated", [mock_empiric_impl.contract_address, new_address]
    )


@pytest.mark.asyncio
async def test_set_oracle_address_failures(empiric):
    with pytest.raises(StarkException, match="Empiric: Address cannot be zero"):
        await empiric.set_oracle_address(0).execute(caller_address=EMPIRIC_OWNER)

    with pytest.raises(StarkException):
        await empiric.set_oracle_address(0xDEAD).execute(caller_address=BAD_GUY)


@pytest.mark.asyncio
async def test_set_update_interval(empiric):
    new_interval = EMPIRIC_UPDATE_INTERVAL * 2
    tx = await empiric.set_update_interval(new_interval).execute(caller_address=EMPIRIC_OWNER)
    assert_event_emitted(tx, empiric.contract_address, "UpdateIntervalUpdated", [EMPIRIC_UPDATE_INTERVAL, new_interval])


@pytest.mark.asyncio
async def test_set_update_interval_failures(empiric):
    for interval in (EMPIRIC_LOWER_UPDATE_INTERVAL_BOUND - 1, EMPIRIC_UPPER_UPDATE_INTERVAL_BOUND + 1):
        with pytest.raises(StarkException, match="Empiric: Update interval out of bounds"):
            await empiric.set_update_interval(interval).execute(caller_address=EMPIRIC_OWNER)

    with pytest.raises(StarkException):
        await empiric.set_update_interval(EMPIRIC_UPDATE_INTERVAL * 2).execute(caller_address=BAD_GUY)


@pytest.mark.asyncio
async def test_add_yang(eth_token, empiric, mock_empiric_impl):
    await mock_empiric_impl.next_get_spot_median(ETH_EMPIRIC_ID, 100, 8, 5000, 3).execute()
    tx = await empiric.add_yang(ETH_EMPIRIC_ID, eth_token.contract_address).execute(caller_address=EMPIRIC_OWNER)
    assert_event_emitted(tx, empiric.contract_address, "YangAdded", [0, ETH_EMPIRIC_ID, eth_token.contract_address])


@pytest.mark.asyncio
async def test_add_yang_failures(btc_token, eth_token, empiric, mock_empiric_impl):
    with pytest.raises(StarkException):
        await empiric.add_yang(ETH_EMPIRIC_ID, eth_token.contract_address).execute(caller_address=BAD_GUY)

    with pytest.raises(StarkException, match="Empiric: Invalid values"):
        await empiric.add_yang(0, eth_token.contract_address).execute(caller_address=EMPIRIC_OWNER)

    with pytest.raises(StarkException, match="Empiric: Invalid values"):
        await empiric.add_yang(ETH_EMPIRIC_ID, 0).execute(caller_address=EMPIRIC_OWNER)

    await mock_empiric_impl.next_get_spot_median(ETH_EMPIRIC_ID, 100, 0, 5000, 3).execute()
    with pytest.raises(StarkException, match="Empiric: Unknown pair ID"):
        await empiric.add_yang(ETH_EMPIRIC_ID, eth_token.contract_address).execute(caller_address=EMPIRIC_OWNER)

    await mock_empiric_impl.next_get_spot_median(ETH_EMPIRIC_ID, 100, 20, 5000, 3).execute()
    with pytest.raises(StarkException, match="Empiric: Feed with too many decimals"):
        await empiric.add_yang(ETH_EMPIRIC_ID, eth_token.contract_address).execute(caller_address=EMPIRIC_OWNER)

    await mock_empiric_impl.next_get_spot_median(BTC_EMPIRIC_ID, 100, 8, 5000, 3).execute()
    await empiric.add_yang(BTC_EMPIRIC_ID, btc_token.contract_address).execute(caller_address=EMPIRIC_OWNER)
    with pytest.raises(StarkException, match="Empiric: Yang already present"):
        await empiric.add_yang(BTC_EMPIRIC_ID, btc_token.contract_address).execute(caller_address=EMPIRIC_OWNER)


@pytest.mark.usefixtures("with_yangs", "funded_gates")
@pytest.mark.parametrize(
    "rebase_percentage", [Decimal("0"), Decimal("0.01"), Decimal("0.1"), Decimal("0.5"), Decimal("1")]
)
@pytest.mark.asyncio
async def test_update_prices(
    btc_token, eth_token, btc_gate, eth_gate, empiric, mock_empiric_impl, shrine, starknet, rebase_percentage
):
    # simulate rebase by sending tokens to the gate
    await btc_token.mint(btc_gate.contract_address, to_uint(int(rebase_percentage * BTC_DEPOSIT))).execute(
        caller_address=btc_gate.contract_address
    )
    await eth_token.mint(eth_gate.contract_address, to_uint(int(rebase_percentage * ETH_DEPOSIT))).execute(
        caller_address=eth_gate.contract_address
    )

    oracle_update_ts = INIT_BLOCK_TS + TIME_INTERVAL + 1  # ensuring the update is in the next interval
    oracle_update_interval = oracle_update_ts // TIME_INTERVAL

    price_multiplier = Decimal("1") + rebase_percentage

    # the multiplying by 2 here is because add_yang sets the
    # sentinel value in the interval _previous_ to current
    new_eth_price = 1293
    new_eth_yang_price = price_multiplier * new_eth_price
    eth_cumulative_price = ETH_INIT_PRICE * 2 + new_eth_yang_price

    new_btc_price = 19330
    new_btc_yang_price = price_multiplier * new_btc_price
    btc_cumulative_price = BTC_INIT_PRICE * 2 + new_btc_yang_price

    await mock_empiric_impl.next_get_spot_median(
        ETH_EMPIRIC_ID, to_empiric(new_eth_price), 8, oracle_update_ts, 3
    ).execute()
    await mock_empiric_impl.next_get_spot_median(
        BTC_EMPIRIC_ID, to_empiric(new_btc_price), 8, oracle_update_ts, 4
    ).execute()

    set_block_timestamp(starknet, oracle_update_ts)
    caller = str_to_felt("yagi")
    tx = await empiric.update_prices().execute(caller_address=caller)
    assert_event_emitted(tx, empiric.contract_address, "PricesUpdated", [oracle_update_ts, caller])
    assert_event_emitted(
        tx,
        shrine.contract_address,
        "YangPriceUpdated",
        [eth_token.contract_address, to_wad(new_eth_yang_price), to_wad(eth_cumulative_price), oracle_update_interval],
    )
    assert_event_emitted(
        tx,
        shrine.contract_address,
        "YangPriceUpdated",
        [btc_token.contract_address, to_wad(new_btc_yang_price), to_wad(btc_cumulative_price), oracle_update_interval],
    )

    assert (
        await shrine.get_yang_price(eth_token.contract_address, oracle_update_interval).execute()
    ).result.price == to_wad(new_eth_yang_price)
    assert (
        await shrine.get_yang_price(btc_token.contract_address, oracle_update_interval).execute()
    ).result.price == to_wad(new_btc_yang_price)


@pytest.mark.asyncio
async def test_update_prices_without_yangs(empiric):
    # just to test the module works well even if no yangs were added yet
    caller = str_to_felt("yagi")
    tx = await empiric.update_prices().execute(caller_address=caller)
    assert_event_emitted(tx, empiric.contract_address, "PricesUpdated", [INIT_BLOCK_TS, caller])


@pytest.mark.usefixtures("with_yangs")
@pytest.mark.asyncio
async def test_update_prices_update_too_soon_failure(empiric, mock_empiric_impl, starknet):
    await mock_empiric_impl.next_get_spot_median(
        ETH_EMPIRIC_ID, to_empiric(ETH_INIT_PRICE), 8, INIT_BLOCK_TS, 3
    ).execute()

    # first update should pass
    await empiric.update_prices().execute()

    # second update that's happening too soon should not pass
    set_block_timestamp(starknet, INIT_BLOCK_TS + 1)
    with pytest.raises(StarkException, match="Empiric: Too soon to update prices"):
        await empiric.update_prices().execute()


# first parametrization checks for negative value price udpate
# second for insufficient number of sources,
# third for stale price update (too much in the past)
@pytest.mark.parametrize("price, ts_diff, num_sources", [(-20, 0, 5), (1300, 0, 1), (1300, 24 * 3600, 4)])
@pytest.mark.usefixtures("with_yangs")
@pytest.mark.asyncio
async def test_update_prices_invalid_price_updates(eth_token, empiric, mock_empiric_impl, price, ts_diff, num_sources):
    update_ts = INIT_BLOCK_TS - ts_diff

    await mock_empiric_impl.next_get_spot_median(ETH_EMPIRIC_ID, to_empiric(price), 8, update_ts, num_sources).execute()

    tx = await empiric.update_prices().execute()
    assert_event_emitted(
        tx,
        empiric.contract_address,
        "InvalidPriceUpdate",
        [
            eth_token.contract_address,
            signed_int_to_felt(to_wad(price)),
            update_ts,
            num_sources,
            INITIAL_ASSET_AMT_PER_YANG,
        ],
    )


# yang has not been added to Sentinel
@pytest.mark.usefixtures("with_btc")
@pytest.mark.asyncio
async def test_update_prices_invalid_gate(starknet, shrine, eth_token, empiric, mock_empiric_impl):
    # Add ETH to empiric but not Sentinel
    await mock_empiric_impl.next_get_spot_median(ETH_EMPIRIC_ID, 1300, 8, 5000, 6).execute()

    await empiric.add_yang(ETH_EMPIRIC_ID, eth_token.contract_address).execute(caller_address=EMPIRIC_OWNER)

    oracle_update_ts = INIT_BLOCK_TS + TIME_INTERVAL + 1  # ensuring the update is in the next interval

    # the multiplying by 2 here is because add_yang sets the
    # sentinel value in the interval _previous_ to current
    num_eth_sources = 3
    new_eth_price = new_eth_yang_price = 1293

    await mock_empiric_impl.next_get_spot_median(
        ETH_EMPIRIC_ID, to_empiric(new_eth_price), 8, oracle_update_ts, num_eth_sources
    ).execute()

    set_block_timestamp(starknet, oracle_update_ts)
    caller = str_to_felt("yagi")
    tx = await empiric.update_prices().execute(caller_address=caller)
    assert_event_emitted(tx, empiric.contract_address, "PricesUpdated", [oracle_update_ts, caller])

    INVALID_ASSET_AMT_PER_YANG = 0
    assert_event_emitted(
        tx,
        empiric.contract_address,
        "InvalidPriceUpdate",
        [
            eth_token.contract_address,
            to_wad(new_eth_yang_price),
            oracle_update_ts,
            num_eth_sources,
            INVALID_ASSET_AMT_PER_YANG,
        ],
    )


@pytest.mark.usefixtures("with_yangs")
@pytest.mark.asyncio
async def test_probeTask(empiric, mock_empiric_impl, starknet):
    # initially, empiric_last_price_update is 0, so probeTask should return true
    assert (await empiric.probeTask().execute()).result.is_task_ready == 1

    new_ts = INIT_BLOCK_TS + 1
    set_block_timestamp(starknet, new_ts)
    await mock_empiric_impl.next_get_spot_median(
        ETH_EMPIRIC_ID, to_empiric(ETH_INIT_PRICE + 30), 8, new_ts, 3
    ).execute()
    await empiric.update_prices().execute()

    # after update_prices, the last update ts is moved to current block ts
    # as well, so calling probeTask in the same block afterwards should
    # return false
    assert (await empiric.probeTask().execute()).result.is_task_ready == 0

    # moving the block time forward to the next time interval, probeTask
    # should again return true
    set_block_timestamp(starknet, new_ts + TIME_INTERVAL + 1)
    assert (await empiric.probeTask().execute()).result.is_task_ready == 1
