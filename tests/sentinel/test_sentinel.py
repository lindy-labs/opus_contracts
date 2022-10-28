import pytest
from starkware.starkware_utils.error_handling import StarkException

from tests.roles import SentinelRoles
from tests.utils import BAD_GUY, SENTINEL_OWNER, YangConfig, assert_event_emitted


@pytest.mark.usefixtures("sentinel_with_yangs")
@pytest.mark.asyncio
async def test_sentinel_setup(sentinel, steth_yang: YangConfig, doge_yang: YangConfig):
    assert (await sentinel.get_admin().execute()).result.admin == SENTINEL_OWNER
    assert (await sentinel.has_role(SentinelRoles.ADD_YANG, SENTINEL_OWNER).execute()).result.has_role == 1
    yang_addrs = (await sentinel.get_yang_addresses().execute()).result.addresses
    assert len(yang_addrs) == 2
    assert steth_yang.contract_address in yang_addrs
    assert doge_yang.contract_address in yang_addrs


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


@pytest.mark.asyncio
async def test_add_yang_failures(sentinel, steth_yang: YangConfig, doge_yang: YangConfig):

    yang = steth_yang

    # test reverting on unathorized actor calling add_yang
    with pytest.raises(StarkException, match=r"AccessControl: Caller is missing role \d+"):
        await sentinel.add_yang(
            yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address
        ).execute(caller_address=BAD_GUY)

    # test reverting on yang address equal 0
    with pytest.raises(StarkException, match="Sentinel: Address cannot be zero"):
        await sentinel.add_yang(0, yang.ceiling, yang.threshold, yang.price_wad, 0xDEADBEEF).execute(
            caller_address=SENTINEL_OWNER
        )

    # test reverting on gate address equal 0
    with pytest.raises(StarkException, match="Sentinel: Address cannot be zero"):
        await sentinel.add_yang(0xDEADBEEF, yang.ceiling, yang.threshold, yang.price_wad, 0).execute(
            caller_address=SENTINEL_OWNER
        )

    # test reverting on trying to add the same yang / gate combo
    await sentinel.add_yang(
        yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address
    ).execute(caller_address=SENTINEL_OWNER)
    with pytest.raises(StarkException, match="Sentinel: Yang already added"):
        await sentinel.add_yang(
            yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, yang.gate_address
        ).execute(caller_address=SENTINEL_OWNER)

    # test reverting when the Gate is for a different yang
    yang = doge_yang
    with pytest.raises(StarkException, match="Sentinel: Yang address does not match Gate's asset"):
        await sentinel.add_yang(
            yang.contract_address, yang.ceiling, yang.threshold, yang.price_wad, steth_yang.gate_address
        ).execute(caller_address=SENTINEL_OWNER)


# Tests for view functions grouped together for efficiency since none of them change the state
@pytest.mark.usefixtures("sentinel_with_yangs")
@pytest.mark.asyncio
async def test_view_funcs(sentinel, steth_yang: YangConfig, doge_yang: YangConfig, steth_gate, doge_gate):

    # Testing `get_yang_addresses`
    assert (await sentinel.get_yang_addresses().execute()).result.addresses == [
        steth_yang.contract_address,
        doge_yang.contract_address,
    ]

    # Testing `get_gate_addresses`
    assert (
        await sentinel.get_gate_address(steth_yang.contract_address).execute()
    ).result.gate == steth_gate.contract_address
    assert (
        await sentinel.get_gate_address(doge_yang.contract_address).execute()
    ).result.gate == doge_gate.contract_address

    # Testing `get_yang`
    assert (await sentinel.get_yang(0).execute()).result.yang == steth_yang.contract_address
    assert (await sentinel.get_yang(1).execute()).result.yang == doge_yang.contract_address

    # Testing `get_yang_addresses_count`
    assert (await sentinel.get_yang_addresses_count().execute()).result.count == 2
