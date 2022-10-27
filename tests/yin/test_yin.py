import pytest
from starkware.starknet.testing.contract import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.shrine.constants import FORGE_AMT_WAD
from tests.utils import (
    INFINITE_YIN_ALLOWANCE,
    MAX_UINT256,
    SHRINE_OWNER,
    TROVE1_OWNER,
    TROVE_1,
    TRUE,
    assert_event_emitted,
    from_uint,
    str_to_felt,
)

# Accounts
USER_2 = str_to_felt("user 2")
USER_3 = str_to_felt("user 3")

#
# Fixtures
#


@pytest.fixture
async def shrine_killed(shrine) -> StarknetContract:
    await shrine.kill().execute(caller_address=SHRINE_OWNER)
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
    u1_bal = (await yin.balanceOf(TROVE1_OWNER).execute()).result.balance
    assert u1_bal == FORGE_AMT_WAD

    u2_bal = (await yin.balanceOf(USER_2).execute()).result.balance
    assert u2_bal == 0

    # Transferring all of TROVE1_OWNER's balance to USER_2
    transfer_tx = await yin.transfer(USER_2, FORGE_AMT_WAD).execute(caller_address=TROVE1_OWNER)
    assert transfer_tx.result.success == TRUE

    u1_new_bal = (await yin.balanceOf(TROVE1_OWNER).execute()).result.balance
    assert u1_new_bal == 0

    u2_new_bal = (await yin.balanceOf(USER_2).execute()).result.balance
    assert u2_new_bal == FORGE_AMT_WAD

    assert_event_emitted(
        transfer_tx,
        yin.contract_address,
        "Transfer",
        [TROVE1_OWNER, USER_2, FORGE_AMT_WAD],
    )

    # Attempting to transfer 0 yin when TROVE1_OWNER owns nothing - should pass
    await yin.transfer(USER_2, 0).execute(caller_address=TROVE1_OWNER)


@pytest.mark.asyncio
async def test_yin_transfer_fail(shrine_forge, yin):
    # Attempting to transfer more yin than TROVE1_OWNER owns
    with pytest.raises(StarkException, match="Shrine: Transfer amount exceeds yin balance"):
        await yin.transfer(USER_2, FORGE_AMT_WAD + 1).execute(caller_address=TROVE1_OWNER)

    # Attempting to transfer any amount of yin when USER_2 owns nothing
    with pytest.raises(StarkException, match="Shrine: Transfer amount exceeds yin balance"):
        await yin.transfer(TROVE1_OWNER, 1).execute(caller_address=USER_2)


@pytest.mark.parametrize("shrine_both", ["shrine", "shrine_killed"], indirect=["shrine_both"])
@pytest.mark.asyncio
async def test_yin_transfer_from_pass(shrine_forge, shrine_both, yin):

    # TROVE1_OWNER approves USER_2
    approve_tx = await yin.approve(USER_2, FORGE_AMT_WAD).execute(caller_address=TROVE1_OWNER)
    assert approve_tx.result.success == TRUE

    # Checking USER_2's allowance for TROVE1_OWNER
    allowance = (await yin.allowance(TROVE1_OWNER, USER_2).execute()).result.allowance
    assert allowance == FORGE_AMT_WAD

    # USER_2 transfers all of TROVE1_OWNER's funds to USER_3
    await yin.transferFrom(TROVE1_OWNER, USER_3, FORGE_AMT_WAD).execute(caller_address=USER_2)

    # Checking balances
    u1_bal = (await yin.balanceOf(TROVE1_OWNER).execute()).result.balance
    assert u1_bal == 0

    u3_bal = (await yin.balanceOf(USER_3).execute()).result.balance
    assert u3_bal == FORGE_AMT_WAD

    # Checking USER_2's allowance
    u2_allowance = (await yin.allowance(TROVE1_OWNER, USER_2).execute()).result.allowance
    assert u2_allowance == 0


@pytest.mark.asyncio
async def test_yin_INFINITE_YIN_ALLOWANCE(shrine_forge, yin):
    # infinite allowance test
    await yin.approve(USER_2, INFINITE_YIN_ALLOWANCE).execute(caller_address=TROVE1_OWNER)
    await yin.transferFrom(TROVE1_OWNER, USER_3, FORGE_AMT_WAD).execute(caller_address=USER_2)
    u2_allowance = (await yin.allowance(TROVE1_OWNER, USER_2).execute()).result.allowance
    assert u2_allowance == INFINITE_YIN_ALLOWANCE


@pytest.mark.asyncio
async def test_yin_transfer_from_fail(shrine_forge, yin):
    # Calling `transferFrom` with an allowance of zero

    # USER_2 transfers all of TROVE1_OWNER's funds to USER_3 - should fail
    # since TROVE1_OWNER hasn't approved USER_2
    with pytest.raises(StarkException, match="Yin: Insufficient allowance"):
        await yin.transferFrom(TROVE1_OWNER, USER_3, FORGE_AMT_WAD).execute(caller_address=USER_2)

    # TROVE1_OWNER approves USER_2 but not enough to send FORGE_AMT_WAD
    await yin.approve(USER_2, FORGE_AMT_WAD // 2).execute(caller_address=TROVE1_OWNER)

    # Should fail since USER_2's allowance for TROVE1_OWNER is less than FORGE_AMT_WAD
    with pytest.raises(StarkException, match="Yin: Insufficient allowance"):
        await yin.transferFrom(TROVE1_OWNER, USER_3, FORGE_AMT_WAD).execute(caller_address=USER_2)

    # TROVE1_OWNER grants USER_2 unlimited allowance
    await yin.approve(USER_2, INFINITE_YIN_ALLOWANCE).execute(caller_address=TROVE1_OWNER)

    # Should fail since USER_2's tries transferring more than TROVE1_OWNER has in their balance
    with pytest.raises(StarkException, match="Shrine: Transfer amount exceeds yin balance"):
        await yin.transferFrom(TROVE1_OWNER, USER_3, FORGE_AMT_WAD + 1).execute(caller_address=USER_2)

    # Transfer to zero address - should fail since a check prevents this
    with pytest.raises(StarkException, match="Yin: Cannot transfer to the zero address"):
        await yin.transferFrom(TROVE1_OWNER, 0, FORGE_AMT_WAD).execute(caller_address=USER_2)


@pytest.mark.asyncio
async def test_yin_invalid_inputs(yin):

    with pytest.raises(StarkException, match=r"Yin: Amount is not in the valid range \[0, 2\*\*125\]"):
        await yin.transfer(USER_2, -1).execute(caller_address=TROVE1_OWNER)

    with pytest.raises(StarkException, match=r"Yin: Amount is not in the valid range \[0, 2\*\*125\]"):
        await yin.transfer(USER_2, 2**125 + 1).execute(caller_address=TROVE1_OWNER)

    with pytest.raises(StarkException, match=r"Yin: Amount is not in the valid range \[0, 2\*\*125\]"):
        await yin.approve(USER_2, 2**128 + 1).execute(caller_address=TROVE1_OWNER)

    with pytest.raises(StarkException, match=r"Yin: Amount is not in the valid range \[0, 2\*\*125\]"):
        await yin.approve(USER_2, 2**128 - 1).execute(caller_address=TROVE1_OWNER)

    with pytest.raises(StarkException, match=r"Yin: Amount is not in the valid range \[0, 2\*\*125\]"):
        await yin.approve(USER_2, -2).execute(caller_address=TROVE1_OWNER)

    with pytest.raises(StarkException, match=r"Yin: Amount is not in the valid range \[0, 2\*\*125\]"):
        await yin.approve(USER_2, 2**125 + 1).execute(caller_address=TROVE1_OWNER)


#
# Testing edge cases
#


@pytest.mark.parametrize("shrine_both", ["shrine", "shrine_killed"], indirect=["shrine_both"])
@pytest.mark.asyncio
async def test_yin_melt_after_transfer(shrine_forge, shrine_both, yin):
    shrine = shrine_both

    # Transferring half of TROVE1_OWNER's balance to USER_2
    await yin.transfer(USER_2, FORGE_AMT_WAD // 2).execute(caller_address=TROVE1_OWNER)

    # Trying to melt `FORGE_AMT_WAD` debt. Should fail since TROVE1_OWNER no longer has FORGE_AMT_WAD yin.
    with pytest.raises(StarkException, match="Shrine: Not enough yin to melt debt"):
        await shrine.melt(TROVE1_OWNER, TROVE_1, FORGE_AMT_WAD).execute(caller_address=SHRINE_OWNER)

    # Trying to melt less than half of `FORGE_AMT_WAD`. Should pass since TROVE1_OWNER has enough yin to do this.
    await shrine.melt(TROVE1_OWNER, TROVE_1, FORGE_AMT_WAD // 2 - 1).execute(caller_address=SHRINE_OWNER)

    # Checking that the user's debt and yin are what we expect them to be
    u1_trove = (await shrine.get_trove(TROVE_1).execute()).result.trove
    u1_yin = (await shrine.get_yin(TROVE1_OWNER).execute()).result.balance

    assert u1_trove.debt == FORGE_AMT_WAD - (FORGE_AMT_WAD // 2 - 1)

    # First `FORGE_AMT_WAD//2` yin was transferred, and then `FORGE_AMT_WAD//2 - 1` was melted
    assert u1_yin == FORGE_AMT_WAD - FORGE_AMT_WAD // 2 - (FORGE_AMT_WAD // 2 - 1)


#
# Flash mint tests
#


@pytest.mark.asyncio
async def test_flashFee(yin):
    assert (await yin.flashFee(yin.contract_address, (0, 200)).execute()).result.fee == (0, 0)


@pytest.mark.asyncio
async def test_flashFee_unsupported_token(yin):
    with pytest.raises(StarkException, match="Yin: Unsupported token"):
        await yin.flashFee(0xDEADCA7, (0, 3000)).execute()


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_maxFlashLoan(yin):
    total_yin = (await yin.totalSupply().execute()).result.total_supply
    max_loan_uint = (await yin.maxFlashLoan(yin.contract_address).execute()).result.amount
    max_loan = from_uint(max_loan_uint)

    assert max_loan == int(0.05 * total_yin)


@pytest.mark.asyncio
async def test_maxFlashLoan_unsupported_token(yin):
    assert (await yin.maxFlashLoan(0xDEADCA7).execute()).result.amount == (0, 0)


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_flashLoan(yin, flash_minter):
    mintooor = str_to_felt("mintooor")
    calldata = [True, False]

    initial_balance = (await yin.balanceOf(mintooor).execute()).result.balance
    mint_amount = (await yin.maxFlashLoan(yin.contract_address).execute()).result.amount
    tx = await yin.flashLoan(flash_minter.contract_address, yin.contract_address, mint_amount, calldata).execute(
        caller_address=mintooor
    )

    assert_event_emitted(
        tx,
        yin.contract_address,
        "FlashMint",
        [mintooor, flash_minter.contract_address, yin.contract_address, *mint_amount],
    )

    tx = await flash_minter.get_callback_values().execute()
    cbv = tx.result

    assert cbv.initiator == mintooor
    assert cbv.token == yin.contract_address
    assert cbv.amount == mint_amount
    assert cbv.calldata == calldata

    assert (await yin.balanceOf(mintooor).execute()).result.balance == initial_balance


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_flashLoan_asking_too_much(yin):
    with pytest.raises(StarkException, match="Yin: Flash mint amount exceeds maximum allowed mint amount"):
        await yin.flashLoan(0xC0FFEE, yin.contract_address, MAX_UINT256, []).execute()


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_flashLoan_incorrect_callback_return(yin, flash_minter):
    mint_amount = (await yin.maxFlashLoan(yin.contract_address).execute()).result.amount

    with pytest.raises(StarkException, match="Yin: onFlashLoan callback failed"):
        await yin.flashLoan(flash_minter.contract_address, yin.contract_address, mint_amount, [False, False]).execute()


@pytest.mark.usefixtures("shrine_forge")
@pytest.mark.asyncio
async def test_flashLoan_trying_to_steal(yin, flash_minter):
    mint_amount = (await yin.maxFlashLoan(yin.contract_address).execute()).result.amount

    with pytest.raises(StarkException, match="Shrine: Invalid post flash mint state"):
        await yin.flashLoan(flash_minter.contract_address, yin.contract_address, mint_amount, [True, True]).execute()
