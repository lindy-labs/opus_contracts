import pytest
from starkware.starknet.testing.contract import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.abbot.constants import *  # noqa: F403
from tests.utils import (
    AURA_USER_1,
    AURA_USER_2,
    SHRINE_OWNER,
    STARKNET_ADDR,
    TROVE_1,
    YangConfig,
    assert_event_emitted,
    from_uint,
    to_wad,
)

#
# fixtures
#


@pytest.fixture
async def shitcoin(tokens) -> StarknetContract:
    return await tokens("To the moon", "SHIT", 18, (2**128 - 1, 0), SHITCOIN_OWNER)


@pytest.fixture
async def shrine(shrine_deploy) -> StarknetContract:
    shrine = shrine_deploy
    await shrine.set_ceiling(to_wad(50_000_000)).execute(caller_address=SHRINE_OWNER)
    return shrine


@pytest.fixture
def shitcoin_yang(shitcoin) -> YangConfig:
    return YangConfig(shitcoin.contract_address, 0, 0, 0, 0)


@pytest.fixture
async def aura_user_1_with_trove_id_1(abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig):
    await abbot.open_trove(
        INITIAL_FORGED_AMOUNT,
        [steth_yang.contract_address, doge_yang.contract_address],
        [INITIAL_STETH_DEPOSIT, INITIAL_DOGE_DEPOSIT],
    ).execute(caller_address=AURA_USER_1)


@pytest.fixture
async def aura_user_2_with_trove_id_2(abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig):
    await abbot.open_trove(
        INITIAL_FORGED_AMOUNT,
        [steth_yang.contract_address, doge_yang.contract_address],
        [INITIAL_STETH_DEPOSIT, INITIAL_DOGE_DEPOSIT],
    ).execute(caller_address=AURA_USER_2)


#
# tests
#


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_aura_user_1")
@pytest.mark.parametrize("forge_amount", [0, INITIAL_FORGED_AMOUNT])
@pytest.mark.asyncio
async def test_open_trove(abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig, forge_amount):

    tx = await abbot.open_trove(
        forge_amount,
        [steth_yang.contract_address, doge_yang.contract_address],
        [INITIAL_STETH_DEPOSIT, INITIAL_DOGE_DEPOSIT],
    ).execute(caller_address=AURA_USER_1)

    # asserts on the Abbot
    assert_event_emitted(tx, abbot.contract_address, "TroveOpened", [AURA_USER_1, TROVE_1])
    assert (await abbot.get_user_trove_ids(AURA_USER_1).execute()).result.trove_ids == [TROVE_1]
    assert (await abbot.get_troves_count().execute()).result.count == TROVE_1

    # asserts on the gates
    assert_event_emitted(
        tx,
        steth_yang.gate_address,
        "Enter",
        lambda d: d[:2] == [AURA_USER_1, TROVE_1] and d[-1] == INITIAL_STETH_DEPOSIT,
    )
    assert_event_emitted(
        tx,
        doge_yang.gate_address,
        "Enter",
        lambda d: d[:2] == [AURA_USER_1, TROVE_1] and d[-1] == INITIAL_DOGE_DEPOSIT,
    )

    # asserts on the shrine
    assert_event_emitted(
        tx,
        shrine.contract_address,
        "YangUpdated",
        lambda d: d[:2] == [steth_yang.contract_address, INITIAL_STETH_DEPOSIT],
    )
    assert_event_emitted(
        tx,
        shrine.contract_address,
        "YangUpdated",
        lambda d: d[:2] == [doge_yang.contract_address, INITIAL_DOGE_DEPOSIT],
    )
    assert_event_emitted(
        tx, shrine.contract_address, "DepositUpdated", [steth_yang.contract_address, TROVE_1, INITIAL_STETH_DEPOSIT]
    )
    assert_event_emitted(
        tx, shrine.contract_address, "DepositUpdated", [doge_yang.contract_address, TROVE_1, INITIAL_DOGE_DEPOSIT]
    )
    assert (await shrine.get_trove(TROVE_1).execute()).result.trove.debt == forge_amount

    # asserts on the tokens
    # the 0 is to conform to Uint256
    assert_event_emitted(
        tx, steth_yang.contract_address, "Transfer", [AURA_USER_1, steth_yang.gate_address, INITIAL_STETH_DEPOSIT, 0]
    )
    assert_event_emitted(
        tx, doge_yang.contract_address, "Transfer", [AURA_USER_1, doge_yang.gate_address, INITIAL_DOGE_DEPOSIT, 0]
    )


@pytest.mark.asyncio
async def test_open_trove_failures(abbot, steth_yang: YangConfig, shitcoin_yang: YangConfig):
    with pytest.raises(StarkException, match=r"Abbot: Input arguments mismatch: \d != \d"):
        await abbot.open_trove(0, [steth_yang.contract_address], [10, 200]).execute(caller_address=AURA_USER_1)

    with pytest.raises(StarkException, match="Abbot: No yangs selected"):
        await abbot.open_trove(0, [], []).execute(caller_address=AURA_USER_1)

    with pytest.raises(StarkException, match=rf"Abbot: Yang {STARKNET_ADDR} is not approved"):
        await abbot.open_trove(0, [shitcoin_yang.contract_address], [10**10]).execute(caller_address=AURA_USER_1)


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_aura_user_1", "aura_user_1_with_trove_id_1")
@pytest.mark.asyncio
async def test_close_trove(abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig):
    assert (await abbot.get_user_trove_ids(AURA_USER_1).execute()).result.trove_ids == [TROVE_1]

    tx = await abbot.close_trove(TROVE_1).execute(caller_address=AURA_USER_1)

    # assert the trove still belongs to the user, but has no debt
    assert (await abbot.get_user_trove_ids(AURA_USER_1).execute()).result.trove_ids == [TROVE_1]
    assert (await shrine.get_trove(TROVE_1).execute()).result.trove.debt == 0

    # asserts on the gates
    assert_event_emitted(
        tx,
        steth_yang.gate_address,
        "Exit",
        lambda d: d[:2] == [AURA_USER_1, TROVE_1] and d[-1] == INITIAL_STETH_DEPOSIT,
    )
    assert_event_emitted(
        tx,
        doge_yang.gate_address,
        "Exit",
        lambda d: d[:2] == [AURA_USER_1, TROVE_1] and d[-1] == INITIAL_DOGE_DEPOSIT,
    )

    # asserts on the shrine
    assert_event_emitted(
        tx, shrine.contract_address, "YangUpdated", lambda d: d[:2] == [steth_yang.contract_address, 0]
    )
    assert_event_emitted(tx, shrine.contract_address, "YangUpdated", lambda d: d[:2] == [doge_yang.contract_address, 0])
    assert_event_emitted(tx, shrine.contract_address, "DepositUpdated", [steth_yang.contract_address, TROVE_1, 0])
    assert_event_emitted(tx, shrine.contract_address, "DepositUpdated", [doge_yang.contract_address, TROVE_1, 0])
    assert_event_emitted(tx, shrine.contract_address, "DebtTotalUpdated", [0])  # from melt
    assert_event_emitted(tx, shrine.contract_address, "TroveUpdated", [TROVE_1, 1, 0])

    # asserts on the tokens
    # the 0 is to conform to Uint256
    assert_event_emitted(
        tx, steth_yang.contract_address, "Transfer", [steth_yang.gate_address, AURA_USER_1, INITIAL_STETH_DEPOSIT, 0]
    )
    assert_event_emitted(
        tx, doge_yang.contract_address, "Transfer", [doge_yang.gate_address, AURA_USER_1, INITIAL_DOGE_DEPOSIT, 0]
    )


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_aura_user_1", "aura_user_1_with_trove_id_1")
@pytest.mark.asyncio
async def test_close_trove_failures(abbot):
    with pytest.raises(StarkException, match=f"Abbot: Address {AURA_USER_1} does not own trove ID 2"):
        await abbot.close_trove(2).execute(caller_address=AURA_USER_1)

    with pytest.raises(StarkException, match=f"Abbot: Address {OTHER_USER} does not own trove ID 1"):
        await abbot.close_trove(1).execute(caller_address=OTHER_USER)


@pytest.mark.parametrize("depositor", [AURA_USER_1, AURA_USER_2])  # melt with trove owner, and non-owner
@pytest.mark.usefixtures(
    "sentinel_with_yangs", "funded_aura_user_1", "aura_user_1_with_trove_id_1", "funded_aura_user_2"
)
@pytest.mark.asyncio
async def test_deposit(abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig, depositor):
    fresh_steth_deposit = to_wad(1)
    fresh_doge_deposit = to_wad(200)

    tx1 = await abbot.deposit(steth_yang.contract_address, TROVE_1, fresh_steth_deposit).execute(
        caller_address=depositor
    )
    tx2 = await abbot.deposit(doge_yang.contract_address, TROVE_1, fresh_doge_deposit).execute(caller_address=depositor)

    # check if gates emitted Deposit from AURA_USER_1 to trove with the right amount
    assert_event_emitted(
        tx1, steth_yang.gate_address, "Enter", lambda d: d[:3] == [depositor, TROVE_1, fresh_steth_deposit]
    )
    assert_event_emitted(
        tx2, doge_yang.gate_address, "Enter", lambda d: d[:3] == [depositor, TROVE_1, fresh_doge_deposit]
    )

    assert (
        await shrine.get_deposit(steth_yang.contract_address, TROVE_1).execute()
    ).result.balance == INITIAL_STETH_DEPOSIT + fresh_steth_deposit
    assert (
        await shrine.get_deposit(doge_yang.contract_address, TROVE_1).execute()
    ).result.balance == INITIAL_DOGE_DEPOSIT + fresh_doge_deposit

    # depositing 0 should pass, no event on gate (exits early)
    await abbot.deposit(steth_yang.contract_address, TROVE_1, 0).execute(caller_address=depositor)
    assert (
        await shrine.get_deposit(steth_yang.contract_address, TROVE_1).execute()
    ).result.balance == INITIAL_STETH_DEPOSIT + fresh_steth_deposit


@pytest.mark.usefixtures("sentinel_with_yangs")
@pytest.mark.asyncio
async def test_deposit_failures(abbot, steth_yang: YangConfig, shitcoin_yang: YangConfig):
    with pytest.raises(StarkException, match="Abbot: Yang address cannot be zero"):
        await abbot.deposit(0, TROVE_1, 0).execute(caller_address=AURA_USER_1)

    with pytest.raises(StarkException, match=rf"Abbot: Yang {STARKNET_ADDR} is not approved"):
        await abbot.deposit(shitcoin_yang.contract_address, TROVE_1, to_wad(100_000)).execute(
            caller_address=AURA_USER_1
        )


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_aura_user_1", "aura_user_1_with_trove_id_1")
@pytest.mark.asyncio
async def test_withdraw(abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig):
    steth_withdraw_amount = to_wad(2)
    doge_withdraw_amount = to_wad(50)

    tx1 = await abbot.withdraw(steth_yang.contract_address, TROVE_1, steth_withdraw_amount).execute(
        caller_address=AURA_USER_1
    )

    tx2 = await abbot.withdraw(doge_yang.contract_address, TROVE_1, doge_withdraw_amount).execute(
        caller_address=AURA_USER_1
    )

    assert_event_emitted(
        tx1,
        steth_yang.gate_address,
        "Exit",
        lambda d: d[:2] == [AURA_USER_1, TROVE_1] and d[-1] == steth_withdraw_amount,
    )

    assert_event_emitted(
        tx2,
        doge_yang.gate_address,
        "Exit",
        lambda d: d[:2] == [AURA_USER_1, TROVE_1] and d[-1] == doge_withdraw_amount,
    )

    assert (
        await shrine.get_deposit(steth_yang.contract_address, TROVE_1).execute()
    ).result.balance == INITIAL_STETH_DEPOSIT - steth_withdraw_amount
    assert (
        await shrine.get_deposit(doge_yang.contract_address, TROVE_1).execute()
    ).result.balance == INITIAL_DOGE_DEPOSIT - doge_withdraw_amount


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_aura_user_1", "aura_user_1_with_trove_id_1")
@pytest.mark.asyncio
async def test_withdraw_failures(abbot, steth_yang: YangConfig, shitcoin_yang: YangConfig):
    with pytest.raises(StarkException, match="Abbot: Yang address cannot be zero"):
        await abbot.withdraw(0, TROVE_1, 0).execute(caller_address=AURA_USER_1)

    with pytest.raises(StarkException, match=rf"Abbot: Yang {STARKNET_ADDR} is not approved"):
        await abbot.withdraw(shitcoin_yang.contract_address, TROVE_1, to_wad(100_000)).execute(
            caller_address=AURA_USER_1
        )

    with pytest.raises(StarkException, match=f"Abbot: Address {OTHER_USER} does not own trove ID {TROVE_1}"):
        await abbot.withdraw(steth_yang.contract_address, TROVE_1, to_wad(10)).execute(caller_address=OTHER_USER)


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_aura_user_1")
@pytest.mark.asyncio
async def test_forge(abbot, steth_yang: YangConfig, yin, shrine):
    await abbot.open_trove(0, [steth_yang.contract_address], [INITIAL_STETH_DEPOSIT]).execute(
        caller_address=AURA_USER_1
    )

    forge_amount = to_wad(55)

    tx = await abbot.forge(TROVE_1, forge_amount).execute(caller_address=AURA_USER_1)

    # asserting only events particular to the user
    assert_event_emitted(tx, shrine.contract_address, "TroveUpdated", [TROVE_1, 1, forge_amount])
    assert_event_emitted(tx, shrine.contract_address, "YinUpdated", [AURA_USER_1, forge_amount])

    balance = (await yin.balanceOf(AURA_USER_1).execute()).result.balance
    assert from_uint(balance) == forge_amount


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_aura_user_1", "aura_user_1_with_trove_id_1")
@pytest.mark.asyncio
async def test_forge_failures(abbot):
    with pytest.raises(StarkException, match=f"Abbot: Address {OTHER_USER} does not own trove ID {TROVE_1}"):
        amount = to_wad(10)
        await abbot.forge(TROVE_1, amount).execute(caller_address=OTHER_USER)

    with pytest.raises(StarkException, match="Shrine: Trove LTV is too high"):
        amount = to_wad(1_000_000)
        await abbot.forge(TROVE_1, amount).execute(caller_address=AURA_USER_1)


@pytest.mark.parametrize("melter", [AURA_USER_1, AURA_USER_2])  # melt with trove owner, and non-owner
@pytest.mark.parametrize("melt_amt", [to_wad(333), INITIAL_FORGED_AMOUNT * 2])
@pytest.mark.usefixtures(
    "sentinel_with_yangs",
    "funded_aura_user_1",
    "aura_user_1_with_trove_id_1",
    "funded_aura_user_2",
    "aura_user_2_with_trove_id_2",
)
@pytest.mark.asyncio
async def test_melt(abbot, yin, shrine, melter, melt_amt):
    melt_amount = to_wad(333)

    tx = await abbot.melt(TROVE_1, melt_amount).execute(caller_address=melter)

    if melt_amount > INITIAL_FORGED_AMOUNT:
        melt_amount = INITIAL_FORGED_AMOUNT

    remaining_amount = INITIAL_FORGED_AMOUNT - melt_amount

    # asserting only events particular to the user
    assert_event_emitted(tx, shrine.contract_address, "TroveUpdated", [TROVE_1, 1, remaining_amount])
    assert_event_emitted(tx, shrine.contract_address, "YinUpdated", [melter, remaining_amount])

    balance = (await yin.balanceOf(melter).execute()).result.balance
    assert from_uint(balance) == remaining_amount


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_aura_user_1", "aura_user_1_with_trove_id_1")
@pytest.mark.asyncio
async def test_get_trove_owner(abbot):
    assert (await abbot.get_trove_owner(TROVE_1).execute()).result.owner == AURA_USER_1
    assert (await abbot.get_trove_owner(789).execute()).result.owner == 0


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_aura_user_1", "aura_user_1_with_trove_id_1")
@pytest.mark.asyncio
async def test_get_user_trove_ids(abbot, steth_yang: YangConfig):
    assert (await abbot.get_user_trove_ids(AURA_USER_1).execute()).result.trove_ids == [TROVE_1]
    assert (await abbot.get_user_trove_ids(OTHER_USER).execute()).result.trove_ids == []

    # opening another trove, checking if it gets added to the array
    await abbot.open_trove(0, [steth_yang.contract_address], [to_wad(2)]).execute(caller_address=AURA_USER_1)
    assert (await abbot.get_user_trove_ids(AURA_USER_1).execute()).result.trove_ids == [TROVE_1, 2]
    assert (await abbot.get_troves_count().execute()).result.count == 2
