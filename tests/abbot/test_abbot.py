from collections import namedtuple

import pytest
from starkware.starknet.testing.starknet import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.account import Account
from tests.utils import assert_event_emitted, compile_contract, to_wad

TAX_RAY = 3 * 10**25

YangConfig = namedtuple("YangConfig", "contract_address ceiling threshold price_wad gate_address")

# TODO:
# deposit - happy path, depositing into foreign trove, depositing 0 amount,
#           depositing twice the same token in 1 call, depositing a yang that hasn't been added,
#           yangs & amounts that don't match in length as args

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
async def steth_token(users, tokens) -> StarknetContract:
    owner = await users("steth owner")
    return await tokens("Lido Staked ETH", "stETH", 18, (10**9, 0), owner.address)


@pytest.fixture
async def doge_token(users, tokens) -> StarknetContract:
    owner = await users("doge owner")
    return await tokens("Dogecoin", "DOGE", 18, (10**32, 0), owner.address)


@pytest.fixture
async def shrine(starknet, shrine_owner) -> StarknetContract:
    shrine_contract = compile_contract("contracts/shrine/shrine.cairo")
    shrine = await starknet.deploy(contract_class=shrine_contract, constructor_calldata=[shrine_owner.address])
    return shrine


@pytest.fixture
async def steth_gate(starknet, users, abbot, shrine, steth_token) -> StarknetContract:
    """
    Deploys an instance of the Gate module with autocompounding and tax.
    """
    contract = compile_contract("tests/gate/rebasing_yang/test_gate_taxable.cairo")
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

    # Authorise Abbot
    await admin.send_tx(gate.contract_address, "authorize", [abbot.contract_address])

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

    # Authorise Abbot
    await admin.send_tx(gate.contract_address, "authorize", [abbot.contract_address])

    return gate


@pytest.fixture
def steth_yang(steth_token, steth_gate) -> YangConfig:
    ceiling = 10**22
    threshold = 90 * 10**25  # 90%
    price_wad = to_wad(2000)
    return YangConfig(steth_token.contract_address, ceiling, threshold, price_wad, steth_gate.contract_address)


@pytest.fixture
def doge_yang(doge_token, doge_gate) -> YangConfig:
    ceiling = 10**20
    threshold = 20 * 10**25  # 20%
    price_wad = to_wad(0.07)
    return YangConfig(doge_token.contract_address, ceiling, threshold, price_wad, doge_gate.contract_address)


@pytest.fixture
async def abbot(starknet, shrine, shrine_owner, abbot_owner) -> StarknetContract:
    abbot_contract = compile_contract("contracts/abbot/abbot.cairo")
    abbot = await starknet.deploy(
        contract_class=abbot_contract, constructor_calldata=[shrine.contract_address, abbot_owner.address]
    )
    # authorize abbot in shrine
    await shrine_owner.send_tx(shrine.contract_address, "authorize", [abbot.contract_address])
    return abbot


# TODO: use proper yangs, like real deployed ERC20 contracts
@pytest.fixture
async def abbot_with_yangs(abbot, abbot_owner, steth_yang: YangConfig, doge_yang: YangConfig):
    for yang in (steth_yang, doge_yang):
        await abbot_owner.send_tx(
            abbot.contract_address,
            "add_yang",
            [yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address],
        )


#
# tests
#

# TODO: test_get_user_trove_ids
#       test_get_yang_addresses


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


# @pytest.mark.skip
# @pytest.mark.usefixtures("abbot_yangs")
# @pytest.mark.asyncio
# async def test_open_trove(abbot, users):
#     aura_user = await users("aura user")

#     tx = await aura_user.send_tx(abbot.contract_address, "open_trove", [to_wad(10), [YANGS[0]], [to_wad(50)]])
#     print(tx)
#     assert_event_emitted(tx, abbot.contract_address, [aura_user.address, 1])

#     # TODO: check something on the gate
#     #       check something on the shrine
#     #       check something on the yang token
#     #       check something on the abbot
