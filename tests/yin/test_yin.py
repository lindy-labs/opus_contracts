import pytest
from starkware.starknet.testing.starknet import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.shrine.constants import FORGE_AMT_WAD, TROVE_1
from tests.utils import CAIRO_PRIME, SHRINE_OWNER, TROVE1_OWNER, assert_event_emitted, compile_contract, str_to_felt

INFINITE_ALLOWANCE = CAIRO_PRIME - 1

TRUE = 1

# Accounts
USER_2 = str_to_felt("user 2")
USER_3 = str_to_felt("user 3")

#
# Fixtures
#


@pytest.fixture
async def yin(starknet, shrine) -> StarknetContract:

    # Deploying the yin contract
    yin_contract = compile_contract("contracts/yin/yin.cairo")
    deployed_yin = await starknet.deploy(
        contract_class=yin_contract,
        constructor_calldata=[str_to_felt("USD Aura"), str_to_felt("USDa"), 18, shrine.contract_address],
    )

    # Authorizing the yin contract in shrine
    await shrine.authorize(deployed_yin.contract_address).invoke(caller_address=SHRINE_OWNER)

    return deployed_yin


@pytest.fixture
async def shrine_killed(shrine) -> StarknetContract:
    shrine.kill().invoke(caller_address=SHRINE_OWNER)
    return shrine


@pytest.fixture
def shrine_both(request) -> StarknetContract:
    """
    Wrapper fixture to pass the regular and killed instances of shrine to `pytest.parametrize`.
    """
    return request.getfixturevalue(request.param)


#
# Basic tests
#


@pytest.mark.parametrize("shrine_both", ["shrine", "shrine_killed"], indirect=["shrine_both"])
@pytest.mark.asyncio
async def test_yin_transfer_pass(shrine_forge, shrine_both, yin):

    # Checking TROVE1_OWNER's and USER_2's initial balance
    u1_bal = (await yin.balanceOf(TROVE1_OWNER).invoke()).result.wad
    assert u1_bal == FORGE_AMT_WAD

    u2_bal = (await yin.balanceOf(USER_2).invoke()).result.wad
    assert u2_bal == 0

    # Transferring all of TROVE1_OWNER's balance to USER_2
    transfer_tx = await yin.transfer(USER_2, FORGE_AMT_WAD).invoke(caller_address=TROVE1_OWNER)
    assert transfer_tx.result.bool == TRUE

    u1_new_bal = (await yin.balanceOf(TROVE1_OWNER).invoke()).result.wad
    assert u1_new_bal == 0

    u2_new_bal = (await yin.balanceOf(USER_2).invoke()).result.wad
    assert u2_new_bal == FORGE_AMT_WAD

    assert_event_emitted(transfer_tx, yin.contract_address, "Transfer", [TROVE1_OWNER, USER_2, FORGE_AMT_WAD])

    # Attempting to transfer 0 yin when TROVE1_OWNER owns nothing - should pass
    await yin.transfer(USER_2, 0).invoke(caller_address=TROVE1_OWNER)


@pytest.mark.asyncio
async def test_yin_transfer_fail(shrine_forge, yin):
    # Attempting to transfer more yin than TROVE1_OWNER owns
    with pytest.raises(StarkException, match="Shrine: transfer amount exceeds yin balance"):
        await yin.transfer(USER_2, FORGE_AMT_WAD + 1).invoke(caller_address=TROVE1_OWNER)

    # Attempting to transfer any amount of yin when USER_2 owns nothing
    with pytest.raises(StarkException, match="Shrine: transfer amount exceeds yin balance"):
        await yin.transfer(TROVE1_OWNER, 1).invoke(caller_address=USER_2)


@pytest.mark.parametrize("shrine_both", ["shrine", "shrine_killed"], indirect=["shrine_both"])
@pytest.mark.asyncio
async def test_yin_transfer_from_pass(shrine_forge, shrine_both, yin):

    # TROVE1_OWNER approves USER_2
    approve_tx = await yin.approve(USER_2, FORGE_AMT_WAD).invoke(caller_address=TROVE1_OWNER)
    assert approve_tx.result.bool == TRUE

    # Checking USER_2's allowance for TROVE1_OWNER
    allowance = (await yin.allowance(TROVE1_OWNER, USER_2).invoke()).result.wad
    assert allowance == FORGE_AMT_WAD

    # USER_2 transfers all of TROVE1_OWNER's funds to USER_3
    await yin.transferFrom(TROVE1_OWNER, USER_3, FORGE_AMT_WAD).invoke(caller_address=USER_2)

    # Checking balances
    u1_bal = (await yin.balanceOf(TROVE1_OWNER).invoke()).result.wad
    assert u1_bal == 0

    u3_bal = (await yin.balanceOf(USER_3).invoke()).result.wad
    assert u3_bal == FORGE_AMT_WAD

    # Checking USER_2's allowance
    u2_allowance = (await yin.allowance(TROVE1_OWNER, USER_2).invoke()).result.wad
    assert u2_allowance == 0


@pytest.mark.asyncio
async def test_yin_infinite_allowance(shrine_forge, yin):
    # infinite allowance test
    await yin.approve(USER_2, INFINITE_ALLOWANCE).invoke(caller_address=TROVE1_OWNER)
    await yin.transferFrom(TROVE1_OWNER, USER_3, FORGE_AMT_WAD).invoke(caller_address=USER_2)
    u2_allowance = (await yin.allowance(TROVE1_OWNER, USER_2).invoke()).result.wad
    assert u2_allowance == INFINITE_ALLOWANCE


@pytest.mark.asyncio
async def test_yin_transfer_from_fail(shrine_forge, yin):
    # Calling `transferFrom` with an allowance of zero

    # USER_2 transfers all of TROVE1_OWNER's funds to USER_3 - should fail
    # since TROVE1_OWNER hasn't approved USER_2
    with pytest.raises(StarkException, match="Yin: insufficient allowance"):
        await yin.transferFrom(TROVE1_OWNER, USER_3, FORGE_AMT_WAD).invoke(caller_address=USER_2)

    # TROVE1_OWNER approves USER_2 but not enough to send FORGE_AMT_WAD
    await yin.approve(USER_2, FORGE_AMT_WAD // 2).invoke(caller_address=TROVE1_OWNER)

    # Should fail since USER_2's allowance for TROVE1_OWNER is less than FORGE_AMT_WAD
    with pytest.raises(StarkException, match="Yin: insufficient allowance"):
        await yin.transferFrom(TROVE1_OWNER, USER_3, FORGE_AMT_WAD).invoke(caller_address=USER_2)

    # TROVE1_OWNER grants USER_2 unlimited allowance
    await yin.approve(USER_2, INFINITE_ALLOWANCE).invoke(caller_address=TROVE1_OWNER)

    # Should fail since USER_2's tries transferring more than TROVE1_OWNER has in their balance
    with pytest.raises(StarkException, match="Shrine: transfer amount exceeds yin balance"):
        await yin.transferFrom(TROVE1_OWNER, USER_3, FORGE_AMT_WAD + 1).invoke(caller_address=USER_2)

    # Transfer to zero address - should fail since a check prevents this
    with pytest.raises(StarkException, match="Yin: cannot transfer to the zero address"):
        await yin.transferFrom(TROVE1_OWNER, 0, FORGE_AMT_WAD).invoke(caller_address=USER_2)


@pytest.mark.asyncio
async def test_yin_invalid_inputs(yin):

    with pytest.raises(StarkException, match=r"Yin: amount is not in the valid range \[0, 2\*\*125\]"):
        await yin.transfer(USER_2, -1).invoke(caller_address=TROVE1_OWNER)

    with pytest.raises(StarkException, match=r"Yin: amount is not in the valid range \[0, 2\*\*125\]"):
        await yin.transfer(USER_2, 2**125 + 1).invoke(caller_address=TROVE1_OWNER)

    with pytest.raises(StarkException, match=r"Yin: amount is not in the valid range \[0, 2\*\*125\]"):
        await yin.approve(USER_2, 2**128 + 1).invoke(caller_address=TROVE1_OWNER)

    with pytest.raises(StarkException, match=r"Yin: amount is not in the valid range \[0, 2\*\*125\]"):
        await yin.approve(USER_2, 2**128 - 1).invoke(caller_address=TROVE1_OWNER)

    with pytest.raises(StarkException, match=r"Yin: amount is not in the valid range \[0, 2\*\*125\]"):
        await yin.approve(USER_2, -2).invoke(caller_address=TROVE1_OWNER)

    with pytest.raises(StarkException, match=r"Yin: amount is not in the valid range \[0, 2\*\*125\]"):
        await yin.approve(USER_2, 2**125 + 1).invoke(caller_address=TROVE1_OWNER)


#
# Testing edge cases
#


@pytest.mark.parametrize("shrine_both", ["shrine", "shrine_killed"], indirect=["shrine_both"])
@pytest.mark.asyncio
async def test_yin_melt_after_transfer(shrine_forge, shrine_both, yin):
    shrine = shrine_both

    # Transferring half of TROVE1_OWNER's balance to USER_2
    await yin.transfer(USER_2, FORGE_AMT_WAD // 2).invoke(caller_address=TROVE1_OWNER)

    # Trying to melt `FORGE_AMT_WAD` debt. Should fail since TROVE1_OWNER no longer has FORGE_AMT_WAD yin.
    with pytest.raises(StarkException, match="Shrine: not enough yin to melt debt"):
        await shrine.melt(TROVE1_OWNER, TROVE_1, FORGE_AMT_WAD).invoke(caller_address=SHRINE_OWNER)

    # Trying to melt less than half of `FORGE_AMT_WAD`. Should pass since TROVE1_OWNER has enough yin to do this.
    await shrine.melt(
        TROVE1_OWNER,
        TROVE_1,
        FORGE_AMT_WAD // 2 - 1,
    ).invoke(caller_address=SHRINE_OWNER)

    # Checking that the user's debt and yin are what we expect them to be
    u1_trove = (await shrine.get_trove(TROVE_1).invoke()).result.trove
    u1_yin = (await shrine.get_yin(TROVE1_OWNER).invoke()).result.wad

    assert u1_trove.debt == FORGE_AMT_WAD - (FORGE_AMT_WAD // 2 - 1)

    # First `FORGE_AMT_WAD//2` yin was transferred, and then `FORGE_AMT_WAD//2 - 1` was melted
    assert u1_yin == FORGE_AMT_WAD - FORGE_AMT_WAD // 2 - (FORGE_AMT_WAD // 2 - 1)
