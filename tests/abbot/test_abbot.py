from collections import namedtuple

import pytest
from starkware.starknet.testing.starknet import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.account import Account
from tests.utils import assert_event_emitted, compile_contract, to_wad

TAX_RAY = 3 * 10**25  # TODO: use RAY_PERCENT const from utils, also elsewhere in this file
UINT256_MAX = (2**128 - 1, 2**128 - 1)
STARKNET_ADDR = r"-?\d+"  # addresses are sometimes printed as negative numbers, hence the -?

YangConfig = namedtuple("YangConfig", "contract_address ceiling threshold price_wad gate_address")

#
# fixtures
#


@pytest.fixture
async def abbot_owner(users) -> Account:
    return await users("abbot owner")


@pytest.fixture
async def shrine_owner(users) -> Account:
    return await users("shrine owner")


@pytest.fixture
async def aura_user(users) -> Account:
    return await users("aura user")


@pytest.fixture
async def steth_token(users, tokens) -> StarknetContract:
    owner = await users("steth owner")
    return await tokens("Lido Staked ETH", "stETH", 18, (to_wad(100_000), 0), owner.address)


@pytest.fixture
async def doge_token(users, tokens) -> StarknetContract:
    owner = await users("doge owner")
    return await tokens("Dogecoin", "DOGE", 18, (to_wad(10_000_000), 0), owner.address)


@pytest.fixture
async def shitcoin(users, tokens) -> StarknetContract:
    owner = await users("shitcoin owner")
    return await tokens("To the moon", "SHIT", 18, (2**128 - 1, 0), owner.address)


@pytest.fixture
async def shrine(starknet, shrine_owner) -> StarknetContract:
    shrine_contract = compile_contract("contracts/shrine/shrine.cairo")
    shrine = await starknet.deploy(contract_class=shrine_contract, constructor_calldata=[shrine_owner.address])
    await shrine_owner.send_tx(shrine.contract_address, "set_ceiling", [to_wad(50_000_000)])
    return shrine


@pytest.fixture
async def steth_gate(starknet, users, abbot, shrine, shrine_owner, steth_token) -> StarknetContract:
    """
    Deploys an instance of the Gate module with autocompounding and tax.
    """
    contract = compile_contract("contracts/gate/rebasing_yang/gate_taxable.cairo")
    admin = await users("admin")
    tax_collector = await users("tax collector")

    gate = await starknet.deploy(
        contract_class=contract,
        constructor_calldata=[
            admin.address,
            shrine.contract_address,
            steth_token.contract_address,
            TAX_RAY,
            tax_collector.address,
        ],
    )

    # auth Abbot in Gate
    await admin.send_tx(gate.contract_address, "authorize", [abbot.contract_address])
    # auth Gate in Shrine
    await shrine_owner.send_tx(shrine.contract_address, "authorize", [gate.contract_address])

    return gate


@pytest.fixture
async def doge_gate(starknet, users, abbot, shrine, shrine_owner, doge_token) -> StarknetContract:
    """
    Deploys an instance of the Gate module, without any autocompounding or tax.
    """
    contract = compile_contract("contracts/gate/rebasing_yang/gate.cairo")
    admin = await users("admin")
    gate = await starknet.deploy(
        contract_class=contract,
        constructor_calldata=[
            admin.address,
            shrine.contract_address,
            doge_token.contract_address,
        ],
    )

    # auth Abbot in Gate
    await admin.send_tx(gate.contract_address, "authorize", [abbot.contract_address])
    # auth Gate in Shrine
    await shrine_owner.send_tx(shrine.contract_address, "authorize", [gate.contract_address])

    return gate


@pytest.fixture
def steth_yang(steth_token, steth_gate) -> YangConfig:
    ceiling = to_wad(1_000_000)
    threshold = 90 * 10**25  # 90%
    price_wad = to_wad(2000)
    return YangConfig(steth_token.contract_address, ceiling, threshold, price_wad, steth_gate.contract_address)


@pytest.fixture
def doge_yang(doge_token, doge_gate) -> YangConfig:
    ceiling = to_wad(100_000_000)
    threshold = 20 * 10**25  # 20%
    price_wad = to_wad(0.07)
    return YangConfig(doge_token.contract_address, ceiling, threshold, price_wad, doge_gate.contract_address)


@pytest.fixture
def shitcoin_yang(shitcoin) -> YangConfig:
    return YangConfig(shitcoin.contract_address, 0, 0, 0, 0)


@pytest.fixture
async def abbot(starknet, shrine, shrine_owner, abbot_owner) -> StarknetContract:
    abbot_contract = compile_contract("contracts/abbot/abbot.cairo")
    abbot = await starknet.deploy(
        contract_class=abbot_contract, constructor_calldata=[shrine.contract_address, abbot_owner.address]
    )
    # auth Abbot in Shrine
    await shrine_owner.send_tx(shrine.contract_address, "authorize", [abbot.contract_address])
    return abbot


@pytest.fixture
async def abbot_with_yangs(abbot, abbot_owner, steth_yang: YangConfig, doge_yang: YangConfig):
    for yang in (steth_yang, doge_yang):
        await abbot_owner.send_tx(
            abbot.contract_address,
            "add_yang",
            [yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address],
        )


@pytest.fixture
async def funded_aura_user(aura_user, users, steth_yang: YangConfig, doge_yang: YangConfig):
    steth_owner = await users("steth owner")
    doge_owner = await users("doge owner")

    # fund the user with bags
    await steth_owner.send_tx(steth_yang.contract_address, "transfer", [aura_user.address, *[to_wad(1_000), 0]])
    await doge_owner.send_tx(doge_yang.contract_address, "transfer", [aura_user.address, *[to_wad(1_000_000), 0]])

    # user approves Aura gates to spend bags
    await max_approve(aura_user, steth_yang.contract_address, steth_yang.gate_address)
    await max_approve(aura_user, doge_yang.contract_address, doge_yang.gate_address)


@pytest.fixture
async def aura_user_with_first_trove(aura_user, abbot, steth_yang: YangConfig, doge_yang: YangConfig):
    steth_deposit = to_wad(20)
    doge_deposit = to_wad(1000)
    forge_amount = to_wad(4000)

    await aura_user.send_tx(
        abbot.contract_address,
        "open_trove",
        [forge_amount, 2, steth_yang.contract_address, doge_yang.contract_address, 2, steth_deposit, doge_deposit],
    )


#
# helpers
#


async def max_approve(owner: Account, token_addr: int, spender_addr: int):
    await owner.send_tx(token_addr, "approve", [spender_addr, *UINT256_MAX])


#
# tests
#

# TODO:
# deposit - happy path, depositing into foreign trove, depositing 0 amount,
#           depositing twice the same token in 1 call, depositing a yang that hasn't been added,
#           yangs & amounts that don't match in length as args
# test_get_user_trove_ids
# test_get_yang_addresses


@pytest.mark.usefixtures("abbot_with_yangs")
@pytest.mark.asyncio
async def test_abbot_setup(abbot, steth_yang: YangConfig, doge_yang: YangConfig):
    yang_addrs = (await abbot.get_yang_addresses().invoke()).result.addresses
    assert len(yang_addrs) == 2
    assert steth_yang.contract_address in yang_addrs
    assert doge_yang.contract_address in yang_addrs


@pytest.mark.asyncio
async def test_add_yang(abbot, shrine, abbot_owner, users, steth_yang: YangConfig, doge_yang: YangConfig):
    yangs = (steth_yang, doge_yang)
    for idx, yang in enumerate(yangs):
        tx = await abbot_owner.send_tx(
            abbot.contract_address,
            "add_yang",
            [yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address],
        )

        assert_event_emitted(tx, abbot.contract_address, "YangAdded", [yang.contract_address, yang.gate_address])
        # this assert on an event emitted from the shrine contract serves as a proxy
        # to see if the Shrine was actually called (IShrine.add_yang)
        assert_event_emitted(
            tx,
            shrine.contract_address,
            "YangAdded",
            [yang.contract_address, idx + 1, yang.ceiling, yang.price_wad],
        )

    addrs = (await abbot.get_yang_addresses().invoke()).result.addresses
    assert len(addrs) == len(yangs)
    for i in range(len(yangs)):
        assert addrs[i] in (y.contract_address for y in yangs)

    # test TX reverts on unathorized actor calling add_yang
    bad_guy = await users("bad guy")
    with pytest.raises(StarkException):
        await bad_guy.send_tx(abbot.contract_address, "add_yang", [0xC0FFEE, 10**30, 10**27, to_wad(1), 0xDEADBEEF])

    yang = steth_yang

    # test reverting on yang address equal 0
    with pytest.raises(StarkException, match="Abbot: address cannot be zero"):
        await abbot_owner.send_tx(
            abbot.contract_address,
            "add_yang",
            [0, yang.ceiling, yang.threshold, yang.price_wad, 0xDEADBEEF],
        )

    # test reverting on gate address equal 0
    with pytest.raises(StarkException, match="Abbot: address cannot be zero"):
        await abbot_owner.send_tx(
            abbot.contract_address,
            "add_yang",
            [0xDEADBEEF, yang.ceiling, yang.threshold, yang.price_wad, 0],
        )

    # test reverting on trying to add the same yang / gate combo
    with pytest.raises(StarkException, match="Abbot: yang already added"):
        await abbot_owner.send_tx(
            abbot.contract_address,
            "add_yang",
            [yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address],
        )


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user")
@pytest.mark.parametrize("forge_amount", [0, to_wad(3000)])
@pytest.mark.asyncio
async def test_open_trove(aura_user, abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig, forge_amount):
    steth_deposit = to_wad(20)
    doge_deposit = to_wad(1000)

    tx = await aura_user.send_tx(
        abbot.contract_address,
        "open_trove",
        [forge_amount, 2, steth_yang.contract_address, doge_yang.contract_address, 2, steth_deposit, doge_deposit],
    )
    trove_id = 1  # first trove, hence trove_id=1

    # asserts on the Abbot
    assert_event_emitted(tx, abbot.contract_address, "TroveOpened", [aura_user.address, trove_id])
    assert (await abbot.get_user_trove_ids(aura_user.address).invoke()).result.trove_ids == [trove_id]
    assert (await abbot.get_troves_count().invoke()).result.ufelt == trove_id

    # asserts on the gates
    assert_event_emitted(
        tx,
        steth_yang.gate_address,
        "Deposit",
        lambda d: d[:2] == [aura_user.address, trove_id] and d[-1] == steth_deposit,
    )
    assert_event_emitted(
        tx,
        doge_yang.gate_address,
        "Deposit",
        lambda d: d[:2] == [aura_user.address, trove_id] and d[-1] == doge_deposit,
    )

    # asserts on the shrine
    assert_event_emitted(
        tx, shrine.contract_address, "YangUpdated", lambda d: d[:2] == [steth_yang.contract_address, steth_deposit]
    )
    assert_event_emitted(
        tx, shrine.contract_address, "YangUpdated", lambda d: d[:2] == [doge_yang.contract_address, doge_deposit]
    )
    assert_event_emitted(
        tx, shrine.contract_address, "DepositUpdated", [trove_id, steth_yang.contract_address, steth_deposit]
    )
    assert_event_emitted(
        tx, shrine.contract_address, "DepositUpdated", [trove_id, doge_yang.contract_address, doge_deposit]
    )
    assert (await shrine.get_trove(trove_id).invoke()).result.trove.debt == forge_amount

    # asserts on the tokens
    # the 0 is to conform to Uint256
    assert_event_emitted(
        tx, steth_yang.contract_address, "Transfer", [aura_user.address, steth_yang.gate_address, steth_deposit, 0]
    )
    assert_event_emitted(
        tx, doge_yang.contract_address, "Transfer", [aura_user.address, doge_yang.gate_address, doge_deposit, 0]
    )


@pytest.mark.asyncio
async def test_open_trove_failures(aura_user, abbot, steth_yang: YangConfig, shitcoin_yang: YangConfig):
    with pytest.raises(StarkException, match=r"Abbot: input arguments mismatch: \d != \d"):
        await aura_user.send_tx(abbot.contract_address, "open_trove", [0, 1, steth_yang.contract_address, 2, 10, 200])

    with pytest.raises(StarkException, match="Abbot: no yangs selected"):
        await aura_user.send_tx(abbot.contract_address, "open_trove", [0, 0, 0])

    with pytest.raises(StarkException, match=rf"Abbot: yang {STARKNET_ADDR} is not approved"):
        await aura_user.send_tx(
            abbot.contract_address, "open_trove", [0, 1, shitcoin_yang.contract_address, 1, 10**10]
        )


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_close_trove(aura_user, abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig):
    steth_amount = to_wad(20)
    doge_amount = to_wad(1_000)
    trove_id = 1
    assert (await abbot.get_user_trove_ids(aura_user.address).invoke()).result.trove_ids == [trove_id]

    tx = await aura_user.send_tx(abbot.contract_address, "close_trove", [trove_id])

    # assert the trove still belongs to the user, but has no debt
    assert (await abbot.get_user_trove_ids(aura_user.address).invoke()).result.trove_ids == [trove_id]
    assert (await shrine.get_trove(trove_id).invoke()).result.trove.debt == 0

    # asserts on the gates
    assert_event_emitted(
        tx,
        steth_yang.gate_address,
        "Withdraw",
        lambda d: d[:2] == [aura_user.address, trove_id] and d[-1] == steth_amount,
    )
    assert_event_emitted(
        tx,
        doge_yang.gate_address,
        "Withdraw",
        lambda d: d[:2] == [aura_user.address, trove_id] and d[-1] == doge_amount,
    )

    # asserts on the shrine
    assert_event_emitted(
        tx, shrine.contract_address, "YangUpdated", lambda d: d[:2] == [steth_yang.contract_address, 0]
    )
    assert_event_emitted(tx, shrine.contract_address, "YangUpdated", lambda d: d[:2] == [doge_yang.contract_address, 0])
    assert_event_emitted(tx, shrine.contract_address, "DepositUpdated", [trove_id, steth_yang.contract_address, 0])
    assert_event_emitted(tx, shrine.contract_address, "DepositUpdated", [trove_id, doge_yang.contract_address, 0])
    assert_event_emitted(tx, shrine.contract_address, "DebtTotalUpdated", [0])  # from melt
    assert_event_emitted(tx, shrine.contract_address, "TroveUpdated", [trove_id, 0, 0])

    # asserts on the tokens
    # the 0 is to conform to Uint256
    assert_event_emitted(
        tx, steth_yang.contract_address, "Transfer", [steth_yang.gate_address, aura_user.address, steth_amount, 0]
    )
    assert_event_emitted(
        tx, doge_yang.contract_address, "Transfer", [doge_yang.gate_address, aura_user.address, doge_amount, 0]
    )


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_close_trove_failures(aura_user, abbot, users):
    with pytest.raises(StarkException, match="Abbot: caller does not own trove ID 2"):
        await aura_user.send_tx(abbot.contract_address, "close_trove", [2])

    with pytest.raises(StarkException, match="Abbot: caller does not own trove ID 1"):
        other_one = await users("other")
        await other_one.send_tx(abbot.contract_address, "close_trove", [1])


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_deposit(aura_user, abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig):
    initial_steth_deposit = to_wad(20)
    initial_doge_deposit = to_wad(1000)
    fresh_steth_deposit = to_wad(1)
    fresh_doge_deposit = to_wad(200)
    trove_id = 1

    tx1 = await aura_user.send_tx(
        abbot.contract_address,
        "deposit",
        [trove_id, steth_yang.contract_address, fresh_steth_deposit],
    )

    tx2 = await aura_user.send_tx(
        abbot.contract_address, "deposit", [trove_id, doge_yang.contract_address, fresh_doge_deposit]
    )

    # check if gates emitted Deposit from aura_user to trove with the right amount
    assert_event_emitted(
        tx1, steth_yang.gate_address, "Deposit", lambda d: d[:3] == [aura_user.address, trove_id, fresh_steth_deposit]
    )
    assert_event_emitted(
        tx2, doge_yang.gate_address, "Deposit", lambda d: d[:3] == [aura_user.address, trove_id, fresh_doge_deposit]
    )

    assert (
        await shrine.get_deposit(trove_id, steth_yang.contract_address).invoke()
    ).result.wad == initial_steth_deposit + fresh_steth_deposit
    assert (
        await shrine.get_deposit(trove_id, doge_yang.contract_address).invoke()
    ).result.wad == initial_doge_deposit + fresh_doge_deposit


@pytest.mark.usefixtures("abbot_with_yangs")
@pytest.mark.asyncio
async def test_deposit_failures(aura_user, abbot, users, steth_yang: YangConfig, shitcoin_yang: YangConfig):
    trove_id = 1

    with pytest.raises(StarkException, match="Abbot: yang address cannot be zero"):
        await aura_user.send_tx(abbot.contract_address, "deposit", [trove_id, 0, 0])

    with pytest.raises(StarkException, match=rf"Abbot: yang {STARKNET_ADDR} is not approved"):
        await aura_user.send_tx(
            abbot.contract_address, "deposit", [trove_id, shitcoin_yang.contract_address, to_wad(100_000)]
        )

    with pytest.raises(StarkException, match="Abbot: caller does not own trove ID 1"):
        other_one = await users("other")
        await other_one.send_tx(abbot.contract_address, "deposit", [trove_id, steth_yang.contract_address, to_wad(1)])


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_withdraw(aura_user, abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig):
    initial_steth_deposit = to_wad(20)
    initial_doge_deposit = to_wad(1000)
    steth_withdraw_amount = to_wad(2)
    doge_withdraw_amount = to_wad(50)
    trove_id = 1

    tx1 = await aura_user.send_tx(
        abbot.contract_address,
        "withdraw",
        [
            trove_id,
            steth_yang.contract_address,
            steth_withdraw_amount,
        ],
    )

    tx2 = await aura_user.send_tx(
        abbot.contract_address, "withdraw", [trove_id, doge_yang.contract_address, doge_withdraw_amount]
    )

    assert_event_emitted(
        tx1,
        steth_yang.gate_address,
        "Withdraw",
        lambda d: d[:2] == [aura_user.address, trove_id] and d[-1] == steth_withdraw_amount,
    )

    assert_event_emitted(
        tx2,
        doge_yang.gate_address,
        "Withdraw",
        lambda d: d[:2] == [aura_user.address, trove_id] and d[-1] == doge_withdraw_amount,
    )

    assert (
        await shrine.get_deposit(trove_id, steth_yang.contract_address).invoke()
    ).result.wad == initial_steth_deposit - steth_withdraw_amount
    assert (
        await shrine.get_deposit(trove_id, doge_yang.contract_address).invoke()
    ).result.wad == initial_doge_deposit - doge_withdraw_amount


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_withdraw_failures(aura_user, abbot, users, steth_yang: YangConfig, shitcoin_yang: YangConfig):
    trove_id = 1

    with pytest.raises(StarkException, match="Abbot: yang address cannot be zero"):
        await aura_user.send_tx(abbot.contract_address, "withdraw", [trove_id, 0, 0])

    with pytest.raises(StarkException, match=rf"Abbot: yang {STARKNET_ADDR} is not approved"):
        await aura_user.send_tx(
            abbot.contract_address, "withdraw", [trove_id, shitcoin_yang.contract_address, to_wad(100_000)]
        )

    with pytest.raises(StarkException, match="Abbot: caller does not own trove ID 1"):
        other_one = await users("other")
        await other_one.send_tx(abbot.contract_address, "withdraw", [trove_id, steth_yang.contract_address, to_wad(10)])
