import pytest

from decimal import Decimal

from tests.purger.test_purger import purger, advance_yang_prices_by_percentage, aura_user_with_first_trove
from tests.purger.constants import *
from tests.stability_pool.constants import *

from tests.utils import (
    AURA_USER,
    TROVE_1,
    STETH_OWNER,
    DOGE_OWNER,
    SHRINE_OWNER,
    compile_contract,
    calculate_max_forge,
    max_approve,
    w2d_assert
)

async def open_trove(
    user,
    shrine,
    abbot,
    steth_yang,
    doge_yang,
    steth_wad,
    doge_wad,
) -> int:
    """
    Given a user, opens a Trove with the constants amounts defined in purger/constants.py.
    """
    # Get stETH price
    steth_price = (await shrine.get_current_yang_price(steth_yang.contract_address).execute()).result.price_wad

    # Get Doge price
    doge_price = (await shrine.get_current_yang_price(doge_yang.contract_address).execute()).result.price_wad

    # Get maximum forge amount
    prices = [steth_price, doge_price]
    amounts = [steth_wad, doge_wad]
    thresholds = [steth_yang.threshold, doge_yang.threshold]
    max_forge_amt = calculate_max_forge(prices, amounts, thresholds)

    forge_amt = to_wad(max_forge_amt - 1)

    await abbot.open_trove(
        forge_amt,
        [steth_yang.contract_address, doge_yang.contract_address],
        [steth_wad, doge_wad],
    ).execute(caller_address=user)

    return forge_amt

async def fund_user(user, steth_yang, doge_yang, steth_token, doge_token, steth_amount, doge_amount):
    """
    Funds a `user` by sending steth and doge tokens from AURA_USER.
    """
    await steth_token.transfer(user, (steth_amount, 0)).execute(caller_address=AURA_USER)
    await doge_token.transfer(user, (doge_amount, 0)).execute(caller_address=AURA_USER)
    await max_approve(steth_token, user, steth_yang.gate_address)
    await max_approve(doge_token, user, doge_yang.gate_address)

    
@pytest.fixture
async def deployed_pool(request, shrine, yin, purger, starknet):
    pool_contract = compile_contract("contracts/stability_pool/stability_pool.cairo", request)
    pool = await starknet.deploy(
        contract_class=pool_contract,
        constructor_calldata=[yin.contract_address, shrine.contract_address, purger.contract_address],
    )
    new_ceiling = to_wad(100_000_000)
    await shrine.set_ceiling(new_ceiling).execute(caller_address=SHRINE_OWNER)
    return pool

@pytest.mark.usefixtures(
    "abbot_with_yangs",
    "funded_aura_user",
    "aura_user_with_first_trove"
)
@pytest.mark.asyncio
async def test_provide(deployed_pool, yin, aura_user_with_first_trove):
    """
    The user already opened a Trove and is depositing his Yin into the SP.
    Ensures the compounded deposit at t=0 is correct.
    """
    pool = deployed_pool
    amount = aura_user_with_first_trove
    await yin.approve(pool.contract_address, amount).execute(caller_address=AURA_USER)
    await pool.provide(amount).execute(caller_address=AURA_USER)
    deposit = (await pool.get_provider_owed_yin(AURA_USER).execute()).result.yin
    pool_balance = (await yin.balanceOf(pool.contract_address).execute()).result.wad
    assert deposit == amount
    assert pool_balance == amount


@pytest.mark.usefixtures(
    "abbot_with_yangs",
    "funded_aura_user",
    "aura_user_with_first_trove"
)
@pytest.mark.asyncio
async def test_liquidate(
    starknet,
    shrine,
    abbot,
    purger,
    deployed_pool,
    yin,
    steth_yang,
    doge_yang,
    steth_token,
    doge_token,
    aura_user_with_first_trove):
    """
    The SP is used to absorb a Trove's debt.

    The providers compounded deposits should be lower than the initial deposit.
    """
    pool = deployed_pool
    amount = aura_user_with_first_trove
    # Funds an extra user
    await fund_user(USER_2, steth_yang, doge_yang, steth_token, doge_token, USER_2_STETH_DEPOSIT_WAD, USER_2_DOGE_DEPOSIT_WAD)
    user2_forged_amount = await open_trove(USER_2, shrine, abbot, steth_yang, doge_yang, USER_2_STETH_DEPOSIT_WAD, USER_2_DOGE_DEPOSIT_WAD)

    await yin.approve(pool.contract_address, amount).execute(caller_address=AURA_USER)
    await pool.provide(amount).execute(caller_address=AURA_USER)

    # user2 provides as well
    await yin.approve(pool.contract_address, user2_forged_amount).execute(caller_address=USER_2)
    await pool.provide(user2_forged_amount).execute(caller_address=USER_2)

    # At this point, AURA_USER and user2 have the same amount of Yin in the SP
    aura_user_ratio = amount / (amount + user2_forged_amount)
    pool_balance = (await yin.balanceOf(pool.contract_address).execute()).result.wad

    # prices change, trove becomes totally liquidatable
    await advance_yang_prices_by_percentage(starknet, shrine, [steth_yang, doge_yang], Decimal("-0.5"))
    expected_max_close_amnt = (await purger.get_max_close_amount(TROVE_1).execute()).result.wad
    assert amount == expected_max_close_amnt

    # absorb trove's debt
    await pool.liquidate(TROVE_1).execute(caller_address=AURA_USER)
    # pool's liquidity should be decreased by the amount of debt absorbed
    new_pool_balance = (await yin.balanceOf(pool.contract_address).execute()).result.wad
    assert new_pool_balance == pool_balance - expected_max_close_amnt

    # both users should see their deposits decreased by 66%
    aura_user_deposit = (await pool.get_provider_owed_yin(AURA_USER).execute()).result.yin
    user2_deposit = (await pool.get_provider_owed_yin(USER_2).execute()).result.yin
    w2d_assert(aura_user_deposit, amount * (1-aura_user_ratio))
    w2d_assert(user2_deposit, user2_forged_amount * (1-aura_user_ratio))


    # someone deposit **after** the liquidation
    await fund_user(USER_3, steth_yang, doge_yang, steth_token, doge_token, USER_3_STETH_DEPOSIT_WAD, USER_3_DOGE_DEPOSIT_WAD)
    user3_forged_amount = await open_trove(USER_3, shrine, abbot, steth_yang, doge_yang, USER_3_STETH_DEPOSIT_WAD, USER_3_DOGE_DEPOSIT_WAD)
    await yin.approve(pool.contract_address, user3_forged_amount).execute(caller_address=USER_3)
    await pool.provide(user3_forged_amount).execute(caller_address=USER_3)

    # previous users deposits shouldn't have changed
    aura_user_deposit = (await pool.get_provider_owed_yin(AURA_USER).execute()).result.yin
    user2_deposit = (await pool.get_provider_owed_yin(USER_2).execute()).result.yin
    w2d_assert(aura_user_deposit, amount * (1-aura_user_ratio))
    w2d_assert(user2_deposit, user2_forged_amount * (1-aura_user_ratio))
    user3_deposit = (await pool.get_provider_owed_yin(USER_3).execute()).result.yin
    w2d_assert(user3_deposit, user3_forged_amount)

    
