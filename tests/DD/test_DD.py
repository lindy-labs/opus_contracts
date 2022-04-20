from math import floor

import pytest
from starkware.starkware_utils.error_handling import StarkException

from utils import MAX_UINT256, to_uint, assert_event_emitted


@pytest.mark.asyncio
async def test_deposit(direct_deposit, usda, users):
    dd, stablecoin = direct_deposit
    dd_owner = await users("dd owner")
    depositor = await users("depositor")

    reserve_address = 42 ** 2
    treasury_address = 42 ** 3
    deposit_amount = 3983
    stability_fee = 40  # 40 bps = 0.4%

    await dd_owner.send_txs(
        [
            (dd, "set_reserve_address", [reserve_address]),
            (dd, "set_treasury_address", [treasury_address]),
            (dd, "set_stability_fee", [stability_fee]),  # 40 bps == 0.4%
        ]
    )

    # give some stablecoin to the actor
    await stablecoin.mint(depositor.address, to_uint(10000)).invoke()

    # allow Aura to take stable
    await depositor.send_tx(
        stablecoin.contract_address, "approve", [dd.contract_address, *MAX_UINT256]
    )

    # deposit stables into Aura
    await depositor.send_tx(dd.contract_address, "deposit", [*to_uint(deposit_amount)])

    # DD module should hold the requested amount of stablecoin
    tx = await stablecoin.balanceOf(dd.contract_address).invoke()
    assert tx.result.balance == to_uint(deposit_amount)

    # depositor should hold the requested amount minus stability fee
    expected_depositor_balance = floor(deposit_amount * ((10_000 - stability_fee) / 10_000))
    tx = await usda.balanceOf(depositor.address).invoke()
    assert tx.result.balance == to_uint(expected_depositor_balance)

    rest = deposit_amount - expected_depositor_balance
    # reserve should hold half of the rest, rounded down
    expected_reserve_amount = floor(rest / 2)
    tx = await usda.balanceOf(reserve_address).invoke()
    assert tx.result.balance == to_uint(expected_reserve_amount)

    # treasury should hold whatever else is left
    expected_treasury_amount = rest - expected_reserve_amount
    tx = await usda.balanceOf(treasury_address).invoke()
    assert tx.result.balance == to_uint(expected_treasury_amount)


@pytest.mark.asyncio
async def test_getters_setters(direct_deposit, usda, users):
    dd, stablecoin = direct_deposit
    dd_owner = await users("dd owner")
    rektooor = await users("rektooor")

    # magic consts from conftest.py fixutre when contract is deployed
    current_reserve_address = 1
    current_treasury_address = 2
    current_stability_fee = 200

    reserve_address = 42 ** 2
    treasury_address = 42 ** 3

    # TODO: test for emitted events on setters

    # tests getting and setting reserve address
    assert (await dd.get_reserve_address().invoke()).result.addr == current_reserve_address
    tx = await dd_owner.send_tx(dd, "set_reserve_address", [reserve_address])
    assert_event_emitted(tx, dd.contract_address, "ReserveAddressChange", [current_reserve_address, reserve_address])
    assert (await dd.get_reserve_address().invoke()).result.addr == reserve_address
    with pytest.raises(StarkException):
        await rektooor.send_tx(dd, "set_reserve_address", [rektooor.address])
    with pytest.raises(StarkException):
        await dd_owner.send_tx(dd, "set_reserve_address", [0])

    # test getting and setting treasury address
    assert (await dd.get_treasury_address().invoke()).result.addr == current_treasury_address
    tx = await dd_owner.send_tx(dd, "set_treasury_address", [treasury_address])
    assert_event_emitted(tx, dd.contract_address, "TreasuryAddressChange", [current_treasury_address, treasury_address])
    assert (await dd.get_treasury_address().invoke()).result.addr == treasury_address
    with pytest.raises(StarkException):
        await rektooor.send_tx(dd, "set_treasury_address", [rektooor.address])
    with pytest.raises(StarkException):
        await dd_owner.send_tx(dd, "set_treasury_address", [0])

    # test getting and setting stability fee
    assert (await dd.get_stability_fee().invoke()).result.fee == current_stability_fee
    tx = await dd_owner.send_tx(dd, "set_stability_fee", [400])
    assert_event_emitted(tx, dd.contract_address, "StabilityFeeChange", [current_stability_fee, 400])
    assert (await dd.get_stability_fee().invoke()).result.fee == 400
    with pytest.raises(StarkException):
        await rektooor.send_tx(dd, "set_stability_fee", [1200])
    with pytest.raises(StarkException):
        await dd_owner.send_tx(dd, "set_stability_fee", [11_000])

    # test getting stablecoin address
    assert (await dd.get_stablecoin_address().invoke()).result.addr == stablecoin.contract_address

    # test getting usda address
    assert (await dd.get_usda_address().invoke()).result.addr == usda.contract_address

    # test getting and setting owner
    new_owner = await users("new dd owner")
    assert (await dd.get_owner_address().invoke()).result.addr == dd_owner.address
    tx = await dd_owner.send_tx(dd, "set_owner", [new_owner.address])
    assert_event_emitted(tx, dd.contract_address, "OwnerChange", [dd_owner.address, new_owner.address])
    assert (await dd.get_owner_address().invoke()).result.addr == new_owner.address
    with pytest.raises(StarkException):
        await rektooor.send_tx(dd, "set_owner", [rektooor.address])
