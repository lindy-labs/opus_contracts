import pytest

from tests.utils import SENTINEL_OWNER, YangConfig, assert_event_emitted


@pytest.mark.asyncio
async def test_add_yang(sentinel, shrine_deploy, steth_yang: YangConfig, doge_yang: YangConfig):
    shrine = shrine_deploy
    yangs = (steth_yang, doge_yang)

    for idx, yang in enumerate(yangs):
        tx = await sentinel.add_yang(
            yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address
        ).execute(caller_address=SENTINEL_OWNER)

        assert_event_emitted(tx, sentinel.contract_address, "YangAdded", [yang.contract_address, yang.gate_address])
        # this assert on an event emitted from the shrine contract serves as a proxy
        # to see if the Shrine was actually called (IShrine.add_yang)
        assert_event_emitted(
            tx,
            shrine.contract_address,
            "YangAdded",
            [yang.contract_address, idx + 1, yang.ceiling, yang.price_wad],
        )

    addrs = (await sentinel.get_yang_addresses().execute()).result.addresses
    assert len(addrs) == len(yangs)
    for i in range(len(yangs)):
        assert addrs[i] in (y.contract_address for y in yangs)
