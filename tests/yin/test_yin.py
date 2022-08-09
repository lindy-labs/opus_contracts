import pytest
from starkware.starknet.testing.starknet import StarknetContract

from tests.shrine.constants import FORGE_AMT, USER_1, USER_2
from tests.utils import assert_event_emitted, compile_contract, str_to_felt


@pytest.fixture
async def yin_deploy(shrine, starknet) -> StarknetContract:
    yin_contract = compile_contract("contracts/yin/yin.cairo")
    yin = await starknet.deploy(
        contract_class=yin_contract,
        constructor_calldata=[str_to_felt("USD Aura"), str_to_felt("USDa"), 18, shrine.contract_address],
    )
    return yin


@pytest.fixture
async def yin(yin_deploy, shrine, users) -> StarknetContract:
    shrine_owner = await users("shrine owner")
    await shrine_owner.send_tx(shrine.contract_address, "authorize", [yin_deploy.contract_address])

    return yin_deploy


@pytest.mark.asyncio
async def test_yin_transfer_pass(shrine, shrine_forge, yin):

    # Checking USER_1's and USER_2's initial balance
    u1_bal = (await yin.balanceOf(USER_1).invoke()).result.balance
    assert u1_bal == FORGE_AMT

    u2_bal = (await yin.balanceOf(USER_2).invoke()).result.balance
    assert u2_bal == 0

    # Transferring all of USER_1's balance to USER_2
    transfer_tx = await yin.transfer(USER_2, FORGE_AMT).invoke(caller_address=USER_1)

    u1_new_bal = (await yin.balanceOf(USER_1).invoke()).result.balance
    assert u1_new_bal == 0
    u2_new_bal = (await yin.balanceOf(USER_2).invoke()).result.balance
    assert u2_new_bal == FORGE_AMT

    assert_event_emitted(transfer_tx, yin.contract_address, "Transfer", [USER_1, USER_2, FORGE_AMT])
