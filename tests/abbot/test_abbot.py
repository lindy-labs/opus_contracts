from collections import namedtuple

import pytest
from starkware.starknet.testing.starknet import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.utils import assert_event_emitted, compile_contract, to_wad

TAX_RAY = 3 * 10**25  # TODO: use RAY_PERCENT const from utils, also elsewhere in this file
UINT256_MAX = (2**128 - 1, 2**128 - 1)
STARKNET_ADDR = r"-?\d+"  # addresses are sometimes printed as negative numbers, hence the -?

YangConfig = namedtuple("YangConfig", "contract_address ceiling threshold price_wad gate_address")

#
# users
#

abbot_owner = abs(hash("abbot owner"))
shrine_owner = abs(hash("shrine owner"))
steth_owner = abs(hash("steth owner"))
doge_owner = abs(hash("doge owner"))
shitcoin_owner = abs(hash("shitcoin owner"))
aura_user = abs(hash("aura user"))
other_user = abs(hash("other user"))

#
# fixtures
#


@pytest.fixture
async def steth_token(tokens) -> StarknetContract:
    return await tokens("Lido Staked ETH", "stETH", 18, (to_wad(100_000), 0), steth_owner)


@pytest.fixture
async def doge_token(tokens) -> StarknetContract:
    return await tokens("Dogecoin", "DOGE", 18, (to_wad(10_000_000), 0), doge_owner)


@pytest.fixture
async def shitcoin(tokens) -> StarknetContract:
    return await tokens("To the moon", "SHIT", 18, (2**128 - 1, 0), shitcoin_owner)


@pytest.fixture
async def shrine(starknet) -> StarknetContract:
    shrine_contract = compile_contract("contracts/shrine/shrine.cairo")
    shrine = await starknet.deploy(contract_class=shrine_contract, constructor_calldata=[shrine_owner])
    await shrine.set_ceiling(to_wad(50_000_000)).invoke(caller_address=shrine_owner)
    return shrine


@pytest.fixture
async def steth_gate(starknet, users, abbot, shrine, steth_token) -> StarknetContract:
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
    await shrine.authorize(gate.contract_address).invoke(caller_address=shrine_owner)

    return gate


@pytest.fixture
async def doge_gate(starknet, users, abbot, shrine, doge_token) -> StarknetContract:
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
    await shrine.authorize(gate.contract_address).invoke(caller_address=shrine_owner)

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
async def abbot(starknet, shrine) -> StarknetContract:
    abbot_contract = compile_contract("contracts/abbot/abbot.cairo")
    abbot = await starknet.deploy(
        contract_class=abbot_contract, constructor_calldata=[shrine.contract_address, abbot_owner]
    )
    # auth Abbot in Shrine
    await shrine.authorize(abbot.contract_address).invoke(caller_address=shrine_owner)

    return abbot


@pytest.fixture
async def abbot_with_yangs(abbot, steth_yang: YangConfig, doge_yang: YangConfig):
    for yang in (steth_yang, doge_yang):
        await abbot.add_yang(
            yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address
        ).invoke(caller_address=abbot_owner)


@pytest.fixture
async def funded_aura_user(steth_token, steth_yang: YangConfig, doge_token, doge_yang: YangConfig):
    # fund the user with bags
    await steth_token.transfer(aura_user, (to_wad(1_000), 0)).invoke(caller_address=steth_owner)
    await doge_token.transfer(aura_user, (to_wad(1_000_000), 0)).invoke(caller_address=doge_owner)

    # user approves Aura gates to spend bags
    await max_approve(steth_token, aura_user, steth_yang.gate_address)
    await max_approve(doge_token, aura_user, doge_yang.gate_address)


@pytest.fixture
async def aura_user_with_first_trove(abbot, steth_yang: YangConfig, doge_yang: YangConfig):
    steth_deposit = to_wad(20)
    doge_deposit = to_wad(1000)
    forge_amount = to_wad(4000)

    await abbot.open_trove(
        forge_amount, [steth_yang.contract_address, doge_yang.contract_address], [steth_deposit, doge_deposit]
    ).invoke(caller_address=aura_user)


#
# helpers
#


async def max_approve(token: StarknetContract, owner_addr: int, spender_addr: int):
    await token.approve(spender_addr, UINT256_MAX).invoke(caller_address=owner_addr)


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
async def test_add_yang(abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig):
    yangs = (steth_yang, doge_yang)
    for idx, yang in enumerate(yangs):
        tx = await abbot.add_yang(
            yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address
        ).invoke(caller_address=abbot_owner)

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
    with pytest.raises(StarkException):
        await abbot.add_yang(0xC0FFEE, 10**30, 10**27, to_wad(1), 0xDEADBEEF).invoke(caller_address=other_user)


@pytest.mark.asyncio
async def test_add_yang_failures(abbot, steth_yang: YangConfig, doge_yang: YangConfig):

    yang = steth_yang

    # test reverting on yang address equal 0
    with pytest.raises(StarkException, match="Abbot: address cannot be zero"):
        await abbot.add_yang(0, yang.ceiling, yang.threshold, yang.price_wad, 0xDEADBEEF).invoke(
            caller_address=abbot_owner
        )

    # test reverting on gate address equal 0
    with pytest.raises(StarkException, match="Abbot: address cannot be zero"):
        await abbot.add_yang(0xDEADBEEF, yang.ceiling, yang.threshold, yang.price_wad, 0).invoke(
            caller_address=abbot_owner
        )

    # test reverting on trying to add the same yang / gate combo
    await abbot.add_yang(yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address).invoke(
        caller_address=abbot_owner
    )
    with pytest.raises(StarkException, match="Abbot: yang already added"):
        await abbot.add_yang(
            yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address
        ).invoke(caller_address=abbot_owner)

    # test reverting when the Gate is for a different yang
    yang = doge_yang
    with pytest.raises(StarkException, match="Abbot: yang address does not match Gate's asset"):
        await abbot.add_yang(
            yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, steth_yang.gate_address
        ).invoke(caller_address=abbot_owner)


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user")
@pytest.mark.parametrize("forge_amount", [0, to_wad(3000)])
@pytest.mark.asyncio
async def test_open_trove(abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig, forge_amount):
    steth_deposit = to_wad(20)
    doge_deposit = to_wad(1000)

    tx = await abbot.open_trove(
        forge_amount, [steth_yang.contract_address, doge_yang.contract_address], [steth_deposit, doge_deposit]
    ).invoke(caller_address=aura_user)

    trove_id = 1  # first trove, hence trove_id=1

    # asserts on the Abbot
    assert_event_emitted(tx, abbot.contract_address, "TroveOpened", [aura_user, trove_id])
    assert (await abbot.get_user_trove_ids(aura_user).invoke()).result.trove_ids == [trove_id]
    assert (await abbot.get_troves_count().invoke()).result.ufelt == trove_id

    # asserts on the gates
    assert_event_emitted(
        tx,
        steth_yang.gate_address,
        "Deposit",
        lambda d: d[:2] == [aura_user, trove_id] and d[-1] == steth_deposit,
    )
    assert_event_emitted(
        tx,
        doge_yang.gate_address,
        "Deposit",
        lambda d: d[:2] == [aura_user, trove_id] and d[-1] == doge_deposit,
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
        tx, steth_yang.contract_address, "Transfer", [aura_user, steth_yang.gate_address, steth_deposit, 0]
    )
    assert_event_emitted(
        tx, doge_yang.contract_address, "Transfer", [aura_user, doge_yang.gate_address, doge_deposit, 0]
    )


@pytest.mark.asyncio
async def test_open_trove_failures(abbot, steth_yang: YangConfig, shitcoin_yang: YangConfig):
    with pytest.raises(StarkException, match=r"Abbot: input arguments mismatch: \d != \d"):
        await abbot.open_trove(0, [steth_yang.contract_address], [10, 200]).invoke(caller_address=aura_user)

    with pytest.raises(StarkException, match="Abbot: no yangs selected"):
        await abbot.open_trove(0, [], []).invoke(caller_address=aura_user)

    with pytest.raises(StarkException, match=rf"Abbot: yang {STARKNET_ADDR} is not approved"):
        await abbot.open_trove(0, [shitcoin_yang.contract_address], [10**10]).invoke(caller_address=aura_user)


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_close_trove(abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig):
    steth_amount = to_wad(20)
    doge_amount = to_wad(1_000)
    trove_id = 1

    assert (await abbot.get_user_trove_ids(aura_user).invoke()).result.trove_ids == [trove_id]

    tx = await abbot.close_trove(trove_id).invoke(caller_address=aura_user)

    # assert the trove still belongs to the user, but has no debt
    assert (await abbot.get_user_trove_ids(aura_user).invoke()).result.trove_ids == [trove_id]
    assert (await shrine.get_trove(trove_id).invoke()).result.trove.debt == 0

    # asserts on the gates
    assert_event_emitted(
        tx,
        steth_yang.gate_address,
        "Withdraw",
        lambda d: d[:2] == [aura_user, trove_id] and d[-1] == steth_amount,
    )
    assert_event_emitted(
        tx,
        doge_yang.gate_address,
        "Withdraw",
        lambda d: d[:2] == [aura_user, trove_id] and d[-1] == doge_amount,
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
        tx, steth_yang.contract_address, "Transfer", [steth_yang.gate_address, aura_user, steth_amount, 0]
    )
    assert_event_emitted(
        tx, doge_yang.contract_address, "Transfer", [doge_yang.gate_address, aura_user, doge_amount, 0]
    )


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_close_trove_failures(abbot):
    with pytest.raises(StarkException, match="Abbot: caller does not own trove ID 2"):
        await abbot.close_trove(2).invoke(caller_address=aura_user)

    with pytest.raises(StarkException, match="Abbot: caller does not own trove ID 1"):
        await abbot.close_trove(1).invoke(caller_address=other_user)


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_deposit(abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig):
    initial_steth_deposit = to_wad(20)
    initial_doge_deposit = to_wad(1000)
    fresh_steth_deposit = to_wad(1)
    fresh_doge_deposit = to_wad(200)
    trove_id = 1

    tx1 = await abbot.deposit(steth_yang.contract_address, trove_id, fresh_steth_deposit).invoke(
        caller_address=aura_user
    )
    tx2 = await abbot.deposit(doge_yang.contract_address, trove_id, fresh_doge_deposit).invoke(caller_address=aura_user)

    # check if gates emitted Deposit from aura_user to trove with the right amount
    assert_event_emitted(
        tx1, steth_yang.gate_address, "Deposit", lambda d: d[:3] == [aura_user, trove_id, fresh_steth_deposit]
    )
    assert_event_emitted(
        tx2, doge_yang.gate_address, "Deposit", lambda d: d[:3] == [aura_user, trove_id, fresh_doge_deposit]
    )

    assert (
        await shrine.get_deposit(trove_id, steth_yang.contract_address).invoke()
    ).result.wad == initial_steth_deposit + fresh_steth_deposit
    assert (
        await shrine.get_deposit(trove_id, doge_yang.contract_address).invoke()
    ).result.wad == initial_doge_deposit + fresh_doge_deposit


@pytest.mark.usefixtures("abbot_with_yangs")
@pytest.mark.asyncio
async def test_deposit_failures(abbot, steth_yang: YangConfig, shitcoin_yang: YangConfig):
    trove_id = 1

    with pytest.raises(StarkException, match="Abbot: yang address cannot be zero"):
        await abbot.deposit(0, trove_id, 0).invoke(caller_address=aura_user)

    with pytest.raises(StarkException, match=rf"Abbot: yang {STARKNET_ADDR} is not approved"):
        await abbot.deposit(shitcoin_yang.contract_address, trove_id, to_wad(100_000)).invoke(caller_address=aura_user)

    with pytest.raises(StarkException, match="Abbot: caller does not own trove ID 1"):
        await abbot.deposit(steth_yang.contract_address, trove_id, to_wad(1)).invoke(caller_address=other_user)


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_withdraw(abbot, shrine, steth_yang: YangConfig, doge_yang: YangConfig):
    initial_steth_deposit = to_wad(20)
    initial_doge_deposit = to_wad(1000)
    steth_withdraw_amount = to_wad(2)
    doge_withdraw_amount = to_wad(50)
    trove_id = 1

    tx1 = await abbot.withdraw(steth_yang.contract_address, trove_id, steth_withdraw_amount).invoke(
        caller_address=aura_user
    )

    tx2 = await abbot.withdraw(doge_yang.contract_address, trove_id, doge_withdraw_amount).invoke(
        caller_address=aura_user
    )

    assert_event_emitted(
        tx1,
        steth_yang.gate_address,
        "Withdraw",
        lambda d: d[:2] == [aura_user, trove_id] and d[-1] == steth_withdraw_amount,
    )

    assert_event_emitted(
        tx2,
        doge_yang.gate_address,
        "Withdraw",
        lambda d: d[:2] == [aura_user, trove_id] and d[-1] == doge_withdraw_amount,
    )

    assert (
        await shrine.get_deposit(trove_id, steth_yang.contract_address).invoke()
    ).result.wad == initial_steth_deposit - steth_withdraw_amount
    assert (
        await shrine.get_deposit(trove_id, doge_yang.contract_address).invoke()
    ).result.wad == initial_doge_deposit - doge_withdraw_amount


@pytest.mark.usefixtures("abbot_with_yangs", "funded_aura_user", "aura_user_with_first_trove")
@pytest.mark.asyncio
async def test_withdraw_failures(abbot, steth_yang: YangConfig, shitcoin_yang: YangConfig):
    trove_id = 1

    with pytest.raises(StarkException, match="Abbot: yang address cannot be zero"):
        await abbot.withdraw(0, trove_id, 0).invoke(caller_address=aura_user)

    with pytest.raises(StarkException, match=rf"Abbot: yang {STARKNET_ADDR} is not approved"):
        await abbot.withdraw(shitcoin_yang.contract_address, trove_id, to_wad(100_000)).invoke(caller_address=aura_user)

    with pytest.raises(StarkException, match="Abbot: caller does not own trove ID 1"):
        await abbot.withdraw(steth_yang.contract_address, trove_id, to_wad(10)).invoke(caller_address=other_user)


@pytest.mark.asyncio
async def test_forge():
    pass


@pytest.mark.asyncio
async def test_forge_failures():
    pass


@pytest.mark.asyncio
async def test_melt():
    pass


@pytest.mark.asyncio
async def test_melt_failures():
    pass
