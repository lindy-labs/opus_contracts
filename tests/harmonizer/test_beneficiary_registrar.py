import pytest
from starkware.starkware_utils.error_handling import StarkException

from tests.harmonizer.constants import *  # noqa: F403
from tests.utils import RAY_SCALE, assert_event_emitted


@pytest.mark.asyncio
async def test_setup(beneficiary_registrar):

    res = (await beneficiary_registrar.get_beneficiaries().execute()).result

    assert res.beneficiaries == INITIAL_BENEFICIARIES
    assert res.percentages == INITIAL_PERCENTAGES_RAY
    assert len(res.beneficiaries) == len(res.percentages)
    assert sum(res.percentages) == RAY_SCALE

    beneficiary_count = (await beneficiary_registrar.get_beneficiaries_count().execute()).result.count
    expected_beneficiary_count = len(INITIAL_BENEFICIARIES)
    assert beneficiary_count == expected_beneficiary_count


@pytest.mark.asyncio
async def test_set_beneficiaries_pass(beneficiary_registrar):
    expected_beneficiary_count = len(SUBSEQUENT_BENEFICIARIES)

    tx = await beneficiary_registrar.set_beneficiaries(
        SUBSEQUENT_BENEFICIARIES,
        SUBSEQUENT_PERCENTAGES_RAY,
    ).execute(caller_address=BENEFICIARY_REGISTRAR_OWNER)

    assert_event_emitted(
        tx,
        beneficiary_registrar.contract_address,
        "BeneficiariesUpdated",
        [
            expected_beneficiary_count,
            *SUBSEQUENT_BENEFICIARIES,
            expected_beneficiary_count,
            *SUBSEQUENT_PERCENTAGES_RAY,
        ],
    )

    res = (await beneficiary_registrar.get_beneficiaries().execute()).result

    assert res.beneficiaries == SUBSEQUENT_BENEFICIARIES
    assert res.percentages == SUBSEQUENT_PERCENTAGES_RAY
    assert len(res.beneficiaries) == len(res.percentages)
    assert sum(res.percentages) == RAY_SCALE

    beneficiary_count = (await beneficiary_registrar.get_beneficiaries_count().execute()).result.count
    assert beneficiary_count == expected_beneficiary_count


@pytest.mark.asyncio
async def test_set_beneficiaries_fail(beneficiary_registrar):
    # no beneficiaries provided
    with pytest.raises(StarkException, match="Beneficiary Registrar: No beneficiaries provided"):
        await beneficiary_registrar.set_beneficiaries([], []).execute(caller_address=BENEFICIARY_REGISTRAR_OWNER)

    # mismatch in length of input arrays
    with pytest.raises(StarkException, match=r"Beneficiary Registrar: Input arguments mismatch: \d != \d"):
        await beneficiary_registrar.set_beneficiaries(INITIAL_BENEFICIARIES, SUBSEQUENT_PERCENTAGES_RAY).execute(
            caller_address=BENEFICIARY_REGISTRAR_OWNER
        )

    # percentages do not add up to a ray
    for i in (1, -1):
        invalid_percentages = INITIAL_PERCENTAGES_RAY.copy()
        invalid_percentages[-1] += i
        with pytest.raises(StarkException, match="Beneficiary Registrar: Percentages do not sum up to a ray"):
            await beneficiary_registrar.set_beneficiaries(INITIAL_BENEFICIARIES, invalid_percentages).execute(
                caller_address=BENEFICIARY_REGISTRAR_OWNER
            )
