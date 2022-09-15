import pytest

from decimal import Decimal

from starkware.starkware_utils.error_handling import StarkException

from tests.purger.test_purger import purger, advance_yang_prices_by_percentage, aura_user_with_first_trove
from tests.purger.constants import *
from tests.absorber.constants import *

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
async def deployed_pool(request, shrine, abbot, yin, purger, starknet):
    pool_contract = compile_contract("contracts/absorber/absorber.cairo", request)
    absorber = await starknet.deploy(
        contract_class=pool_contract,
        constructor_calldata=[yin.contract_address, shrine.contract_address, purger.contract_address, abbot.contract_address],
    )
    new_ceiling = to_wad(100_000_000)
    await shrine.set_ceiling(new_ceiling).execute(caller_address=SHRINE_OWNER)
    return absorber

@pytest.mark.usefixtures(
    "abbot_with_yangs",
    "funded_aura_user",
    "aura_user_with_first_trove"
)
@pytest.mark.asyncio
async def test_provide(deployed_pool, yin, aura_user_with_first_trove):
    """
    The user already opened a Trove and is depositing his Yin into the Absorber.
    Ensures the compounded deposit at t=0 is correct.
    """
    absorber = deployed_pool
    amount = aura_user_with_first_trove
    await yin.approve(absorber.contract_address, amount).execute(caller_address=AURA_USER)
    await absorber.provide(amount).execute(caller_address=AURA_USER)
    deposit = (await absorber.get_provider_owed_yin(AURA_USER).execute()).result.yin
    pool_balance = (await yin.balanceOf(absorber.contract_address).execute()).result.wad
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
    The Absorber is used to absorb a Trove's debt.

    The providers compounded deposits should be lower than the initial deposit.
    """
    absorber = deployed_pool
    amount = aura_user_with_first_trove
    # Funds an extra user
    await fund_user(USER_2, steth_yang, doge_yang, steth_token, doge_token, USER_2_STETH_DEPOSIT_WAD, USER_2_DOGE_DEPOSIT_WAD)
    user2_forged_amount = await open_trove(USER_2, shrine, abbot, steth_yang, doge_yang, USER_2_STETH_DEPOSIT_WAD, USER_2_DOGE_DEPOSIT_WAD)

    await yin.approve(absorber.contract_address, amount).execute(caller_address=AURA_USER)
    await absorber.provide(amount).execute(caller_address=AURA_USER)

    # user2 provides as well
    await yin.approve(absorber.contract_address, user2_forged_amount).execute(caller_address=USER_2)
    await absorber.provide(user2_forged_amount).execute(caller_address=USER_2)

    # At this point, AURA_USER and user2 have the same amount of Yin in the Absorber
    aura_user_ratio = amount / (amount + user2_forged_amount)
    absorber_pre_balance = (await yin.balanceOf(absorber.contract_address).execute()).result.wad

    # prices change, trove becomes totally liquidatable
    await advance_yang_prices_by_percentage(starknet, shrine, [steth_yang, doge_yang], Decimal("-0.5"))
    expected_max_close_amnt = (await purger.get_max_close_amount(TROVE_1).execute()).result.wad
    assert amount == expected_max_close_amnt

    # absorb trove's debt
    absorbed = (await absorber.liquidate(TROVE_1).execute(caller_address=AURA_USER)).result.absorbed
    # absorber's liquidity should be decreased by the amount of debt absorbed
    new_pool_balance = (await yin.balanceOf(absorber.contract_address).execute()).result.wad
    assert new_pool_balance == absorber_pre_balance - expected_max_close_amnt

    # both users should see their deposits decreased by 66%
    decrease_ratio = absorbed / absorber_pre_balance
    aura_user_deposit = (await absorber.get_provider_owed_yin(AURA_USER).execute()).result.yin
    user2_deposit = (await absorber.get_provider_owed_yin(USER_2).execute()).result.yin
    w2d_assert(aura_user_deposit, amount * (1-decrease_ratio))
    w2d_assert(user2_deposit, user2_forged_amount * (1-decrease_ratio))


    # someone deposit **after** the liquidation
    await fund_user(USER_3, steth_yang, doge_yang, steth_token, doge_token, USER_3_STETH_DEPOSIT_WAD, USER_3_DOGE_DEPOSIT_WAD)
    user3_forged_amount = await open_trove(USER_3, shrine, abbot, steth_yang, doge_yang, USER_3_STETH_DEPOSIT_WAD, USER_3_DOGE_DEPOSIT_WAD)
    await yin.approve(absorber.contract_address, user3_forged_amount).execute(caller_address=USER_3)
    await absorber.provide(user3_forged_amount).execute(caller_address=USER_3)

    # previous users deposits shouldn't have changed
    aura_user_deposit = (await absorber.get_provider_owed_yin(AURA_USER).execute()).result.yin
    user2_deposit = (await absorber.get_provider_owed_yin(USER_2).execute()).result.yin
    w2d_assert(aura_user_deposit, amount * (1-aura_user_ratio))
    w2d_assert(user2_deposit, user2_forged_amount * (1-aura_user_ratio))
    
    user3_deposit = (await absorber.get_provider_owed_yin(USER_3).execute()).result.yin
    w2d_assert(user3_deposit, user3_forged_amount)


@pytest.mark.usefixtures(
    "abbot_with_yangs",
    "funded_aura_user",
    "aura_user_with_first_trove"
)
@pytest.mark.asyncio
async def test_withdrawing(
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
    The Absorber is used to absorb a Trove's debt and then the providers withdraw their owed collaterals.
    """
    absorber = deployed_pool
    amount = aura_user_with_first_trove
    # Funds an extra user
    await fund_user(USER_2, steth_yang, doge_yang, steth_token, doge_token, USER_2_STETH_DEPOSIT_WAD, USER_2_DOGE_DEPOSIT_WAD)
    user2_forged_amount = await open_trove(USER_2, shrine, abbot, steth_yang, doge_yang, USER_2_STETH_DEPOSIT_WAD, USER_2_DOGE_DEPOSIT_WAD)

    # AURA_USER provides
    await yin.approve(absorber.contract_address, amount).execute(caller_address=AURA_USER)
    await absorber.provide(amount).execute(caller_address=AURA_USER)
    # USER_2 provides
    await yin.approve(absorber.contract_address, user2_forged_amount).execute(caller_address=USER_2)
    await absorber.provide(user2_forged_amount).execute(caller_address=USER_2)

    # At this point, there are only 2 providers to the Absorber ; AURA_USER and USER_2

    pre_pool_yin_balance = (await yin.balanceOf(absorber.contract_address).execute()).result.wad
    # Price goes down by 50%, trove becomes totally liquidatable
    await advance_yang_prices_by_percentage(starknet, shrine, [steth_yang, doge_yang], Decimal("-0.5"))
    absorbed = (await absorber.liquidate(TROVE_1).execute(caller_address=AURA_USER)).result.absorbed

    pool_steth_balance = (await steth_token.balanceOf(absorber.contract_address).execute()).result.balance.low

    # withdraws collaterals and yins
    await absorber.withdraw().execute(caller_address=AURA_USER)
    await absorber.withdraw().execute(caller_address=USER_2)

    # check USER_2 got his owed yin minus the losses incurred by liquidation
    decrease_ratio = absorbed / pre_pool_yin_balance
    user2_yin_balance = (await yin.balanceOf(USER_2).execute()).result.wad
    w2d_assert(user2_yin_balance, user2_forged_amount * (1-decrease_ratio))
    auser_yin_balance = (await yin.balanceOf(AURA_USER).execute()).result.wad
    w2d_assert(auser_yin_balance, amount * (1-decrease_ratio))


    ## balances are correct
    # user 2 should only have 1/3rd of steth
    user2_post_balance_steth = (await steth_token.balanceOf(USER_2).execute()).result.balance.low
    # error margin might be too big!!
    w2d_assert(user2_post_balance_steth, pool_steth_balance * 1/3, Decimal("1e-3"))

    # absorber should be emptied of any collaterals
    absorber_post_balance_doge = (await doge_token.balanceOf(absorber.contract_address).execute()).result.balance.low
    w2d_assert(absorber_post_balance_doge, 0)
    absorber_post_balance_steth = (await steth_token.balanceOf(absorber.contract_address).execute()).result.balance.low
    w2d_assert(absorber_post_balance_steth, 0)
    

@pytest.mark.usefixtures(
    "abbot_with_yangs",
    "funded_aura_user",
    "aura_user_with_first_trove"
)
@pytest.mark.asyncio
async def test_claim(
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
    An user should be able to claim his owed shares of collaterals following a liquidation without having
    to withdraw his deposit.
    """
    absorber = deployed_pool
    amount = aura_user_with_first_trove
    
    # Funds an extra user
    await fund_user(USER_2, steth_yang, doge_yang, steth_token, doge_token, USER_2_STETH_DEPOSIT_WAD, USER_2_DOGE_DEPOSIT_WAD)
    user2_forged_amount = await open_trove(USER_2, shrine, abbot, steth_yang, doge_yang, USER_2_STETH_DEPOSIT_WAD, USER_2_DOGE_DEPOSIT_WAD)

    aura_user_ratio = amount / (amount + user2_forged_amount)

    await yin.approve(absorber.contract_address, amount).execute(caller_address=AURA_USER)
    await absorber.provide(amount).execute(caller_address=AURA_USER)

    # user2 provides as well
    await yin.approve(absorber.contract_address, user2_forged_amount).execute(caller_address=USER_2)
    await absorber.provide(user2_forged_amount).execute(caller_address=USER_2)

    # prices change, trove becomes totally liquidatable
    await advance_yang_prices_by_percentage(starknet, shrine, [steth_yang, doge_yang], Decimal("-0.5"))

    # absorb trove's debt
    absorbed = (await absorber.liquidate(TROVE_1).execute(caller_address=AURA_USER)).result.absorbed
    decrease_ratio = absorbed / (amount + user2_forged_amount)

    absorber_doge_balance = (await doge_token.balanceOf(absorber.contract_address).execute()).result.balance.low

    ## USER_2 claims
    await absorber.claim().execute(caller_address=USER_2)
    # yangs claims should be gucci
    user2_doge_balance = (await doge_token.balanceOf(USER_2).execute()).result.balance.low
    user2_expected_doge_balance = absorber_doge_balance * (1 - aura_user_ratio)
    w2d_assert(user2_doge_balance, user2_expected_doge_balance)
    # deposit should be untouched
    user2_compounded_deposit = (await absorber.get_provider_owed_yin(USER_2).execute()).result.yin
    w2d_assert(user2_compounded_deposit, user2_forged_amount * (1-decrease_ratio))
    # pool should still have user1's (aura user) doge in it
    absorber_post_doge_balance = (await doge_token.balanceOf(absorber.contract_address).execute()).result.balance.low
    w2d_assert(absorber_post_doge_balance, absorber_doge_balance - user2_doge_balance)



@pytest.mark.usefixtures(
    "abbot_with_yangs",
    "funded_aura_user",
    "aura_user_with_first_trove"
)
@pytest.mark.asyncio
async def test_interests(
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
    Tests if the interest paid are correctly distributed to the providers.
    """
    absorber = deployed_pool
    amount = aura_user_with_first_trove
    aura_user_provided_amount = amount // 2
    
    # Funds an extra user
    await fund_user(USER_2, steth_yang, doge_yang, steth_token, doge_token, USER_2_STETH_DEPOSIT_WAD, USER_2_DOGE_DEPOSIT_WAD)
    user2_forged_amount = await open_trove(USER_2, shrine, abbot, steth_yang, doge_yang, USER_2_STETH_DEPOSIT_WAD, USER_2_DOGE_DEPOSIT_WAD)

    aura_user_ratio = aura_user_provided_amount / (aura_user_provided_amount + user2_forged_amount)

    await yin.approve(absorber.contract_address, aura_user_provided_amount).execute(caller_address=AURA_USER)
    await absorber.provide(aura_user_provided_amount).execute(caller_address=AURA_USER)

    # user2 provides as well
    await yin.approve(absorber.contract_address, user2_forged_amount).execute(caller_address=USER_2)
    await absorber.provide(user2_forged_amount).execute(caller_address=USER_2)

    interests_to_send = amount // 10
    # yin as interest is sent to the absorber
    await yin.approve(absorber.contract_address, interests_to_send).execute(caller_address=AURA_USER)
    await absorber.transfer_interests(yin.contract_address, interests_to_send).execute(caller_address=AURA_USER)


    # aura_user and USER_2 claim interests once
    await absorber.claim().execute(caller_address=AURA_USER)
    await absorber.claim().execute(caller_address=USER_2)

    ## check that balances are correct
    # user2 yin balance should be zero before claiming
    user2_yin_balance = (await yin.balanceOf(USER_2).execute()).result.wad
    user2_expected_yin_balance = interests_to_send * (1-aura_user_ratio)
    w2d_assert(user2_yin_balance, user2_expected_yin_balance)

    aura_user_yin_balance = (await yin.balanceOf(AURA_USER).execute()).result.wad
    aura_user_expected_yin_balance = aura_user_provided_amount - interests_to_send + (interests_to_send) * aura_user_ratio
    w2d_assert(aura_user_yin_balance, aura_user_expected_yin_balance)

    # yin interests paid shouldn't affect total deposits
    absorber_yin_balance = (await yin.balanceOf(absorber.contract_address).execute()).result.wad
    absorber_expected_yin_balance = aura_user_provided_amount + user2_forged_amount
    w2d_assert(absorber_yin_balance, absorber_expected_yin_balance)


    # claiming twice won't transfer anymore yin
    await absorber.claim().execute(caller_address=USER_2)
    user2_yin_balance = (await yin.balanceOf(USER_2).execute()).result.wad
    w2d_assert(user2_yin_balance, user2_expected_yin_balance)

    # Test a second round of interests
    await yin.approve(absorber.contract_address, interests_to_send).execute(caller_address=AURA_USER)
    await absorber.transfer_interests(yin.contract_address, interests_to_send).execute(caller_address=AURA_USER)

    await absorber.claim().execute(caller_address=USER_2)

    user2_yin_balance = (await yin.balanceOf(USER_2).execute()).result.wad
    user2_expected_yin_balance *= 2
    w2d_assert(user2_yin_balance, user2_expected_yin_balance)




