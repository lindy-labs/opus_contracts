import pytest

from decimal import Decimal

from tests.purger.test_purger import purger, advance_yang_prices_by_percentage, aura_user_with_first_trove
from tests.purger.constants import DEBT_CEILING_WAD

from tests.utils import (
    AURA_USER,
    TROVE_1,
    compile_contract,
)
from tests.shrine.constants import FEED_LEN, MAX_PRICE_CHANGE, MULTIPLIER_FEED
from tests.roles import ShrineRoles
    
@pytest.fixture
async def deployed_pool(request, shrine, yin, purger, starknet):
    pool_contract = compile_contract("contracts/stability_pool/stability_pool.cairo", request)
    pool = await starknet.deploy(
        contract_class=pool_contract,
        constructor_calldata=[yin.contract_address, shrine.contract_address, purger.contract_address],
    )
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
    assert deposit == amount


@pytest.mark.usefixtures(
    "abbot_with_yangs",
    "funded_aura_user",
    "aura_user_with_first_trove"
)
@pytest.mark.asyncio
async def test_liquidate(
    starknet,
    shrine,
    purger,
    deployed_pool,
    yin,
    steth_yang,
    doge_yang,
    aura_user_with_first_trove):
    """
    The SP is used to absorb a Trove's debt.
    """
    pool = deployed_pool
    amount = aura_user_with_first_trove
    await yin.approve(pool.contract_address, amount).execute(caller_address=AURA_USER)
    await pool.provide(amount).execute(caller_address=AURA_USER)

    # prices change, trove becomes totally liquidatable
    await advance_yang_prices_by_percentage(starknet, shrine, [steth_yang, doge_yang], Decimal("-0.5"))
    expected_max_close_amnt = (await purger.get_max_close_amount(TROVE_1).execute()).result.wad
    assert amount == expected_max_close_amnt

    # absorb trove's debt
    await pool.liquidate(TROVE_1).execute(caller_address=AURA_USER)
    # pool 