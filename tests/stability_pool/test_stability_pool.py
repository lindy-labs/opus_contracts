import pytest

from decimal import Decimal

from tests.purger.test_purger import purger, advance_yang_prices_by_percentage, aura_user_with_first_trove
from tests.purger.constants import DEBT_CEILING_WAD

from tests.utils import (
    SHRINE_OWNER,
    TROVE1_OWNER,
    TROVE_1,
    TIME_INTERVAL,
    compile_contract,
    str_to_felt,
    to_wad,
    create_feed,
    from_wad,
    set_block_timestamp
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
    #await shrine.forge(TROVE1_OWNER, TROVE_1, FORGE_AMT_WAD).invoke(caller_address=SHRINE_OWNER)
    return pool

@pytest.mark.usefixtures("aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_provide(deployed_pool, shrine, yin, aura_user_with_first_trove):
    pool = deployed_pool
    amount = aura_user_with_first_trove
    await yin.approve(pool.contract_address, amount).invoke(caller_address=TROVE1_OWNER)
    await shrine.provide(amount).invoke(caller_address=TROVE1_OWNER)
    deposit = (await pool.get_provider_owed_yin(TROVE1_OWNER)).result.yin
    assert deposit == amount
