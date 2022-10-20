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


def to_empiric(value: int) -> int:
    """
    Empiric reports the pairs used in this test suite with 8 decimals.
    This function converts a "regular" numeric value to an Emipric native
    one, i.e. as if it was returned from Empiric.
    """
    return value * (10**8)


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

    tx = await empiric.set_price_validity_thresholds(new_freshness, new_sources).execute()

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
    empiric_id = str_to_felt("ETH/USD")
    yang = str_to_felt("eth")

    tx = await empiric.add_yang(empiric_id, yang).execute(caller_address=EMPIRIC_OWNER)
    assert_event_emitted(tx, empiric.contract_address, "YangAdded", [0, empiric_id, yang])


@pytest.mark.asyncio
async def test_add_yang_failures(empiric, mock_empiric_impl):
    with pytest.raises(StarkException, match="Empiric: invalid values"):
        await empiric.add_yang(0, str_to_felt("eth")).execute(caller_address=EMPIRIC_OWNER)

    pair_id = str_to_felt("ETH/USD")

    with pytest.raises(StarkException, match="Empiric: invalid values"):
        await empiric.add_yang(pair_id, 0).execute(caller_address=EMPIRIC_OWNER)

    with pytest.raises(StarkException):
        await empiric.add_yang(pair_id, str_to_felt("eth")).execute(caller_address=BAD_GUY)

    await mock_empiric_impl.next_get_spot_median(pair_id, 100, 20, 5000, 3).execute()
    with pytest.raises(StarkException, match="Empiric: feed with too many decimals"):
        await empiric.add_yang(pair_id, str_to_felt("eth")).execute(caller_address=EMPIRIC_OWNER)


# TODO: parametrize - have values go up only or down only
@pytest.mark.asyncio
async def test_update_prices(empiric, mock_empiric_impl, shrine, starknet):
    init_block_ts = 1666000000
    set_block_timestamp(starknet, init_block_ts)
    oracle_update_ts = init_block_ts + TIME_INTERVAL + 1  # ensuring the update is in the next interval
    oracle_update_interval = oracle_update_ts // TIME_INTERVAL

    eth_addr = str_to_felt("eth")
    eth_pair_id = str_to_felt("ETH/USD")
    init_eth_price = 1283
    new_eth_price = 1293
    eth_cumulative_price = init_eth_price + new_eth_price

    btc_addr = str_to_felt("btc")
    btc_pair_id = str_to_felt("BTC/USD")
    init_btc_price = 19520
    new_btc_price = 19600
    btc_cumulative_price = init_btc_price + new_btc_price

    await empiric.add_yang(eth_pair_id, eth_addr).execute(caller_address=EMPIRIC_OWNER)
    await empiric.add_yang(btc_pair_id, btc_addr).execute(caller_address=EMPIRIC_OWNER)

    await shrine.add_yang(eth_addr, 100_000_000, to_wad(Decimal("0.9")), to_wad(init_eth_price)).execute(
        caller_address=SHRINE_OWNER
    )
    await shrine.add_yang(btc_addr, 100_000_000, to_wad(Decimal("0.85")), to_wad(init_btc_price)).execute(
        caller_address=SHRINE_OWNER
    )

    await mock_empiric_impl.next_get_spot_median(
        eth_pair_id, to_empiric(new_eth_price), 8, oracle_update_ts, 3
    ).execute()
    await mock_empiric_impl.next_get_spot_median(
        btc_pair_id, to_empiric(new_btc_price), 8, oracle_update_ts, 4
    ).execute()

    set_block_timestamp(starknet, oracle_update_ts)
    tx = await empiric.update_prices().execute()
    assert_event_emitted(tx, empiric.contract_address, "PricesUpdated", [oracle_update_ts])
    assert_event_emitted(
        tx,
        shrine.contract_address,
        "YangPriceUpdated",
        [eth_addr, to_wad(new_eth_price), to_wad(eth_cumulative_price), oracle_update_interval],
    )
    assert_event_emitted(
        tx,
        shrine.contract_address,
        "YangPriceUpdated",
        [btc_addr, to_wad(new_btc_price), to_wad(btc_cumulative_price), oracle_update_interval],
    )

    assert (await shrine.get_yang_price(eth_addr, oracle_update_interval).execute()).result.price == to_wad(
        new_eth_price
    )
    assert (await shrine.get_yang_price(btc_addr, oracle_update_interval).execute()).result.price == to_wad(
        new_btc_price
    )


@pytest.mark.asyncio
async def test_update_prices_update_too_soon_failure(empiric, mock_empiric_impl, shrine, starknet):
    init_block_ts = 1666000000
    set_block_timestamp(starknet, init_block_ts)
    next_block_ts = init_block_ts + 1

    eth_addr = str_to_felt("eth")
    eth_pair_id = str_to_felt("ETH/USD")
    init_eth_price = 1283

    await empiric.add_yang(eth_pair_id, eth_addr).execute(caller_address=EMPIRIC_OWNER)
    await shrine.add_yang(eth_addr, 100_000_000, to_wad(Decimal("0.9")), to_wad(init_eth_price)).execute(
        caller_address=SHRINE_OWNER
    )
    await mock_empiric_impl.next_get_spot_median(
        eth_pair_id, to_empiric(init_eth_price + 1), 8, next_block_ts, 3
    ).execute()

    set_block_timestamp(starknet, next_block_ts)
    with pytest.raises(StarkException, match="Empiric: too soon to update prices"):
        await empiric.update_prices().execute()


@pytest.mark.asyncio
async def test_udpate_prices_invalid_price_updates():
    pass


# test_probeTask - for yes and no

# test for trying to update a price of a just added yang within the same Shrine's interval
