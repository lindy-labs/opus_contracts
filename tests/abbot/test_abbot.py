import pytest
from starkware.starknet.testing.starknet import Starknet, StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.shrine.constants import YANGS
from tests.utils import assert_event_emitted, compile_contract, to_wad

# TODO:
# deposit - happy path, depositing into foreign trove, depositing 0 amount,
#           depositing twice the same token in 1 call, depositing a yang that hasn't been added,
#           yangs & amounts that don't match in length as args

#
# fixtures
#


@pytest.fixture(scope="session")  # TODO: descope when PR#54 is merged and rebased
async def starknet() -> Starknet:
    starknet = await Starknet.empty()
    return starknet


@pytest.fixture
async def shrine(starknet, users) -> StarknetContract:
    shrine_owner = await users("shrine owner")
    shrine_contract = compile_contract("contracts/shrine/shrine.cairo")
    shrine = await starknet.deploy(contract_class=shrine_contract, constructor_calldata=[shrine_owner.address])
    return shrine


@pytest.fixture
async def abbot(starknet, shrine, users) -> StarknetContract:
    shrine_owner = await users("shrine owner")
    abbot_owner = await users("abbot owner")
    abbot_contract = compile_contract("contracts/abbot/abbot.cairo")
    abbot = await starknet.deploy(
        contract_class=abbot_contract, constructor_calldata=[shrine.contract_address, abbot_owner.address]
    )
    # authorize abbot in shrine
    await shrine_owner.send_tx(shrine.contract_address, "authorize", [abbot.contract_address])
    return abbot


#
# tests
#


@pytest.mark.asyncio
async def test_add_yang(abbot, shrine, users):
    abbot_owner = await users("abbot owner")

    for idx, yang in enumerate(YANGS):
        gate_addr = (idx + 1) * 10**10
        tx = await abbot_owner.send_tx(
            abbot.contract_address,
            "add_yang",
            [yang["address"], yang["ceiling"], yang["threshold"], to_wad(yang["start_price"]), gate_addr],
        )

        assert_event_emitted(tx, abbot.contract_address, "YangAdded", [yang["address"], gate_addr])
        # this assert on an event emitted from the shrine contract serves as a proxy
        # to see if the Shrine was actually called (IShrine.add_yang)
        assert_event_emitted(
            tx,
            shrine.contract_address,
            "YangAdded",
            [yang["address"], idx + 1, yang["ceiling"], to_wad(yang["start_price"])],
        )

    addrs = (await abbot.get_yang_addresses().invoke()).result.addresses
    assert len(addrs) == len(YANGS)
    for i in range(len(YANGS)):
        assert addrs[i] == YANGS[i]["address"]

    # test TX reverts on unathorized actor calling add_yang
    bad_guy = await users("bad guy")
    with pytest.raises(StarkException):
        await bad_guy.send_tx(
            abbot.contract_address,
            "add_yang",
            [yang["address"], yang["ceiling"], yang["threshold"], to_wad(yang["start_price"]), gate_addr],
        )

    yang = YANGS[0]
    gate_addr = 87654

    # test reverting on yang address equal 0
    with pytest.raises(StarkException):
        await abbot_owner.send_tx(
            abbot.contract_address,
            "add_yang",
            [0, yang["ceiling"], yang["threshold"], to_wad(yang["start_price"]), gate_addr],
        )

    # test reverting on gate address equal 0
    with pytest.raises(StarkException):
        await abbot_owner.send_tx(
            abbot.contract_address,
            "add_yang",
            [yang["address"], yang["ceiling"], yang["threshold"], to_wad(yang["start_price"]), 0],
        )

    gate_addr = 10**10
    # test reverting on trying to add the same yang / gate combo
    with pytest.raises(StarkException):
        await abbot_owner.send_tx(
            abbot.contract_address,
            "add_yang",
            [yang["address"], yang["ceiling"], yang["threshold"], to_wad(yang["start_price"]), gate_addr],
        )
