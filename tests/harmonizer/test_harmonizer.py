import pytest
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

from tests.harmonizer.constants import *  # noqa: F403
from tests.roles import HarmonizerRoles, ShrineRoles
from tests.utils import (
    BAD_GUY,
    SHRINE_OWNER,
    ZERO_ADDRESS,
    assert_equalish,
    assert_event_emitted,
    compile_contract,
    from_uint,
    from_wad,
    get_token_balances,
)

#
# fixtures
#


@pytest.fixture
async def harmonizer(starknet: Starknet, shrine, beneficiary_registrar) -> StarknetContract:
    harmonizer_contract = compile_contract("contracts/harmonizer/harmonizer.cairo")
    harmonizer = await starknet.deploy(
        contract_class=harmonizer_contract,
        constructor_calldata=[
            HARMONIZER_OWNER,
            shrine.contract_address,
            beneficiary_registrar.contract_address,
        ],
    )

    await shrine.grant_role(ShrineRoles.FORGE_WITHOUT_TROVE, harmonizer.contract_address).execute(
        caller_address=SHRINE_OWNER
    )

    return harmonizer


@pytest.fixture
async def alt_beneficiary_registrar(starknet: Starknet) -> StarknetContract:
    registrar_contract = compile_contract("contracts/harmonizer/beneficiary_registrar.cairo")
    registrar = await starknet.deploy(
        contract_class=registrar_contract,
        constructor_calldata=[
            BENEFICIARY_REGISTRAR_OWNER,
            len(SUBSEQUENT_BENEFICIARIES),
            *SUBSEQUENT_BENEFICIARIES,
            len(SUBSEQUENT_PERCENTAGES_RAY),
            *SUBSEQUENT_PERCENTAGES_RAY,
        ],
    )

    return registrar


#
# tests
#


@pytest.mark.asyncio
async def test_setup(harmonizer, beneficiary_registrar):
    registrar = (await harmonizer.get_beneficiary_registrar().execute()).result.registrar
    assert registrar == beneficiary_registrar.contract_address


@pytest.mark.parametrize("surplus_wad", [0, DEBT_INCREMENT_WAD])
@pytest.mark.asyncio
async def test_restore_pass(shrine, harmonizer, surplus_wad):
    await shrine.increase_total_debt(surplus_wad).execute(caller_address=SHRINE_OWNER)

    expected_beneficiary_count = len(INITIAL_BENEFICIARIES)
    expected_beneficiaries = INITIAL_BENEFICIARIES
    expected_percentages_ray = INITIAL_PERCENTAGES_RAY

    before_yin_supply = from_uint((await shrine.totalSupply().execute()).result.total_supply)
    before_beneficiary_bals = (await get_token_balances([shrine], expected_beneficiaries))[0]

    tx = await harmonizer.restore().execute()

    after_beneficiary_bals = (await get_token_balances([shrine], expected_beneficiaries))[0]
    expected_percentages = INITIAL_PERCENTAGES
    surplus = from_wad(surplus_wad)

    for beneficiary, percentage, before_bal, after_bal in zip(
        expected_beneficiaries, expected_percentages, before_beneficiary_bals, after_beneficiary_bals
    ):
        expected_increment = percentage * surplus
        assert_equalish(after_bal, before_bal + expected_increment)

        if surplus > 0:
            assert_event_emitted(
                tx,
                shrine.contract_address,
                "Transfer",
                lambda d: d[:2] == [ZERO_ADDRESS, beneficiary],
            )

    after_yin_supply = from_uint((await shrine.totalSupply().execute()).result.total_supply)
    assert after_yin_supply == before_yin_supply + surplus_wad

    if surplus > 0:
        assert_event_emitted(
            tx,
            harmonizer.contract_address,
            "Restore",
            [
                expected_beneficiary_count,
                *expected_beneficiaries,
                expected_beneficiary_count,
                *expected_percentages_ray,
                surplus_wad,
            ],
        )


@pytest.mark.asyncio
async def test_set_beneficiary_registrar_pass(shrine, harmonizer, beneficiary_registrar, alt_beneficiary_registrar):
    tx = await harmonizer.set_beneficiary_registrar(alt_beneficiary_registrar.contract_address).execute(
        caller_address=HARMONIZER_OWNER
    )

    assert_event_emitted(
        tx,
        harmonizer.contract_address,
        "BeneficiaryRegistrarUpdated",
        [beneficiary_registrar.contract_address, alt_beneficiary_registrar.contract_address],
    )

    # Check `restore`
    surplus_wad = DEBT_INCREMENT_WAD
    await shrine.increase_total_debt(surplus_wad).execute(caller_address=SHRINE_OWNER)

    expected_beneficiary_count = len(SUBSEQUENT_BENEFICIARIES)
    expected_beneficiaries = SUBSEQUENT_BENEFICIARIES
    expected_percentages_ray = SUBSEQUENT_PERCENTAGES_RAY

    before_yin_supply = from_uint((await shrine.totalSupply().execute()).result.total_supply)
    before_beneficiary_bals = (await get_token_balances([shrine], expected_beneficiaries))[0]

    tx = await harmonizer.restore().execute()

    after_beneficiary_bals = (await get_token_balances([shrine], expected_beneficiaries))[0]
    expected_percentages = SUBSEQUENT_PERCENTAGES
    surplus = from_wad(surplus_wad)

    for beneficiary, percentage, before_bal, after_bal in zip(
        expected_beneficiaries, expected_percentages, before_beneficiary_bals, after_beneficiary_bals
    ):
        expected_increment = percentage * surplus
        assert_equalish(after_bal, before_bal + expected_increment)

        assert_event_emitted(
            tx,
            shrine.contract_address,
            "Transfer",
            lambda d: d[:2] == [ZERO_ADDRESS, beneficiary],
        )

    after_yin_supply = from_uint((await shrine.totalSupply().execute()).result.total_supply)
    assert after_yin_supply == before_yin_supply + surplus_wad

    assert_event_emitted(
        tx,
        harmonizer.contract_address,
        "Restore",
        [
            expected_beneficiary_count,
            *expected_beneficiaries,
            expected_beneficiary_count,
            *expected_percentages_ray,
            surplus_wad,
        ],
    )


@pytest.mark.asyncio
async def test_set_beneficiary_registrar_fail(harmonizer, alt_beneficiary_registrar):
    # unauthorized
    with pytest.raises(
        StarkException, match=f"AccessControl: Caller is missing role {HarmonizerRoles.SET_BENEFICIARY_REGISTRAR}"
    ):
        await harmonizer.set_beneficiary_registrar(alt_beneficiary_registrar.contract_address).execute(
            caller_address=BAD_GUY
        )
