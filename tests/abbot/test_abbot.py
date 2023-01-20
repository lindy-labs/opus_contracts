import pytest
from starkware.starknet.testing.contract import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.abbot.constants import *  # noqa: F403
from tests.utils import (
    SHRINE_OWNER,
    STARKNET_ADDR,
    TROVE1_OWNER,
    TROVE2_OWNER,
    TROVE_1,
    WAD_DECIMALS,
    YangConfig,
    assert_event_emitted,
    from_uint,
    str_to_felt,
    to_uint,
    to_wad,
)

#
# fixtures
#


@pytest.fixture
async def shitcoin(tokens) -> StarknetContract:
    return await tokens("To the moon", "SHIT", WAD_DECIMALS)


@pytest.fixture
async def shrine(shrine_deploy) -> StarknetContract:
    shrine = shrine_deploy
    await shrine.set_ceiling(to_wad(50_000_000)).execute(caller_address=SHRINE_OWNER)
    return shrine


@pytest.fixture
def shitcoin_yang(shitcoin) -> YangConfig:
    empiric_id = str_to_felt("SHIT/USD")
    return YangConfig(shitcoin.contract_address, WAD_DECIMALS, 0, 0, 0, 0, empiric_id)


@pytest.fixture
async def forged_trove_1(abbot, shrine, yangs):
    await abbot.open_trove(
        INITIAL_FORGED_AMOUNT,
        [yang.contract_address for yang in yangs],
        INITIAL_DEPOSITS,
    ).execute(caller_address=TROVE1_OWNER)


@pytest.fixture
async def forged_trove_2(abbot, shrine, yangs):
    await abbot.open_trove(
        INITIAL_FORGED_AMOUNT,
        [yang.contract_address for yang in yangs],
        INITIAL_DEPOSITS,
    ).execute(caller_address=TROVE2_OWNER)


#
# tests
#


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_trove_owners")
@pytest.mark.parametrize("forge_amount", [0, INITIAL_FORGED_AMOUNT])
@pytest.mark.asyncio
async def test_open_trove(abbot, shrine, yangs, forge_amount):

    tx = await abbot.open_trove(
        forge_amount,
        [yang.contract_address for yang in yangs],
        INITIAL_DEPOSITS,
    ).execute(caller_address=TROVE1_OWNER)

    # asserts on the Abbot
    assert_event_emitted(tx, abbot.contract_address, "TroveOpened", [TROVE1_OWNER, TROVE_1])
    assert (await abbot.get_user_trove_ids(TROVE1_OWNER).execute()).result.trove_ids == [TROVE_1]
    assert (await abbot.get_troves_count().execute()).result.count == TROVE_1

    for yang, deposit_amt, expected_yang_amt in zip(yangs, INITIAL_DEPOSITS, INITIAL_YANG_AMTS):
        # asserts on the gates
        assert_event_emitted(
            tx,
            yang.gate_address,
            "Enter",
            [TROVE1_OWNER, TROVE_1, deposit_amt, expected_yang_amt],
        )

        # asserts on the shrine
        assert_event_emitted(
            tx,
            shrine.contract_address,
            "YangUpdated",
            lambda d: d[:2] == [yang.contract_address, expected_yang_amt],
        )
        assert_event_emitted(
            tx, shrine.contract_address, "DepositUpdated", [yang.contract_address, TROVE_1, expected_yang_amt]
        )

        # asserts on the tokens
        # the 0 is to conform to Uint256
        assert_event_emitted(tx, yang.contract_address, "Transfer", [TROVE1_OWNER, yang.gate_address, deposit_amt, 0])

    assert (await shrine.get_trove(TROVE_1).execute()).result.trove.debt == forge_amount


@pytest.mark.asyncio
async def test_open_trove_failures(abbot, steth_yang: YangConfig, shitcoin_yang: YangConfig):
    with pytest.raises(StarkException, match=r"Abbot: Input arguments mismatch: \d != \d"):
        await abbot.open_trove(0, [steth_yang.contract_address], [10, 200]).execute(caller_address=TROVE1_OWNER)

    with pytest.raises(StarkException, match="Abbot: No yangs selected"):
        await abbot.open_trove(0, [], []).execute(caller_address=TROVE1_OWNER)

    with pytest.raises(StarkException, match=rf"Sentinel: Yang {STARKNET_ADDR} is not approved"):
        await abbot.open_trove(0, [shitcoin_yang.contract_address], [10**10]).execute(caller_address=TROVE1_OWNER)


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_trove_owners", "forged_trove_1")
@pytest.mark.asyncio
async def test_close_trove(abbot, shrine, yangs):
    assert (await abbot.get_user_trove_ids(TROVE1_OWNER).execute()).result.trove_ids == [TROVE_1]

    tx = await abbot.close_trove(TROVE_1).execute(caller_address=TROVE1_OWNER)

    # assert the trove still belongs to the user, but has no debt
    assert (await abbot.get_user_trove_ids(TROVE1_OWNER).execute()).result.trove_ids == [TROVE_1]
    assert (await shrine.get_trove(TROVE_1).execute()).result.trove.debt == 0

    for yang, deposit_amt, expected_yang_amt in zip(yangs, INITIAL_DEPOSITS, INITIAL_YANG_AMTS):
        # asserts on the gates
        assert_event_emitted(
            tx,
            yang.gate_address,
            "Exit",
            [TROVE1_OWNER, TROVE_1, deposit_amt, expected_yang_amt],
        )

        # asserts on the shrine
        assert_event_emitted(tx, shrine.contract_address, "YangUpdated", lambda d: d[:2] == [yang.contract_address, 0])
        assert_event_emitted(tx, shrine.contract_address, "DepositUpdated", [yang.contract_address, TROVE_1, 0])

        # asserts on the tokens
        # the 0 is to conform to Uint256
        assert_event_emitted(tx, yang.contract_address, "Transfer", [yang.gate_address, TROVE1_OWNER, deposit_amt, 0])

    assert_event_emitted(tx, shrine.contract_address, "DebtTotalUpdated", [0])  # from melt
    assert_event_emitted(tx, shrine.contract_address, "TroveUpdated", [TROVE_1, 1, 0])


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_trove_owners", "forged_trove_1")
@pytest.mark.asyncio
async def test_close_trove_failures(abbot):
    with pytest.raises(StarkException, match=f"Abbot: Address {TROVE1_OWNER} does not own trove ID 2"):
        await abbot.close_trove(2).execute(caller_address=TROVE1_OWNER)

    with pytest.raises(StarkException, match=f"Abbot: Address {OTHER_USER} does not own trove ID 1"):
        await abbot.close_trove(1).execute(caller_address=OTHER_USER)


@pytest.mark.parametrize("depositor", [TROVE1_OWNER, TROVE2_OWNER])  # melt with trove owner, and non-owner
@pytest.mark.usefixtures("sentinel_with_yangs", "funded_trove_owners", "forged_trove_1")
@pytest.mark.asyncio
async def test_deposit(abbot, shrine, yangs, depositor):
    for yang, deposited_yang, deposit_amt, expected_yang_amt in zip(
        yangs, INITIAL_YANG_AMTS, SUBSEQUENT_DEPOSITS, SUBSEQUENT_YANG_AMTS
    ):

        tx = await abbot.deposit(yang.contract_address, TROVE_1, deposit_amt).execute(caller_address=depositor)

        # check if gates emitted Deposit from TROVE1_OWNER to trove with the right amount
        assert_event_emitted(tx, yang.gate_address, "Enter", [depositor, TROVE_1, deposit_amt, expected_yang_amt])

        expected_yang = deposited_yang + expected_yang_amt
        assert (await shrine.get_deposit(yang.contract_address, TROVE_1).execute()).result.balance == expected_yang

        # depositing 0 should pass, no event on gate (exits early)
        await abbot.deposit(yang.contract_address, TROVE_1, 0).execute(caller_address=depositor)
        assert (await shrine.get_deposit(yang.contract_address, TROVE_1).execute()).result.balance == expected_yang


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_trove_owners", "shrine")
@pytest.mark.asyncio
async def test_deposit_failures(abbot, steth_yang: YangConfig, shitcoin_yang: YangConfig):
    with pytest.raises(StarkException, match="Abbot: Yang address cannot be zero"):
        await abbot.deposit(0, TROVE_1, 0).execute(caller_address=TROVE1_OWNER)

    with pytest.raises(StarkException, match="Abbot: Trove ID cannot be zero"):
        await abbot.deposit(shitcoin_yang.contract_address, 0, 0).execute(caller_address=TROVE1_OWNER)

    # need to open a trove for the next two asserts to test functionality correctly
    tx = await abbot.open_trove(
        INITIAL_FORGED_AMOUNT,
        [steth_yang.contract_address],
        [INITIAL_STETH_DEPOSIT],
    ).execute(caller_address=TROVE1_OWNER)
    # sanity check that a trove was opened
    assert_event_emitted(tx, abbot.contract_address, "TroveOpened", [TROVE1_OWNER, TROVE_1])

    with pytest.raises(StarkException, match=rf"Sentinel: Yang {STARKNET_ADDR} is not approved"):
        await abbot.deposit(shitcoin_yang.contract_address, TROVE_1, to_wad(100_000)).execute(
            caller_address=TROVE1_OWNER
        )

    with pytest.raises(StarkException, match="Abbot: Cannot deposit to a non-existing trove"):
        await abbot.deposit(steth_yang.contract_address, 999, to_wad(1)).execute(caller_address=TROVE1_OWNER)


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_trove_owners", "forged_trove_1")
@pytest.mark.asyncio
async def test_withdraw(abbot, shrine, yangs):
    for yang, deposited_yang, withdraw_asset_amt, withdraw_yang_amt in zip(
        yangs, INITIAL_YANG_AMTS, WITHDRAW_AMTS, WITHDRAW_YANG_AMTS
    ):
        tx = await abbot.withdraw(yang.contract_address, TROVE_1, withdraw_yang_amt).execute(
            caller_address=TROVE1_OWNER
        )

        assert_event_emitted(
            tx,
            yang.gate_address,
            "Exit",
            [TROVE1_OWNER, TROVE_1, withdraw_asset_amt, withdraw_yang_amt],
        )

        assert (
            await shrine.get_deposit(yang.contract_address, TROVE_1).execute()
        ).result.balance == deposited_yang - withdraw_yang_amt


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_trove_owners", "forged_trove_1")
@pytest.mark.asyncio
async def test_withdraw_failures(abbot, steth_yang: YangConfig, shitcoin_yang: YangConfig):
    with pytest.raises(StarkException, match="Abbot: Yang address cannot be zero"):
        await abbot.withdraw(0, TROVE_1, 0).execute(caller_address=TROVE1_OWNER)

    with pytest.raises(StarkException, match=rf"Sentinel: Yang {STARKNET_ADDR} is not approved"):
        await abbot.withdraw(shitcoin_yang.contract_address, TROVE_1, to_wad(100_000)).execute(
            caller_address=TROVE1_OWNER
        )

    with pytest.raises(StarkException, match=f"Abbot: Address {OTHER_USER} does not own trove ID {TROVE_1}"):
        await abbot.withdraw(steth_yang.contract_address, TROVE_1, to_wad(10)).execute(caller_address=OTHER_USER)


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_trove_owners")
@pytest.mark.asyncio
async def test_forge(abbot, steth_yang: YangConfig, shrine):
    await abbot.open_trove(0, [steth_yang.contract_address], [INITIAL_STETH_DEPOSIT]).execute(
        caller_address=TROVE1_OWNER
    )

    forge_amount = to_wad(55)

    tx = await abbot.forge(TROVE_1, forge_amount).execute(caller_address=TROVE1_OWNER)

    # asserting only events particular to the user
    assert_event_emitted(tx, shrine.contract_address, "TroveUpdated", [TROVE_1, 1, forge_amount])
    assert_event_emitted(tx, shrine.contract_address, "Transfer", [0, TROVE1_OWNER, *to_uint(forge_amount)])

    balance = (await shrine.balanceOf(TROVE1_OWNER).execute()).result.balance
    assert from_uint(balance) == forge_amount


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_trove_owners", "forged_trove_1")
@pytest.mark.asyncio
async def test_forge_failures(abbot):
    with pytest.raises(StarkException, match=f"Abbot: Address {OTHER_USER} does not own trove ID {TROVE_1}"):
        amount = to_wad(10)
        await abbot.forge(TROVE_1, amount).execute(caller_address=OTHER_USER)

    with pytest.raises(StarkException, match="Shrine: Trove LTV is too high"):
        amount = to_wad(1_000_000)
        await abbot.forge(TROVE_1, amount).execute(caller_address=TROVE1_OWNER)


@pytest.mark.parametrize("melter", [TROVE1_OWNER, TROVE2_OWNER])  # melt with trove owner, and non-owner
@pytest.mark.parametrize("melt_amt", [to_wad(333), INITIAL_FORGED_AMOUNT * 2])
@pytest.mark.usefixtures("sentinel_with_yangs", "funded_trove_owners", "forged_trove_1", "forged_trove_2")
@pytest.mark.asyncio
async def test_melt(abbot, shrine, melter, melt_amt):
    tx = await abbot.melt(TROVE_1, melt_amt).execute(caller_address=melter)

    if melt_amt > INITIAL_FORGED_AMOUNT:
        melt_amt = INITIAL_FORGED_AMOUNT

    remaining_amount = INITIAL_FORGED_AMOUNT - melt_amt

    # asserting only events particular to the user
    assert_event_emitted(tx, shrine.contract_address, "TroveUpdated", [TROVE_1, 1, remaining_amount])
    assert_event_emitted(tx, shrine.contract_address, "Transfer", [melter, 0, *to_uint(melt_amt)])

    balance = (await shrine.balanceOf(melter).execute()).result.balance
    assert from_uint(balance) == remaining_amount


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_trove_owners", "forged_trove_1")
@pytest.mark.asyncio
async def test_get_trove_owner(abbot):
    assert (await abbot.get_trove_owner(TROVE_1).execute()).result.owner == TROVE1_OWNER
    assert (await abbot.get_trove_owner(789).execute()).result.owner == 0


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_trove_owners", "forged_trove_1")
@pytest.mark.asyncio
async def test_get_user_trove_ids(abbot, steth_yang: YangConfig):
    assert (await abbot.get_user_trove_ids(TROVE1_OWNER).execute()).result.trove_ids == [TROVE_1]
    assert (await abbot.get_user_trove_ids(OTHER_USER).execute()).result.trove_ids == []

    # opening another trove, checking if it gets added to the array
    await abbot.open_trove(0, [steth_yang.contract_address], [to_wad(2)]).execute(caller_address=TROVE1_OWNER)
    assert (await abbot.get_user_trove_ids(TROVE1_OWNER).execute()).result.trove_ids == [TROVE_1, 2]
    assert (await abbot.get_troves_count().execute()).result.count == 2
