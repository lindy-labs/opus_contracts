from decimal import Decimal

import pytest
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
)
from tests.roles import EmpiricRoles
from tests.utils import (
    BAD_GUY,
    EMPIRIC_OWNER,
    SHRINE_OWNER,
    TIME_INTERVAL,
    assert_event_emitted,
    set_block_timestamp,
    str_to_felt,
    to_wad,
)

BTC_EMPIRIC_ID = str_to_felt("BTC/USD")
BTC_YANG = str_to_felt("btc")
BTC_INIT_PRICE = 19520

ETH_EMPIRIC_ID = str_to_felt("ETH/USD")
ETH_YANG = str_to_felt("eth")
ETH_INIT_PRICE = 1283


def to_empiric(value: int) -> int:
    """
    Empiric reports the pairs used in this test suite with 8 decimals.
    This function converts a "regular" numeric value to an Emipric native
    one, i.e. as if it was returned from Empiric.
    """
    return value * (10**8)


@pytest.fixture
async def with_yangs(shrine, empiric):
    await empiric.add_yang(ETH_EMPIRIC_ID, ETH_YANG).execute(caller_address=EMPIRIC_OWNER)
    await empiric.add_yang(BTC_EMPIRIC_ID, BTC_YANG).execute(caller_address=EMPIRIC_OWNER)

    await shrine.add_yang(ETH_YANG, 100_000_000, to_wad(Decimal("0.9")), to_wad(ETH_INIT_PRICE)).execute(
        caller_address=SHRINE_OWNER
    )
    await shrine.add_yang(BTC_YANG, 100_000_000, to_wad(Decimal("0.85")), to_wad(BTC_INIT_PRICE)).execute(
        caller_address=SHRINE_OWNER
    )


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
        with pytest.raises(StarkException, match="Empiric: freshness threshold out of bounds"):
            await empiric.set_price_validity_thresholds(bound, EMPIRIC_SOURCES_THRESHOLD).execute(
                caller_address=EMPIRIC_OWNER
            )

    # test for sources within bounds
    for bound in (EMPIRIC_LOWER_SOURCES_BOUND - 1, EMPIRIC_UPPER_SOURCES_BOUND + 1):
        with pytest.raises(StarkException, match="Empiric: sources threshold out of bounds"):
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
    with pytest.raises(StarkException, match="Empiric: address cannot be zero"):
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
        with pytest.raises(StarkException, match="Empiric: update interval out of bounds"):
            await empiric.set_update_interval(interval).execute(caller_address=EMPIRIC_OWNER)

    with pytest.raises(StarkException):
        await empiric.set_update_interval(EMPIRIC_UPDATE_INTERVAL * 2).execute(caller_address=BAD_GUY)


@pytest.mark.asyncio
async def test_add_yang(empiric):
    tx = await empiric.add_yang(ETH_EMPIRIC_ID, ETH_YANG).execute(caller_address=EMPIRIC_OWNER)
    assert_event_emitted(tx, empiric.contract_address, "YangAdded", [0, ETH_EMPIRIC_ID, ETH_YANG])


@pytest.mark.asyncio
async def test_add_yang_failures(empiric, mock_empiric_impl):
    with pytest.raises(StarkException, match="Empiric: invalid values"):
        await empiric.add_yang(0, ETH_YANG).execute(caller_address=EMPIRIC_OWNER)

    with pytest.raises(StarkException, match="Empiric: invalid values"):
        await empiric.add_yang(ETH_EMPIRIC_ID, 0).execute(caller_address=EMPIRIC_OWNER)

    with pytest.raises(StarkException):
        await empiric.add_yang(ETH_EMPIRIC_ID, ETH_YANG).execute(caller_address=BAD_GUY)

    await mock_empiric_impl.next_get_spot_median(ETH_EMPIRIC_ID, 100, 20, 5000, 3).execute()
    with pytest.raises(StarkException, match="Empiric: feed with too many decimals"):
        await empiric.add_yang(ETH_EMPIRIC_ID, ETH_YANG).execute(caller_address=EMPIRIC_OWNER)

    await empiric.add_yang(BTC_EMPIRIC_ID, BTC_YANG).execute(caller_address=EMPIRIC_OWNER)
    with pytest.raises(StarkException, match="Empiric: yang already present"):
        await empiric.add_yang(BTC_EMPIRIC_ID, BTC_YANG).execute(caller_address=EMPIRIC_OWNER)


@pytest.mark.usefixtures("with_yangs")
@pytest.mark.asyncio
async def test_update_prices(empiric, mock_empiric_impl, shrine, starknet):
    oracle_update_ts = INIT_BLOCK_TS + TIME_INTERVAL + 1  # ensuring the update is in the next interval
    oracle_update_interval = oracle_update_ts // TIME_INTERVAL

    # the multiplying by 2 here is because add_yang sets the
    # sentinel value in the interval _previous_ to current
    new_eth_price = 1293
    eth_cumulative_price = ETH_INIT_PRICE * 2 + new_eth_price
    new_btc_price = 19330
    btc_cumulative_price = BTC_INIT_PRICE * 2 + new_btc_price

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
        [ETH_YANG, to_wad(new_eth_price), to_wad(eth_cumulative_price), oracle_update_interval],
    )
    assert_event_emitted(
        tx,
        shrine.contract_address,
        "YangPriceUpdated",
        [BTC_YANG, to_wad(new_btc_price), to_wad(btc_cumulative_price), oracle_update_interval],
    )

    assert (await shrine.get_yang_price(ETH_YANG, oracle_update_interval).execute()).result.price == to_wad(
        new_eth_price
    )
    assert (await shrine.get_yang_price(BTC_YANG, oracle_update_interval).execute()).result.price == to_wad(
        new_btc_price
    )


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
    with pytest.raises(StarkException, match="Empiric: too soon to update prices"):
        await empiric.update_prices().execute()


# first parametrization check for insufficient number of sources,
# second for stale price update (too much in the past)
@pytest.mark.parametrize("ts_diff, num_sources", [(0, 1), (24 * 3600, 4)])
@pytest.mark.asyncio
async def test_update_prices_invalid_price_updates(empiric, mock_empiric_impl, starknet, ts_diff, num_sources):
    update_price = 1300
    update_ts = INIT_BLOCK_TS - ts_diff

    await empiric.add_yang(ETH_EMPIRIC_ID, ETH_YANG).execute(caller_address=EMPIRIC_OWNER)

    await mock_empiric_impl.next_get_spot_median(
        ETH_EMPIRIC_ID, to_empiric(update_price), 8, update_ts, num_sources
    ).execute()

    tx = await empiric.update_prices().execute()
    assert_event_emitted(
        tx,
        empiric.contract_address,
        "InvalidPriceUpdate",
        [ETH_YANG, to_wad(update_price), update_ts, num_sources],
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
