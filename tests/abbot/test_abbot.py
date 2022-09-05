from collections import namedtuple
from enum import IntEnum

import pytest
from starkware.starknet.testing.contract import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.gate.rebasing_yang.constants import ABBOT_ROLE
from tests.shrine.constants import ShrineRoles
from tests.utils import RAY_PERCENT, SHRINE_OWNER, assert_event_emitted, compile_contract, str_to_felt, to_wad

UINT256_MAX = (2**128 - 1, 2**128 - 1)
STARKNET_ADDR = r"-?\d+"  # addresses are sometimes printed as negative numbers, hence the -?

YangConfig = namedtuple("YangConfig", "contract_address ceiling threshold price_wad gate_address")


#
# users
#

ABBOT_OWNER = str_to_felt("abbot owner")
GATE_OWNER = str_to_felt("gate owner")
STETH_OWNER = str_to_felt("steth owner")
DOGE_OWNER = str_to_felt("doge owner")
SHITCOIN_OWNER = str_to_felt("shitcoin owner")
AURA_USER = str_to_felt("aura user")
OTHER_USER = str_to_felt("other user")


#
# module consts
#

INITIAL_STETH_DEPOSIT = to_wad(20)
INITIAL_DOGE_DEPOSIT = to_wad(1000)
INITIAL_FORGED_AMOUNT = to_wad(4000)
TROVE_1 = 1  # first trove (and in most cases, only one)


class AbbotRoles(IntEnum):
    ADD_YANG = 2**0


#
# fixtures
#


@pytest.fixture
async def steth_token(tokens) -> StarknetContract:
    return await tokens("Lido Staked ETH", "stETH", 18, (to_wad(100_000), 0), STETH_OWNER)


@pytest.fixture
async def doge_token(tokens) -> StarknetContract:
    return await tokens("Dogecoin", "DOGE", 18, (to_wad(10_000_000), 0), DOGE_OWNER)


@pytest.fixture
async def shitcoin(tokens) -> StarknetContract:
    return await tokens("To the moon", "SHIT", 18, (2**128 - 1, 0), SHITCOIN_OWNER)


@pytest.fixture
async def shrine(shrine_deploy) -> StarknetContract:
    shrine = shrine_deploy
    await shrine.set_ceiling(to_wad(50_000_000)).execute(caller_address=SHRINE_OWNER)
    return shrine


@pytest.fixture
async def steth_gate(request, starknet, abbot, shrine, steth_token) -> StarknetContract:
    """
    Deploys an instance of the Gate module, without any autocompounding or tax.
    """
    contract = compile_contract("contracts/gate/rebasing_yang/gate.cairo", request)

    gate = await starknet.deploy(
        contract_class=contract,
        constructor_calldata=[
            GATE_OWNER,
            shrine.contract_address,
            steth_token.contract_address,
        ],
    )

    # auth Abbot in Gate
    await gate.grant_role(ABBOT_ROLE, abbot.contract_address).execute(caller_address=GATE_OWNER)

    # auth Gate in Shrine
    roles = ShrineRoles.DEPOSIT + ShrineRoles.WITHDRAW
    await shrine.grant_role(roles, gate.contract_address).execute(caller_address=SHRINE_OWNER)

    return gate


@pytest.fixture
async def doge_gate(request, starknet, abbot, shrine, doge_token) -> StarknetContract:
    """
    Deploys an instance of the Gate module, without any autocompounding or tax.
    """
    contract = compile_contract("contracts/gate/rebasing_yang/gate.cairo", request)
    gate = await starknet.deploy(
        contract_class=contract,
        constructor_calldata=[
            GATE_OWNER,
            shrine.contract_address,
            doge_token.contract_address,
        ],
    )

    # auth Abbot in Gate
    await gate.grant_role(ABBOT_ROLE, abbot.contract_address).execute(caller_address=GATE_OWNER)

    # auth Gate in Shrine
    roles = ShrineRoles.DEPOSIT + ShrineRoles.WITHDRAW
    await shrine.grant_role(roles, gate.contract_address).execute(caller_address=SHRINE_OWNER)

    return gate


@pytest.fixture
def steth_yang(steth_token, steth_gate) -> YangConfig:
    ceiling = to_wad(1_000_000)
    threshold = 90 * RAY_PERCENT
    price_wad = to_wad(2000)
    return YangConfig(steth_token.contract_address, ceiling, threshold, price_wad, steth_gate.contract_address)


@pytest.fixture
def doge_yang(doge_token, doge_gate) -> YangConfig:
    ceiling = to_wad(100_000_000)
    threshold = 20 * RAY_PERCENT
    price_wad = to_wad(0.07)
    return YangConfig(doge_token.contract_address, ceiling, threshold, price_wad, doge_gate.contract_address)


@pytest.fixture
def shitcoin_yang(shitcoin) -> YangConfig:
    return YangConfig(shitcoin.contract_address, 0, 0, 0, 0)


@pytest.fixture
async def abbot(request, starknet, shrine) -> StarknetContract:
    abbot_contract = compile_contract("contracts/abbot/abbot.cairo", request)
    abbot = await starknet.deploy(
        contract_class=abbot_contract, constructor_calldata=[shrine.contract_address, ABBOT_OWNER]
    )

    # auth Abbot in Shrine
    # TODO: eventually remove ADD_YANG and SET_THRESHOLD from the Abbot
    #       https://github.com/lindy-labs/aura_contracts/issues/105
    roles = ShrineRoles.FORGE + ShrineRoles.MELT + ShrineRoles.ADD_YANG + ShrineRoles.SET_THRESHOLD
    await shrine.grant_role(roles, abbot.contract_address).execute(caller_address=SHRINE_OWNER)

    # allow ABBOT_OWNER to call add_yang
    await abbot.grant_role(AbbotRoles.ADD_YANG.value, ABBOT_OWNER).execute(caller_address=ABBOT_OWNER)

    return abbot


@pytest.fixture
async def abbot_with_yangs(abbot, steth_yang: YangConfig, doge_yang: YangConfig):
    for yang in (steth_yang, doge_yang):
        await abbot.add_yang(
            yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address
        ).execute(caller_address=ABBOT_OWNER)


@pytest.fixture
async def funded_aura_user(steth_token, steth_yang: YangConfig, doge_token, doge_yang: YangConfig):
    # fund the user with bags
    await steth_token.transfer(AURA_USER, (to_wad(1_000), 0)).execute(caller_address=STETH_OWNER)
    await doge_token.transfer(AURA_USER, (to_wad(1_000_000), 0)).execute(caller_address=DOGE_OWNER)

    # user approves Aura gates to spend bags
    await max_approve(steth_token, AURA_USER, steth_yang.gate_address)
    await max_approve(doge_token, AURA_USER, doge_yang.gate_address)


@pytest.fixture
async def aura_user_with_first_trove(abbot, steth_yang: YangConfig, doge_yang: YangConfig):
    await abbot.open_trove(
        INITIAL_FORGED_AMOUNT,
        [steth_yang.contract_address, doge_yang.contract_address],
        [INITIAL_STETH_DEPOSIT, INITIAL_DOGE_DEPOSIT],
    ).execute(caller_address=AURA_USER)


#
# helpers
#


async def max_approve(token: StarknetContract, owner_addr: int, spender_addr: int):
    await token.approve(spender_addr, UINT256_MAX).execute(caller_address=owner_addr)


#
# tests
#


@pytest.mark.usefixtures("abbot_with_yangs")
@pytest.mark.asyncio
async def test_abbot_setup(abbot, steth_yang: YangConfig, doge_yang: YangConfig):
    assert (await abbot.get_admin().execute()).result.address == ABBOT_OWNER
    yang_addrs = (await abbot.get_yang_addresses().execute()).result.addresses
    assert len(yang_addrs) == 2
    assert steth_yang.contract_address in yang_addrs
    assert doge_yang.contract_address in yang_addrs


@pytest.mark.asyncio
async def test_add_yang(abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig):
    yangs = (steth_yang, doge_yang)
    for idx, yang in enumerate(yangs):
        tx = await abbot.add_yang(
            yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address
        ).execute(caller_address=ABBOT_OWNER)

        assert_event_emitted(tx, abbot.contract_address, "YangAdded", [yang.contract_address, yang.gate_address])
        # this assert on an event emitted from the shrine contract serves as a proxy
        # to see if the Shrine was actually called (IShrine.add_yang)
        assert_event_emitted(
            tx,
            shrine.contract_address,
            "YangAdded",
            [yang.contract_address, idx + 1, yang.ceiling, yang.price_wad],
        )

    addrs = (await abbot.get_yang_addresses().execute()).result.addresses
    assert len(addrs) == len(yangs)
    for i in range(len(yangs)):
        assert addrs[i] in (y.contract_address for y in yangs)


@pytest.mark.asyncio
async def test_add_yang_failures(abbot, steth_yang: YangConfig, doge_yang: YangConfig):

    yang = steth_yang

    # test reverting on unathorized actor calling add_yang
    with pytest.raises(StarkException, match=r"AccessControl: caller is missing role \d+"):
        await abbot.add_yang(
            yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address
        ).execute(caller_address=OTHER_USER)

    # test reverting on yang address equal 0
    with pytest.raises(StarkException, match="Abbot: address cannot be zero"):
        await abbot.add_yang(0, yang.ceiling, yang.threshold, yang.price_wad, 0xDEADBEEF).execute(
            caller_address=ABBOT_OWNER
        )

    # test reverting on gate address equal 0
    with pytest.raises(StarkException, match="Abbot: address cannot be zero"):
        await abbot.add_yang(0xDEADBEEF, yang.ceiling, yang.threshold, yang.price_wad, 0).execute(
            caller_address=ABBOT_OWNER
        )

    # test reverting on trying to add the same yang / gate combo
    await abbot.add_yang(
        yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address
    ).execute(caller_address=ABBOT_OWNER)
    with pytest.raises(StarkException, match="Abbot: yang already added"):
        await abbot.add_yang(
            yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address
        ).execute(caller_address=ABBOT_OWNER)

    # test reverting when the Gate is for a different yang
    yang = doge_yang
    with pytest.raises(StarkException, match="Abbot: yang address does not match Gate's asset"):
        await abbot.add_yang(
            yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, steth_yang.gate_address
        ).execute(caller_address=ABBOT_OWNER)


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user")
@pytest.mark.parametrize("forge_amount", [0, INITIAL_FORGED_AMOUNT])
@pytest.mark.asyncio
async def test_open_trove(abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig, forge_amount):
    tx = await abbot.open_trove(
        forge_amount,
        [steth_yang.contract_address, doge_yang.contract_address],
        [INITIAL_STETH_DEPOSIT, INITIAL_DOGE_DEPOSIT],
    ).execute(caller_address=AURA_USER)

    # asserts on the Abbot
    assert_event_emitted(tx, abbot.contract_address, "TroveOpened", [AURA_USER, TROVE_1])
    assert (await abbot.get_user_trove_ids(AURA_USER).execute()).result.trove_ids == [TROVE_1]
    assert (await abbot.get_troves_count().execute()).result.ufelt == TROVE_1

    # asserts on the gates
    assert_event_emitted(
        tx,
        steth_yang.gate_address,
        "Deposit",
        lambda d: d[:2] == [AURA_USER, TROVE_1] and d[-1] == INITIAL_STETH_DEPOSIT,
    )
    assert_event_emitted(
        tx,
        doge_yang.gate_address,
        "Deposit",
        lambda d: d[:2] == [AURA_USER, TROVE_1] and d[-1] == INITIAL_DOGE_DEPOSIT,
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
        tx, steth_yang.contract_address, "Transfer", [AURA_USER, steth_yang.gate_address, INITIAL_STETH_DEPOSIT, 0]
    )
    assert_event_emitted(
        tx, doge_yang.contract_address, "Transfer", [AURA_USER, doge_yang.gate_address, INITIAL_DOGE_DEPOSIT, 0]
    )


@pytest.mark.asyncio
async def test_open_trove_failures(abbot, steth_yang: YangConfig, shitcoin_yang: YangConfig):
    with pytest.raises(StarkException, match=r"Abbot: input arguments mismatch: \d != \d"):
        await abbot.open_trove(0, [steth_yang.contract_address], [10, 200]).execute(caller_address=AURA_USER)

    with pytest.raises(StarkException, match="Abbot: no yangs selected"):
        await abbot.open_trove(0, [], []).execute(caller_address=AURA_USER)

    with pytest.raises(StarkException, match=rf"Abbot: yang {STARKNET_ADDR} is not approved"):
        await abbot.open_trove(0, [shitcoin_yang.contract_address], [10**10]).execute(caller_address=AURA_USER)


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_close_trove(abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig):
    assert (await abbot.get_user_trove_ids(AURA_USER).execute()).result.trove_ids == [TROVE_1]

    tx = await abbot.close_trove(TROVE_1).execute(caller_address=AURA_USER)

    # assert the trove still belongs to the user, but has no debt
    assert (await abbot.get_user_trove_ids(AURA_USER).execute()).result.trove_ids == [TROVE_1]
    assert (await shrine.get_trove(TROVE_1).execute()).result.trove.debt == 0

    # asserts on the gates
    assert_event_emitted(
        tx,
        steth_yang.gate_address,
        "Withdraw",
        lambda d: d[:2] == [AURA_USER, TROVE_1] and d[-1] == INITIAL_STETH_DEPOSIT,
    )
    assert_event_emitted(
        tx,
        doge_yang.gate_address,
        "Withdraw",
        lambda d: d[:2] == [AURA_USER, TROVE_1] and d[-1] == INITIAL_DOGE_DEPOSIT,
    )

    # asserts on the shrine
    assert_event_emitted(
        tx, shrine.contract_address, "YangUpdated", lambda d: d[:2] == [steth_yang.contract_address, 0]
    )
    assert_event_emitted(tx, shrine.contract_address, "YangUpdated", lambda d: d[:2] == [doge_yang.contract_address, 0])
    assert_event_emitted(tx, shrine.contract_address, "DepositUpdated", [steth_yang.contract_address, TROVE_1, 0])
    assert_event_emitted(tx, shrine.contract_address, "DepositUpdated", [doge_yang.contract_address, TROVE_1, 0])
    assert_event_emitted(tx, shrine.contract_address, "DebtTotalUpdated", [0])  # from melt
    assert_event_emitted(tx, shrine.contract_address, "TroveUpdated", [TROVE_1, 0, 0])

    # asserts on the tokens
    # the 0 is to conform to Uint256
    assert_event_emitted(
        tx, steth_yang.contract_address, "Transfer", [steth_yang.gate_address, AURA_USER, INITIAL_STETH_DEPOSIT, 0]
    )
    assert_event_emitted(
        tx, doge_yang.contract_address, "Transfer", [doge_yang.gate_address, AURA_USER, INITIAL_DOGE_DEPOSIT, 0]
    )


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_close_trove_failures(abbot):
    with pytest.raises(StarkException, match=f"Abbot: address {AURA_USER} does not own trove ID 2"):
        await abbot.close_trove(2).execute(caller_address=AURA_USER)

    with pytest.raises(StarkException, match=f"Abbot: address {OTHER_USER} does not own trove ID 1"):
        await abbot.close_trove(1).execute(caller_address=OTHER_USER)


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_deposit(abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig):
    fresh_steth_deposit = to_wad(1)
    fresh_doge_deposit = to_wad(200)

    tx1 = await abbot.deposit(steth_yang.contract_address, TROVE_1, fresh_steth_deposit).execute(
        caller_address=AURA_USER
    )
    tx2 = await abbot.deposit(doge_yang.contract_address, TROVE_1, fresh_doge_deposit).execute(caller_address=AURA_USER)

    # check if gates emitted Deposit from AURA_USER to trove with the right amount
    assert_event_emitted(
        tx1, steth_yang.gate_address, "Deposit", lambda d: d[:3] == [AURA_USER, TROVE_1, fresh_steth_deposit]
    )
    assert_event_emitted(
        tx2, doge_yang.gate_address, "Deposit", lambda d: d[:3] == [AURA_USER, TROVE_1, fresh_doge_deposit]
    )

    assert (
        await shrine.get_deposit(steth_yang.contract_address, TROVE_1).execute()
    ).result.wad == INITIAL_STETH_DEPOSIT + fresh_steth_deposit
    assert (
        await shrine.get_deposit(doge_yang.contract_address, TROVE_1).execute()
    ).result.wad == INITIAL_DOGE_DEPOSIT + fresh_doge_deposit

    # depositing 0 should pass, no event on gate (exits early)
    await abbot.deposit(steth_yang.contract_address, TROVE_1, 0).execute(caller_address=AURA_USER)
    assert (
        await shrine.get_deposit(steth_yang.contract_address, TROVE_1).execute()
    ).result.wad == INITIAL_STETH_DEPOSIT + fresh_steth_deposit


@pytest.mark.usefixtures("abbot_with_yangs")
@pytest.mark.asyncio
async def test_deposit_failures(abbot, steth_yang: YangConfig, shitcoin_yang: YangConfig):
    with pytest.raises(StarkException, match="Abbot: yang address cannot be zero"):
        await abbot.deposit(0, TROVE_1, 0).execute(caller_address=AURA_USER)

    with pytest.raises(StarkException, match=rf"Abbot: yang {STARKNET_ADDR} is not approved"):
        await abbot.deposit(shitcoin_yang.contract_address, TROVE_1, to_wad(100_000)).execute(caller_address=AURA_USER)

    with pytest.raises(StarkException, match=f"Abbot: address {OTHER_USER} does not own trove ID {TROVE_1}"):
        await abbot.deposit(steth_yang.contract_address, TROVE_1, to_wad(1)).execute(caller_address=OTHER_USER)

    nope_trove = 2  # trove ID 2 does not exist
    with pytest.raises(StarkException, match=f"Abbot: address {AURA_USER} does not own trove ID {nope_trove}"):
        await abbot.deposit(steth_yang.contract_address, nope_trove, to_wad(1)).execute(caller_address=AURA_USER)


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_withdraw(abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig):
    steth_withdraw_amount = to_wad(2)
    doge_withdraw_amount = to_wad(50)

    tx1 = await abbot.withdraw(steth_yang.contract_address, TROVE_1, steth_withdraw_amount).execute(
        caller_address=AURA_USER
    )

    tx2 = await abbot.withdraw(doge_yang.contract_address, TROVE_1, doge_withdraw_amount).execute(
        caller_address=AURA_USER
    )

    assert_event_emitted(
        tx1,
        steth_yang.gate_address,
        "Withdraw",
        lambda d: d[:2] == [AURA_USER, TROVE_1] and d[-1] == steth_withdraw_amount,
    )

    assert_event_emitted(
        tx2,
        doge_yang.gate_address,
        "Withdraw",
        lambda d: d[:2] == [AURA_USER, TROVE_1] and d[-1] == doge_withdraw_amount,
    )

    assert (
        await shrine.get_deposit(steth_yang.contract_address, TROVE_1).execute()
    ).result.wad == INITIAL_STETH_DEPOSIT - steth_withdraw_amount
    assert (
        await shrine.get_deposit(doge_yang.contract_address, TROVE_1).execute()
    ).result.wad == INITIAL_DOGE_DEPOSIT - doge_withdraw_amount


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_withdraw_failures(abbot, steth_yang: YangConfig, shitcoin_yang: YangConfig):
    with pytest.raises(StarkException, match="Abbot: yang address cannot be zero"):
        await abbot.withdraw(0, TROVE_1, 0).execute(caller_address=AURA_USER)

    with pytest.raises(StarkException, match=rf"Abbot: yang {STARKNET_ADDR} is not approved"):
        await abbot.withdraw(shitcoin_yang.contract_address, TROVE_1, to_wad(100_000)).execute(caller_address=AURA_USER)

    with pytest.raises(StarkException, match=f"Abbot: address {OTHER_USER} does not own trove ID {TROVE_1}"):
        await abbot.withdraw(steth_yang.contract_address, TROVE_1, to_wad(10)).execute(caller_address=OTHER_USER)


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user")
@pytest.mark.asyncio
async def test_forge(abbot, steth_yang: YangConfig, yin, shrine):
    await abbot.open_trove(0, [steth_yang.contract_address], [INITIAL_STETH_DEPOSIT]).execute(caller_address=AURA_USER)

    forge_amount = to_wad(55)

    tx = await abbot.forge(TROVE_1, forge_amount).execute(caller_address=AURA_USER)

    # asserting only events particular to the user
    assert_event_emitted(tx, shrine.contract_address, "TroveUpdated", [TROVE_1, 0, forge_amount])
    assert_event_emitted(tx, shrine.contract_address, "YinUpdated", [AURA_USER, forge_amount])

    assert (await yin.balanceOf(AURA_USER).execute()).result.wad == forge_amount


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_forge_failures(abbot):
    with pytest.raises(StarkException, match=f"Abbot: address {OTHER_USER} does not own trove ID {TROVE_1}"):
        amount = to_wad(10)
        await abbot.forge(TROVE_1, amount).execute(caller_address=OTHER_USER)

    with pytest.raises(StarkException, match="Shrine: Trove LTV is too high"):
        amount = to_wad(1_000_000)
        await abbot.forge(TROVE_1, amount).execute(caller_address=AURA_USER)


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_melt(abbot, yin, shrine):
    melt_amount = to_wad(333)
    remaining_amount = INITIAL_FORGED_AMOUNT - melt_amount

    tx = await abbot.melt(TROVE_1, melt_amount).execute(caller_address=AURA_USER)

    # asserting only events particular to the user
    assert_event_emitted(tx, shrine.contract_address, "TroveUpdated", [TROVE_1, 0, remaining_amount])
    assert_event_emitted(tx, shrine.contract_address, "YinUpdated", [AURA_USER, remaining_amount])

    assert (await yin.balanceOf(AURA_USER).execute()).result.wad == remaining_amount


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_melt_failures(abbot):
    with pytest.raises(StarkException, match=f"Abbot: address {OTHER_USER} does not own trove ID {TROVE_1}"):
        amount = to_wad(10)
        await abbot.forge(TROVE_1, amount).execute(caller_address=OTHER_USER)

    with pytest.raises(StarkException, match="Shrine: System debt underflow"):
        amount = INITIAL_FORGED_AMOUNT * 2
        await abbot.melt(TROVE_1, amount).execute(caller_address=AURA_USER)


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_get_trove_owner(abbot):
    assert (await abbot.get_trove_owner(TROVE_1).execute()).result.address == AURA_USER
    assert (await abbot.get_trove_owner(789).execute()).result.address == 0


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_get_user_trove_ids(abbot, steth_yang: YangConfig):
    assert (await abbot.get_user_trove_ids(AURA_USER).execute()).result.trove_ids == [TROVE_1]
    assert (await abbot.get_user_trove_ids(OTHER_USER).execute()).result.trove_ids == []

    # opening another trove, checking if it gets added to the array
    await abbot.open_trove(0, [steth_yang.contract_address], [to_wad(2)]).execute(caller_address=AURA_USER)
    assert (await abbot.get_user_trove_ids(AURA_USER).execute()).result.trove_ids == [TROVE_1, 2]
    assert (await abbot.get_troves_count().execute()).result.ufelt == 2


@pytest.mark.usefixtures("abbot_with_yangs")
@pytest.mark.asyncio
async def test_get_yang_addresses(abbot, steth_yang: YangConfig, doge_yang: YangConfig):
    assert (await abbot.get_yang_addresses().execute()).result.addresses == [
        steth_yang.contract_address,
        doge_yang.contract_address,
    ]
