# TODO:
# * test for when deposit can't go through (e.g. max_mint == 0)
# * test calculate_max_mint_amount
from decimal import Decimal
from math import floor

import pytest
from starkware.starknet.testing.contract import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.utils import (
    MAX_UINT256,
    Uint256,
    assert_event_emitted,
    compile_contract,
    felt_to_str,
    from_uint,
    str_to_felt,
    to_uint,
)

RESERVE_ADDR = 1
TREASURY_ADDR = 2
STABILITY_FEE = 100
THRESHOLD_BUFFER = 2000  # 20%
HUNDRED_PERCENT_BPS = 10_000

#
# fixtures
#


# parametrized fixture used to emulate stablecoins allowed
# in the direct deposit contract
@pytest.fixture(params=[("DAI", 18), ("USDC", 6)], ids=["DAI", "USDC"])
async def dd_stablecoin(request, tokens) -> StarknetContract:
    ten_billy = 10**10
    token, decimals = request.param
    owner = str_to_felt(f"{token.lower()} owner")
    return await tokens(f"Test {token}", f"t{token}", decimals, (ten_billy, 0), owner)


# fixture returns the deployed direct deposit module together
# with its associated stablecoin mock ERC20
@pytest.fixture
async def direct_deposit(starknet, usda, dd_stablecoin) -> tuple[StarknetContract, StarknetContract]:
    dd_owner = str_to_felt("dd owner")
    dd_contract = compile_contract("contracts/DD/DD.cairo")

    dd = await starknet.deploy(
        contract_class=dd_contract,
        constructor_calldata=[
            dd_owner,
            dd_stablecoin.contract_address,
            usda.contract_address,
            RESERVE_ADDR,
            TREASURY_ADDR,
            STABILITY_FEE,
            THRESHOLD_BUFFER,
        ],
    )

    return dd, dd_stablecoin


#
# tests
#


@pytest.mark.asyncio
async def test_deposit(direct_deposit, usda):
    dd, stablecoin = direct_deposit
    stable_symbol = felt_to_str((await stablecoin.symbol().execute()).result.symbol)
    depositor = str_to_felt(f"{stable_symbol} depositor")

    usda_decimals = (await usda.decimals().execute()).result.decimals
    stable_decimals = (await stablecoin.decimals().execute()).result.decimals
    deposit_amount = 3983 * 10**stable_decimals

    # give some stablecoin to the actor
    await stablecoin.mint(depositor, to_uint(10000 * 10**stable_decimals)).execute()

    # allow Aura to take stable
    await stablecoin.approve(dd.contract_address, MAX_UINT256).execute(caller_address=depositor)

    # deposit stables into Aura
    tx = await dd.deposit(to_uint(deposit_amount)).execute(caller_address=depositor)
    assert_event_emitted(tx, dd.contract_address, "Deposit", [*to_uint(deposit_amount)])

    # DD module should hold the requested amount of stablecoin
    tx = await stablecoin.balanceOf(dd.contract_address).execute()
    assert tx.result.balance == to_uint(deposit_amount)

    # depositor should hold the requested amount minus stability fee
    # scaled to USDa decimals
    usda_scaled_deposit = deposit_amount * 10 ** (usda_decimals - stable_decimals)
    expected_depositor_balance = int(
        Decimal(usda_scaled_deposit * (HUNDRED_PERCENT_BPS - STABILITY_FEE)) / HUNDRED_PERCENT_BPS
    )

    tx = await usda.balanceOf(depositor).execute()
    assert tx.result.balance == to_uint(expected_depositor_balance)

    rest = usda_scaled_deposit - expected_depositor_balance
    # reserve should hold half of the rest, rounded down
    expected_reserve_amount = floor(rest / 2)
    tx = await usda.balanceOf(RESERVE_ADDR).execute()
    assert tx.result.balance == to_uint(expected_reserve_amount)

    # treasury should hold whatever else is left
    expected_treasury_amount = rest - expected_reserve_amount
    tx = await usda.balanceOf(TREASURY_ADDR).execute()
    assert tx.result.balance == to_uint(expected_treasury_amount)


@pytest.mark.asyncio
async def test_withdraw(direct_deposit, usda):
    dd, stablecoin = direct_deposit
    stable_symbol = felt_to_str((await stablecoin.symbol().execute()).result.symbol)
    ape = str_to_felt(f"{stable_symbol} ape")

    usda_decimals = (await usda.decimals().execute()).result.decimals
    stable_decimals = (await stablecoin.decimals().execute()).result.decimals
    amount = 5000 * 10**stable_decimals

    # give some stables to ape
    await stablecoin.mint(ape, to_uint(amount)).execute()

    # have them deposited to Aura via direct deposit
    await stablecoin.approve(dd.contract_address, MAX_UINT256).execute(caller_address=ape)
    await dd.deposit(to_uint(amount)).execute(caller_address=ape)
    tx = await usda.balanceOf(ape).execute()
    # check if, indeed, we got some USDa and have no more stables
    ape_usda_balance: Uint256 = tx.result.balance
    assert from_uint(ape_usda_balance) > 0
    assert (await stablecoin.balanceOf(ape).execute()).result.balance == to_uint(0)

    # now withdraw all of it back and check result
    # amount has to be in the scale of stablecoin
    withdraw_amount = int(Decimal(from_uint(ape_usda_balance)) / 10 ** (usda_decimals - stable_decimals))
    tx = await dd.withdraw(to_uint(withdraw_amount)).execute(caller_address=ape)
    assert_event_emitted(tx, dd.contract_address, "Withdrawal", [*to_uint(withdraw_amount)])
    assert (await usda.balanceOf(ape).execute()).result.balance == to_uint(0)
    assert (await stablecoin.balanceOf(ape).execute()).result.balance == to_uint(withdraw_amount)


@pytest.mark.asyncio
async def test_getters_setters(direct_deposit, usda):
    dd, stablecoin = direct_deposit
    dd_owner = str_to_felt("dd owner")
    rektooor = str_to_felt("rektooor")

    new_reserve_address = 42**2
    new_treasury_address = 42**3
    new_stability_fee = 40
    new_threshold_buffer = 4500

    # test getting and setting threshold buffer
    assert (await dd.get_threshold_buffer().execute()).result.value == THRESHOLD_BUFFER
    tx = await dd.set_threshold_buffer(new_threshold_buffer).execute(caller_address=dd_owner)

    assert_event_emitted(
        tx,
        dd.contract_address,
        "ThresholdBufferChange",
        [THRESHOLD_BUFFER, new_threshold_buffer],
    )
    assert (await dd.get_threshold_buffer().execute()).result.value == new_threshold_buffer
    # test setting the limits
    min_threshold_buffer = 500
    max_threshold_buffer = 10_000
    await dd.set_threshold_buffer(min_threshold_buffer).execute(caller_address=dd_owner)
    await dd.set_threshold_buffer(max_threshold_buffer).execute(caller_address=dd_owner)

    with pytest.raises(StarkException):
        await dd.set_threshold_buffer(min_threshold_buffer - 1).execute(caller_address=dd_owner)
    with pytest.raises(StarkException):
        await dd.set_threshold_buffer(max_threshold_buffer + 1).execute(caller_address=dd_owner)
    with pytest.raises(StarkException):
        await dd.set_threshold_buffer(THRESHOLD_BUFFER).execute(caller_address=rektooor)

    # tests getting and setting reserve address
    assert (await dd.get_reserve_address().execute()).result.addr == RESERVE_ADDR
    tx = await dd.set_reserve_address(new_reserve_address).execute(caller_address=dd_owner)
    assert_event_emitted(
        tx,
        dd.contract_address,
        "ReserveAddressChange",
        [RESERVE_ADDR, new_reserve_address],
    )
    assert (await dd.get_reserve_address().execute()).result.addr == new_reserve_address
    with pytest.raises(StarkException):
        await dd.set_reserve_address(rektooor).execute(caller_address=rektooor)
    with pytest.raises(StarkException):
        await dd.set_reserve_address(0).execute(caller_address=dd_owner)

    # test getting and setting treasury address
    assert (await dd.get_treasury_address().execute()).result.addr == TREASURY_ADDR
    tx = await dd.set_treasury_address(new_treasury_address).execute(caller_address=dd_owner)
    assert_event_emitted(
        tx,
        dd.contract_address,
        "TreasuryAddressChange",
        [TREASURY_ADDR, new_treasury_address],
    )
    assert (await dd.get_treasury_address().execute()).result.addr == new_treasury_address
    with pytest.raises(StarkException):
        await dd.set_treasury_address(rektooor).execute(caller_address=rektooor)
    with pytest.raises(StarkException):
        await dd.set_treasury_address(0).execute(caller_address=dd_owner)

    # test getting and setting stability fee
    assert (await dd.get_stability_fee().execute()).result.fee == STABILITY_FEE
    tx = await dd.set_stability_fee(new_stability_fee).execute(caller_address=dd_owner)
    assert_event_emitted(
        tx,
        dd.contract_address,
        "StabilityFeeChange",
        [STABILITY_FEE, new_stability_fee],
    )
    assert (await dd.get_stability_fee().execute()).result.fee == new_stability_fee
    with pytest.raises(StarkException):
        await dd.set_stability_fee(1200).execute(caller_address=rektooor)
    with pytest.raises(StarkException):
        await dd.set_stability_fee(11_000).execute(caller_address=dd_owner)

    # test getting stablecoin address
    assert (await dd.get_stablecoin_address().execute()).result.addr == stablecoin.contract_address

    # test getting usda address
    assert (await dd.get_usda_address().execute()).result.addr == usda.contract_address

    # test getting and setting owner
    new_owner = str_to_felt("new dd owner")
    assert (await dd.get_owner_address().execute()).result.addr == dd_owner
    tx = await dd.set_owner(new_owner).execute(caller_address=dd_owner)
    assert_event_emitted(tx, dd.contract_address, "OwnershipTransferred", [dd_owner, new_owner])
    assert (await dd.get_owner_address().execute()).result.addr == new_owner
    with pytest.raises(StarkException):
        await dd.set_owner(rektooor).execute(caller_address=rektooor)
