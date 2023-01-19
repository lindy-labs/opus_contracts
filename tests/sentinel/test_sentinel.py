import pytest
from starkware.starkware_utils.error_handling import StarkException

from tests.roles import SentinelRoles
from tests.utils import (
    BAD_GUY,
    SENTINEL_OWNER,
    SENTINEL_ROLE_FOR_ABBOT,
    SHRINE_OWNER,
    TROVE1_OWNER,
    TROVE_1,
    WAD_RAY_OOB_VALUES,
    WAD_SCALE,
    YangConfig,
    assert_event_emitted,
    signed_int_to_felt,
    to_fixed_point,
    to_wad,
)


@pytest.fixture
@pytest.mark.asyncio
async def mock_owner_as_abbot(sentinel):
    await (sentinel.grant_role(SENTINEL_ROLE_FOR_ABBOT, SENTINEL_OWNER).execute(caller_address=SENTINEL_OWNER))


@pytest.mark.usefixtures("sentinel_with_yangs")
@pytest.mark.asyncio
async def test_sentinel_setup(sentinel, yangs):
    assert (await sentinel.get_admin().execute()).result.admin == SENTINEL_OWNER
    assert (await sentinel.has_role(SentinelRoles.ADD_YANG, SENTINEL_OWNER).execute()).result.has_role == 1
    yang_addrs = (await sentinel.get_yang_addresses().execute()).result.addresses
    assert len(yang_addrs) == len(yangs)
    for yang in yangs:
        assert yang.contract_address in yang_addrs


@pytest.mark.asyncio
async def test_add_yang(sentinel, shrine_deploy, yangs):
    shrine = shrine_deploy

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
            [yang.contract_address, idx + 1, yang.price_wad],
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


@pytest.mark.usefixtures("sentinel_with_yangs")
@pytest.mark.asyncio
async def test_set_yang_asset_max(shrine, sentinel, steth_yang: YangConfig):
    yang = steth_yang

    async def set_and_assert(new_yang_max):
        orig_max = (await sentinel.get_yang_asset_max(yang.contract_address).execute()).result.max
        tx = await sentinel.set_yang_asset_max(yang.contract_address, new_yang_max).execute(
            caller_address=SENTINEL_OWNER
        )
        assert_event_emitted(
            tx,
            sentinel.contract_address,
            "YangAssetMaxUpdated",
            [yang.contract_address, orig_max, new_yang_max],
        )

        updated_yang_max = (await sentinel.get_yang_asset_max(yang.contract_address).execute()).result.max
        assert updated_yang_max == new_yang_max

    # test increasing the max
    new_yang_max = yang.ceiling * 2
    await set_and_assert(new_yang_max)

    # test decreasing the max
    new_yang_max = yang.ceiling - 1
    await set_and_assert(new_yang_max)

    # test decreasing the max below yang.total
    deposit_amt = to_wad(100)
    # Deposit 100 yang tokens
    await shrine.deposit(yang.contract_address, TROVE_1, deposit_amt).execute(caller_address=SHRINE_OWNER)

    new_yang_max = deposit_amt - to_wad(1)
    await set_and_assert(new_yang_max)  # update yang_max to a value smaller than the total amount currently deposited


@pytest.mark.usefixtures("sentinel_with_yangs")
@pytest.mark.asyncio
async def test_set_yang_asset_max_failures(shrine, sentinel, steth_yang: YangConfig):
    # test reverting on non-existent yang
    faux_yang_address = 999
    faux_yang_max = to_wad(1_000)
    with pytest.raises(
        StarkException,
        match=f"Sentinel: Yang {faux_yang_address} is not approved",
    ):
        await sentinel.set_yang_asset_max(faux_yang_address, faux_yang_max).execute(caller_address=SENTINEL_OWNER)

    # test reverting on out of bound values
    for val in WAD_RAY_OOB_VALUES:
        input_val = signed_int_to_felt(val)
        with pytest.raises(
            StarkException,
            match=r"Sentinel: Value of `new_asset_max` \(-?\d+\) is out of bounds",
        ):
            await sentinel.set_yang_asset_max(steth_yang.contract_address, input_val).execute(
                caller_address=SENTINEL_OWNER
            )

    # test reverting on unauthorized caller
    with pytest.raises(
        StarkException, match=f"AccessControl: Caller is missing role {SentinelRoles.SET_YANG_ASSET_MAX}"
    ):
        await sentinel.set_yang_asset_max(steth_yang.contract_address, steth_yang.ceiling).execute(
            caller_address=BAD_GUY
        )


# Tests for view functions grouped together for efficiency since none of them change the state
@pytest.mark.usefixtures("sentinel_with_yangs")
@pytest.mark.asyncio
async def test_view_funcs(sentinel, yangs, yang_gates):

    # Testing `get_yang_addresses`
    assert (await sentinel.get_yang_addresses().execute()).result.addresses == [yang.contract_address for yang in yangs]

    for idx, (yang, gate) in enumerate(zip(yangs, yang_gates)):
        # Testing `get_gate_addresses`
        assert (await sentinel.get_gate_address(yang.contract_address).execute()).result.gate == gate.contract_address

        # Testing `get_yang`
        assert (await sentinel.get_yang(idx).execute()).result.yang == yang.contract_address

        # Testing `get_yang_asset_max`
        assert (await sentinel.get_yang_asset_max(yang.contract_address).execute()).result.max == yang.ceiling

    # Testing `get_yang_addresses_count`
    assert (await sentinel.get_yang_addresses_count().execute()).result.count == 3


@pytest.mark.usefixtures("mock_owner_as_abbot", "sentinel_with_yangs", "funded_trove_owners")
@pytest.mark.asyncio
async def test_gate_fns_pass(sentinel, yangs, yang_gates):
    deposit_asset_amt = 5
    for yang, gate in zip(yangs, yang_gates):
        scaled_asset_deposit_amt = to_fixed_point(deposit_asset_amt, yang.decimals)
        scaled_yang_withdraw_amt = to_wad(deposit_asset_amt)

        expected_yang_amt = (
            await sentinel.preview_enter(yang.contract_address, scaled_asset_deposit_amt).execute()
        ).result.yang_amt
        assert expected_yang_amt == scaled_yang_withdraw_amt

        enter = await sentinel.enter(yang.contract_address, TROVE1_OWNER, TROVE_1, scaled_asset_deposit_amt).execute(
            caller_address=SENTINEL_OWNER
        )

        expected_asset_amt_per_yang = (
            await sentinel.get_asset_amt_per_yang(yang.contract_address).execute()
        ).result.amt

        # Check if `Gate.enter` is called
        assert_event_emitted(
            enter, gate.contract_address, "Enter", [TROVE1_OWNER, TROVE_1, scaled_asset_deposit_amt, expected_yang_amt]
        )
        assert expected_asset_amt_per_yang == WAD_SCALE

        expected_asset_amt = (
            await sentinel.preview_exit(yang.contract_address, scaled_yang_withdraw_amt).execute()
        ).result.asset_amt
        assert expected_asset_amt == scaled_asset_deposit_amt

        exit_ = await sentinel.exit(yang.contract_address, TROVE1_OWNER, TROVE_1, scaled_yang_withdraw_amt).execute(
            caller_address=SENTINEL_OWNER
        )

        # Check if `Gate.exit` is called
        assert_event_emitted(
            exit_, gate.contract_address, "Exit", [TROVE1_OWNER, TROVE_1, expected_asset_amt, scaled_yang_withdraw_amt]
        )


@pytest.mark.usefixtures("sentinel_with_yangs", "mock_owner_as_abbot")
@pytest.mark.asyncio
async def test_gate_fns_fail_invalid_yang(sentinel):
    faux_yang_address = 999
    faux_yang_amt = faux_deposit_amt = to_wad(10)
    with pytest.raises(StarkException, match=f"Sentinel: Yang {faux_yang_address} is not approved"):
        await sentinel.enter(faux_yang_address, TROVE1_OWNER, TROVE_1, faux_deposit_amt).execute(
            caller_address=SENTINEL_OWNER
        )

    with pytest.raises(StarkException, match=f"Sentinel: Yang {faux_yang_address} is not approved"):
        await sentinel.exit(faux_yang_address, TROVE1_OWNER, TROVE_1, faux_yang_amt).execute(
            caller_address=SENTINEL_OWNER
        )

    with pytest.raises(StarkException, match=f"Sentinel: Yang {faux_yang_address} is not approved"):
        await sentinel.preview_enter(faux_yang_address, faux_deposit_amt).execute()

    with pytest.raises(StarkException, match=f"Sentinel: Yang {faux_yang_address} is not approved"):
        await sentinel.preview_exit(faux_yang_address, faux_yang_amt).execute()

    expected_asset_amt = (await sentinel.get_asset_amt_per_yang(faux_yang_address).execute()).result.amt
    assert expected_asset_amt == 0


@pytest.mark.usefixtures("sentinel_with_yangs", "funded_trove_owners")
@pytest.mark.asyncio
async def test_gate_fns_fail_unauthorized(sentinel, steth_yang: YangConfig):
    deposit_asset_amt = deposit_yang_amt = to_wad(5)
    with pytest.raises(StarkException, match=f"AccessControl: Caller is missing role {SentinelRoles.ENTER}"):
        await sentinel.enter(steth_yang.contract_address, TROVE1_OWNER, TROVE_1, deposit_asset_amt).execute(
            caller_address=TROVE1_OWNER
        )

    with pytest.raises(StarkException, match=f"AccessControl: Caller is missing role {SentinelRoles.EXIT}"):
        await sentinel.exit(steth_yang.contract_address, TROVE1_OWNER, TROVE_1, deposit_yang_amt).execute(
            caller_address=TROVE1_OWNER
        )


@pytest.mark.usefixtures("mock_owner_as_abbot", "sentinel_with_yangs", "funded_trove_owners")
@pytest.mark.asyncio
async def test_enter_fail_exceed_max(sentinel, yangs, yang_gates):
    deposit_asset_amt = 5
    for yang, gate in zip(yangs, yang_gates):
        scaled_asset_deposit_amt = to_fixed_point(deposit_asset_amt, yang.decimals)

        await sentinel.enter(yang.contract_address, TROVE1_OWNER, TROVE_1, scaled_asset_deposit_amt).execute(
            caller_address=SENTINEL_OWNER
        )

        new_asset_max = scaled_asset_deposit_amt - 1
        await sentinel.set_yang_asset_max(yang.contract_address, new_asset_max).execute(caller_address=SENTINEL_OWNER)

        # This should fail, since total deposited assets will exceed max
        with pytest.raises(StarkException, match="Sentinel: Exceeds maximum amount of asset allowed"):
            await sentinel.enter(yang.contract_address, TROVE1_OWNER, TROVE_1, scaled_asset_deposit_amt).execute(
                caller_address=SENTINEL_OWNER
            )
