import pytest
from starkware.starknet.testing.starknet import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.shrine.constants import FORGE_AMT, TROVE_1, USER_1, USER_2, USER_3
from tests.utils import assert_event_emitted, compile_contract, str_to_felt

INFINITE_ALLOWANCE = 2**125

#
# Fixtures
#


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


#
# Basic tests
#


@pytest.mark.asyncio
async def test_yin_transfer_pass(shrine_forge, yin):

    # Checking USER_1's and USER_2's initial balance
    u1_bal = (await yin.balanceOf(USER_1).invoke()).result.balance
    assert u1_bal == FORGE_AMT

    u2_bal = (await yin.balanceOf(USER_2).invoke()).result.balance
    assert u2_bal == 0

    # Transferring all of USER_1's balance to USER_2
    transfer_tx = await yin.transfer(USER_2, FORGE_AMT).invoke(caller_address=USER_1)
    assert transfer_tx.result.success == 1

    u1_new_bal = (await yin.balanceOf(USER_1).invoke()).result.balance
    assert u1_new_bal == 0

    u2_new_bal = (await yin.balanceOf(USER_2).invoke()).result.balance
    assert u2_new_bal == FORGE_AMT

    assert_event_emitted(transfer_tx, yin.contract_address, "Transfer", [USER_1, USER_2, FORGE_AMT])


@pytest.mark.asyncio
async def test_yin_transfer_fail(shrine_forge, yin):
    # Attempting to transfer more yin than USER_1 owns
    with pytest.raises(StarkException, match="Shrine: transfer amount exceeds yin balance"):
        await yin.transfer(USER_2, FORGE_AMT + 1).invoke(caller_address=USER_1)

    # Attempting to transfer any amount of yin when USER_2 owns nothing
    with pytest.raises(StarkException, match="Shrine: transfer amount exceeds yin balance"):
        await yin.transfer(USER_1, 1).invoke(caller_address=USER_2)

    # Attempting to transfer 0 yin when USER_2 owns nothing - should pass
    await yin.transfer(USER_1, 0).invoke(caller_address=USER_2)


@pytest.mark.asyncio
async def test_yin_transfer_from_pass(shrine_forge, yin):

    # USER_1 approves USER_2
    approve_tx = await yin.approve(USER_2, FORGE_AMT).invoke(caller_address=USER_1)
    assert approve_tx.result.success == 1

    # Checking USER_2's allowance for USER_1
    allowance = (await yin.allowance(USER_1, USER_2).invoke()).result.remaining
    assert allowance == FORGE_AMT

    # USER_2 transfers all of USER_1's funds to USER_3
    await yin.transferFrom(USER_1, USER_3, FORGE_AMT).invoke(caller_address=USER_2)

    # Checking balances
    u1_bal = (await yin.balanceOf(USER_1).invoke()).result.balance
    assert u1_bal == 0

    u3_bal = (await yin.balanceOf(USER_3).invoke()).result.balance
    assert u3_bal == FORGE_AMT

    # Checking USER_2's allowance
    u2_allowance = (await yin.allowance(USER_1, USER_2).invoke()).result.remaining
    assert u2_allowance == 0

    # infinite allowance test
    await yin.approve(USER_2, INFINITE_ALLOWANCE).invoke(caller_address=USER_3)
    await yin.transferFrom(USER_3, USER_1, FORGE_AMT).invoke(caller_address=USER_2)
    u2_allowance = (await yin.allowance(USER_3, USER_2).invoke()).result.remaining
    assert u2_allowance == INFINITE_ALLOWANCE


@pytest.mark.asyncio
async def test_yin_transfer_from_fail(shrine_forge, yin):
    # Calling `transferFrom` with an allowance of zero

    # USER_2 transfers all of USER_1's funds to USER_3 - should fail
    # since USER_1 hasn't approved USER_2
    with pytest.raises(StarkException, match="Yin: insufficient allowance"):
        await yin.transferFrom(USER_1, USER_3, FORGE_AMT).invoke(caller_address=USER_2)

    # USER_1 approves USER_2 but not enough to send FORGE_AMT
    await yin.approve(USER_2, FORGE_AMT // 2).invoke(caller_address=USER_1)

    # Should fail since USER_2's allowance for USER_1 is less than FORGE_AMT
    with pytest.raises(StarkException, match="Yin: insufficient allowance"):
        await yin.transferFrom(USER_1, USER_3, FORGE_AMT).invoke(caller_address=USER_2)

    # USER_1 grants USER_2 unlimited allowance
    await yin.approve(USER_2, INFINITE_ALLOWANCE).invoke(caller_address=USER_1)

    # Should fail since USER_2's tries transferring more than USER_1 has in their balance
    with pytest.raises(StarkException, match="Shrine: transfer amount exceeds yin balance"):
        await yin.transferFrom(USER_1, USER_3, FORGE_AMT + 1).invoke(caller_address=USER_2)


@pytest.mark.asyncio
async def test_yin_invalid_inputs(yin):

    with pytest.raises(StarkException, match=r"Yin: amount is not in the valid range \[0, 2\*\*125\]"):
        await yin.transfer(USER_2, -1).invoke(caller_address=USER_1)

    with pytest.raises(StarkException, match=r"Yin: amount is not in the valid range \[0, 2\*\*125\]"):
        await yin.transfer(USER_2, 2**125 + 1).invoke(caller_address=USER_1)

    with pytest.raises(StarkException, match=r"Yin: amount is not in the valid range \[0, 2\*\*125\]"):
        await yin.approve(USER_2, -1).invoke(caller_address=USER_1)

    with pytest.raises(StarkException, match=r"Yin: amount is not in the valid range \[0, 2\*\*125\]"):
        await yin.transfer(USER_2, 2**125 + 1).invoke(caller_address=USER_1)


#
# Testing edge cases
#


@pytest.mark.asyncio
async def test_yin_melt_after_transfer(shrine, shrine_forge, yin, users):
    shrine_owner = await users("shrine owner")

    # Transferring half of USER_1's balance to USER_2
    await yin.transfer(USER_2, FORGE_AMT // 2).invoke(caller_address=USER_1)

    # Trying to melt `FORGE_AMT` debt. Shoulld fail since USER_1 no longer has FORGE_AMT yin.
    with pytest.raises(StarkException, match="Shrine: not enough yin to melt debt"):
        await shrine_owner.send_tx(shrine.contract_address, "melt", [FORGE_AMT, TROVE_1, USER_1])

    # Trying to melt less than half of `FORGE_AMT`. Should pass since USER_1 has enough yin to do this.
    await shrine_owner.send_tx(shrine.contract_address, "melt", [FORGE_AMT // 2 - 1, TROVE_1, USER_1])

    # Checking that the user's debt and yin are what we expect them to be
    u1_trove = (await shrine.get_trove(TROVE_1).invoke()).result.trove
    u1_yin = (await shrine.get_yin(USER_1).invoke()).result.wad

    assert u1_trove.debt == FORGE_AMT - (FORGE_AMT // 2 - 1)

    # First `FORGE_AMT//2` yin was transferred, and then `FORGE_AMT//2 - 1` was melted
    assert u1_yin == FORGE_AMT - FORGE_AMT // 2 - (FORGE_AMT // 2 - 1)
