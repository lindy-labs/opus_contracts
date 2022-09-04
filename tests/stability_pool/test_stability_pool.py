import pytest
from starkware.starknet.testing.objects import StarknetTransactionExecutionInfo
from starkware.starkware_utils.error_handling import StarkException
from starkware.starknet.testing.starknet import StarknetContract

from tests.utils import (
    SHRINE_OWNER,
    TROVE1_OWNER,
    compile_contract,
    str_to_felt,
    to_wad
)
from tests.shrine.constants import (
    ShrineRoles,
    TROVE_1,
    FORGE_AMT_WAD
)

@pytest.fixture
async def deployed_pool(request, shrine, starknet):
    # Deploying the yin contract
    yin_contract = compile_contract("contracts/yin/yin.cairo", request)
    yin = await starknet.deploy(
        contract_class=yin_contract,
        constructor_calldata=[str_to_felt("USD Aura"), str_to_felt("USDa"), 18, shrine.contract_address],
    )

    # Authorizing the yin contract to call `move_yin` in shrine
    await shrine.grant_role(ShrineRoles.MOVE_YIN, yin.contract_address).invoke(caller_address=SHRINE_OWNER)

    pool_contract = compile_contract("contracts/stability_pool/stability_pool.cairo", request)
    pool = await starknet.deploy(
        contract_class=pool_contract,
        constructor_calldata=[yin.contract_address, shrine.contract_address]
    )

    await shrine.forge(TROVE1_OWNER, TROVE_1, FORGE_AMT_WAD).invoke(caller_address=SHRINE_OWNER)

    return yin, shrine, pool

@pytest.mark.parametrize("amount", [to_wad(1000)])
@pytest.mark.asyncio
async def test_provide(deployed_pool, amount):
    # user needs to have yin beforehand
    yin, shrine, pool = deployed_pool
    await yin.approve(pool.contract_address, amount).invoke(caller_address=TROVE1_OWNER)
    await shrine.provide(amount).invoke(caller_address=TROVE1_OWNER)
    deposit = (await pool.get_provider_owed_yin(TROVE1_OWNER)).result.yin
    assert deposit == amount
