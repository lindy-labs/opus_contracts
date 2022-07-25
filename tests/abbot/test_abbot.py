import pytest
from starkware.starkware_utils.error_handling import StarkException

from tests.shrine.constants import YANGS
from tests.utils import assert_event_emitted, to_wad


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
