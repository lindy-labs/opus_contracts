import pytest
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

from tests.harmonizer.constants import *  # noqa: F403
from tests.utils import RAY_SCALE


@pytest.mark.asyncio
async def test_setup(allocator):
    res = (await allocator.get_allocation().execute()).result

    assert res.recipients == INITIAL_RECIPIENTS
    assert res.percentages == INITIAL_PERCENTAGES_RAY
    assert len(res.recipients) == len(res.percentages)
    assert sum(res.percentages) == RAY_SCALE

    recipient_count = (await allocator.get_recipients_count().execute()).result.count
    expected_recipient_count = len(INITIAL_RECIPIENTS)
    assert recipient_count == expected_recipient_count


@pytest.mark.asyncio
async def test_deploy_fail(starknet: Starknet, allocator_contract):
    # no recipients provided
    with pytest.raises(StarkException, match="Allocator: No recipients provided"):
        await starknet.deploy(
            contract_class=allocator_contract,
            constructor_calldata=[0, *[], 0, *[]],
        )

    # mismatch in length of input arrays
    with pytest.raises(StarkException, match=r"Allocator: Input arguments mismatch: \d != \d"):
        await starknet.deploy(
            contract_class=allocator_contract,
            constructor_calldata=[
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
                    len(INITIAL_RECIPIENTS),
                    *INITIAL_RECIPIENTS,
                    len(invalid_percentages),
                    *invalid_percentages,
                ],
            )
