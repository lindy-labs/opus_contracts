import pytest
from starkware.starknet.testing.contract import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.constants import MAX_UINT256, SHRINE_OWNER, SHRINE_ROLE_FOR_FLASHMINT
from tests.utils.utils import assert_event_emitted, compile_contract, str_to_felt
from tests.utils.wadray import from_uint, to_uint


@pytest.fixture
async def flashmint(starknet, shrine) -> StarknetContract:
    contract = compile_contract("contracts/flashmint/flashmint.cairo")
    flashmint = await starknet.deploy(contract_class=contract, constructor_calldata=[shrine.contract_address])

    await shrine.grant_role(SHRINE_ROLE_FOR_FLASHMINT, flashmint.contract_address).execute(caller_address=SHRINE_OWNER)

    return flashmint


# mock flash mint receiver
@pytest.fixture
async def flash_minter(starknet) -> StarknetContract:
    contract = compile_contract("tests/flashmint/flash_minter.cairo")
    return await starknet.deploy(contract_class=contract)


@pytest.mark.asyncio
async def test_flashFee(flashmint, shrine):
    assert (await flashmint.flashFee(shrine.contract_address, to_uint(200)).execute()).result.fee == (0, 0)


@pytest.mark.asyncio
async def test_flashFee_unsupported_token(flashmint):
    with pytest.raises(StarkException, match="Flashmint: Unsupported token"):
        await flashmint.flashFee(0xDEADCA7, to_uint(3000)).execute()


@pytest.mark.usefixtures("shrine_forge_trove1")
@pytest.mark.asyncio
async def test_maxFlashLoan(flashmint, shrine):
    total_yin_uint = (await shrine.totalSupply().execute()).result.total_supply
    max_loan_uint = (await flashmint.maxFlashLoan(shrine.contract_address).execute()).result.amount

    total_yin = from_uint(total_yin_uint)
    max_loan = from_uint(max_loan_uint)

    assert total_yin > 0  # sanity check
    assert max_loan == int(0.05 * total_yin)


@pytest.mark.asyncio
async def test_maxFlashLoan_unsupported_token(flashmint):
    assert (await flashmint.maxFlashLoan(0xDEADCA7).execute()).result.amount == (0, 0)


@pytest.mark.usefixtures("shrine_forge_trove1")
@pytest.mark.asyncio
async def test_flashLoan(flashmint, shrine, flash_minter):
    mintooor = str_to_felt("mintooor")
    calldata = [True, False, False]

    initial_balance = (await shrine.balanceOf(mintooor).execute()).result.balance
    mint_amount = (await flashmint.maxFlashLoan(shrine.contract_address).execute()).result.amount
    tx = await flashmint.flashLoan(
        flash_minter.contract_address, shrine.contract_address, mint_amount, calldata
    ).execute(caller_address=mintooor)

    assert_event_emitted(
        tx,
        flashmint.contract_address,
        "FlashMint",
        [mintooor, flash_minter.contract_address, shrine.contract_address, *mint_amount],
    )

    # mint (forge) event
    assert_event_emitted(tx, shrine.contract_address, "Transfer", [0, flash_minter.contract_address, *mint_amount])

    # burn (melt) event
    assert_event_emitted(tx, shrine.contract_address, "Transfer", [flash_minter.contract_address, 0, *mint_amount])

    tx = await flash_minter.get_callback_values().execute()
    cbv = tx.result

    assert cbv.initiator == mintooor
    assert cbv.token == shrine.contract_address
    assert cbv.amount == mint_amount
    assert cbv.calldata == calldata

    assert (await shrine.balanceOf(mintooor).execute()).result.balance == initial_balance


@pytest.mark.usefixtures("shrine_forge_trove1")
@pytest.mark.asyncio
async def test_flashLoan_asking_too_much(flashmint, shrine):
    with pytest.raises(StarkException, match="Flashmint: Amount exceeds maximum allowed mint limit"):
        await flashmint.flashLoan(0xC0FFEE, shrine.contract_address, MAX_UINT256, []).execute()


@pytest.mark.usefixtures("shrine_forge_trove1")
@pytest.mark.asyncio
async def test_flashLoan_incorrect_callback_return(flashmint, shrine, flash_minter):
    mint_amount = (await flashmint.maxFlashLoan(shrine.contract_address).execute()).result.amount

    with pytest.raises(StarkException, match="Flashmint: onFlashLoan callback failed"):
        await flashmint.flashLoan(
            flash_minter.contract_address, shrine.contract_address, mint_amount, [False, False, False]
        ).execute()


@pytest.mark.usefixtures("shrine_forge_trove1")
@pytest.mark.asyncio
async def test_flashLoan_trying_to_steal(flashmint, shrine, flash_minter):
    mint_amount = (await flashmint.maxFlashLoan(shrine.contract_address).execute()).result.amount

    with pytest.raises(StarkException, match="Shrine: Not enough yin to melt debt"):
        await flashmint.flashLoan(
            flash_minter.contract_address, shrine.contract_address, mint_amount, [True, True, False]
        ).execute()


@pytest.mark.usefixtures("shrine_forge_trove1")
@pytest.mark.asyncio
async def test_flashLoan_not_reentrant(flashmint, shrine, flash_minter):
    mint_amount = (await flashmint.maxFlashLoan(shrine.contract_address).execute()).result.amount

    with pytest.raises(StarkException):
        await flashmint.flashLoan(
            flash_minter.contract_address, shrine.contract_address, mint_amount, [True, False, True]
        ).execute()
