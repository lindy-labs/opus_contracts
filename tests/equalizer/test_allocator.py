import pytest
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

from tests.equalizer.constants import *  # noqa: F403
from tests.roles import AllocatorRoles
from tests.utils import BAD_GUY, RAY_SCALE, assert_event_emitted


@pytest.mark.asyncio
async def test_setup(allocator):
    res = (await allocator.get_allocation().execute()).result

    assert res.recipients == INITIAL_RECIPIENTS
    assert res.percentages == INITIAL_PERCENTAGES_RAY
    assert len(res.recipients) == len(res.percentages)
    assert sum(res.percentages) == RAY_SCALE


@pytest.mark.asyncio
async def test_deploy_fail(starknet: Starknet, allocator_contract):
    # no recipients provided
    with pytest.raises(StarkException, match="Allocator: No recipients provided"):
        await starknet.deploy(
            contract_class=allocator_contract,
            constructor_calldata=[ALLOCATOR_OWNER, 0, *[], 0, *[]],
        )

    # mismatch in length of input arrays
    with pytest.raises(StarkException, match=r"Allocator: Input arguments mismatch: \d != \d"):
        await starknet.deploy(
            contract_class=allocator_contract,
            constructor_calldata=[
                ALLOCATOR_OWNER,
                len(INITIAL_RECIPIENTS),
                *INITIAL_RECIPIENTS,
                len(SUBSEQUENT_PERCENTAGES_RAY),
                *SUBSEQUENT_PERCENTAGES_RAY,
            ],
        )

    # percentages do not add up to a ray
    for i in (1, -1):
        invalid_percentages = INITIAL_PERCENTAGES_RAY.copy()
        invalid_percentages[-1] += i
        with pytest.raises(StarkException, match="Allocator: Percentages do not sum up to a ray"):
            await starknet.deploy(
                contract_class=allocator_contract,
                constructor_calldata=[
                    ALLOCATOR_OWNER,
                    len(INITIAL_RECIPIENTS),
                    *INITIAL_RECIPIENTS,
                    len(invalid_percentages),
                    *invalid_percentages,
                ],
            )


@pytest.mark.asyncio
async def test_set_allocation_pass(allocator):
    expected_recipient_count = len(SUBSEQUENT_RECIPIENTS)

    tx = await allocator.set_allocation(
        SUBSEQUENT_RECIPIENTS,
        SUBSEQUENT_PERCENTAGES_RAY,
    ).execute(caller_address=ALLOCATOR_OWNER)

    assert_event_emitted(
        tx,
        allocator.contract_address,
        "AllocationUpdated",
        [
            expected_recipient_count,
            *SUBSEQUENT_RECIPIENTS,
            expected_recipient_count,
            *SUBSEQUENT_PERCENTAGES_RAY,
        ],
    )

    res = (await allocator.get_allocation().execute()).result

    assert res.recipients == SUBSEQUENT_RECIPIENTS
    assert res.percentages == SUBSEQUENT_PERCENTAGES_RAY
    assert len(res.recipients) == len(res.percentages)
    assert sum(res.percentages) == RAY_SCALE


@pytest.mark.asyncio
async def test_set_allocation_fail(allocator):
    # no recipients provided
    with pytest.raises(StarkException, match="Allocator: No recipients provided"):
        await allocator.set_allocation([], []).execute(caller_address=ALLOCATOR_OWNER)

    # mismatch in length of input arrays
    with pytest.raises(StarkException, match=r"Allocator: Input arguments mismatch: \d != \d"):
        await allocator.set_allocation(INITIAL_RECIPIENTS, SUBSEQUENT_PERCENTAGES_RAY).execute(
            caller_address=ALLOCATOR_OWNER
        )

    # percentages do not add up to a ray
    for i in (1, -1):
        invalid_percentages = INITIAL_PERCENTAGES_RAY.copy()
        invalid_percentages[-1] += i
        with pytest.raises(StarkException, match="Allocator: Percentages do not sum up to a ray"):
            await allocator.set_allocation(INITIAL_RECIPIENTS, invalid_percentages).execute(
                caller_address=ALLOCATOR_OWNER
            )

    # unauthorized
    with pytest.raises(StarkException, match=f"AccessControl: Caller is missing role {AllocatorRoles.SET_ALLOCATION}"):
        await allocator.set_allocation(
            SUBSEQUENT_RECIPIENTS,
            SUBSEQUENT_PERCENTAGES_RAY,
        ).execute(caller_address=BAD_GUY)
