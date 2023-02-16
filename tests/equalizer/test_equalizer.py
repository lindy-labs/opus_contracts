import pytest
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

from tests.equalizer.constants import *  # noqa: F403
from tests.roles import EqualizerRoles, ShrineRoles
from tests.utils import (
    BAD_GUY,
    SHRINE_OWNER,
    ZERO_ADDRESS,
    assert_equalish,
    assert_event_emitted,
    compile_contract,
    from_ray,
    from_uint,
    from_wad,
    get_token_balances,
)

#
# fixtures
#


@pytest.fixture
async def equalizer(starknet: Starknet, shrine, allocator) -> StarknetContract:
    equalizer_contract = compile_contract("contracts/equalizer/equalizer.cairo")
    equalizer = await starknet.deploy(
        contract_class=equalizer_contract,
        constructor_calldata=[
            EQUALIZER_OWNER,
            shrine.contract_address,
            allocator.contract_address,
        ],
    )

    await shrine.grant_role(ShrineRoles.INJECT, equalizer.contract_address).execute(caller_address=SHRINE_OWNER)

    return equalizer


@pytest.fixture
async def alt_allocator(starknet: Starknet, allocator_contract) -> StarknetContract:
    allocator = await starknet.deploy(
        contract_class=allocator_contract,
        constructor_calldata=[
            len(SUBSEQUENT_RECIPIENTS),
            *SUBSEQUENT_RECIPIENTS,
            len(SUBSEQUENT_PERCENTAGES_RAY),
            *SUBSEQUENT_PERCENTAGES_RAY,
        ],
    )

    return allocator


#
# tests
#


@pytest.mark.asyncio
async def test_setup(equalizer, allocator):
    allocator_address = (await equalizer.get_allocator().execute()).result.allocator
    assert allocator_address == allocator.contract_address


@pytest.mark.parametrize(
    "initial_surplus_wad",
    [
        0,
        DEBT_INCREMENT_WAD - 1,  # Test loss of precision from fixed point division
        DEBT_INCREMENT_WAD,
    ],
)
@pytest.mark.asyncio
async def test_equalize_pass(shrine, equalizer, initial_surplus_wad):
    initial_surplus = (await equalizer.get_surplus().execute()).result.amount

    await shrine.increase_total_debt(initial_surplus_wad).execute(caller_address=SHRINE_OWNER)

    before_surplus = (await equalizer.get_surplus().execute()).result.amount
    assert before_surplus == initial_surplus + initial_surplus_wad

    expected_recipients_count = len(INITIAL_RECIPIENTS)
    expected_recipients = INITIAL_RECIPIENTS
    expected_percentages_ray = INITIAL_PERCENTAGES_RAY

    before_yin_supply = from_uint((await shrine.totalSupply().execute()).result.total_supply)
    before_recipients_bal = (await get_token_balances([shrine], expected_recipients))[0]

    tx = await equalizer.equalize().execute()
    minted_surplus_wad = tx.result.minted_surplus

    after_recipients_bal = (await get_token_balances([shrine], expected_recipients))[0]
    initial_surplus = from_wad(initial_surplus_wad)
    minted_surplus = from_wad(minted_surplus_wad)

    for recipient, percentage_ray, before_bal, after_bal in zip(
        expected_recipients, expected_percentages_ray, before_recipients_bal, after_recipients_bal
    ):
        percentage = from_ray(percentage_ray)
        expected_increment = percentage * initial_surplus
        assert_equalish(after_bal, before_bal + expected_increment)

        if minted_surplus > 0:
            assert_event_emitted(
                tx,
                shrine.contract_address,
                "Transfer",
                lambda d: d[:2] == [ZERO_ADDRESS, recipient],
            )

    after_yin_supply = from_uint((await shrine.totalSupply().execute()).result.total_supply)
    assert after_yin_supply == before_yin_supply + minted_surplus_wad

    if minted_surplus > 0:
        assert_event_emitted(
            tx,
            equalizer.contract_address,
            "Equalize",
            [
                expected_recipients_count,
                *expected_recipients,
                expected_recipients_count,
                *expected_percentages_ray,
                minted_surplus_wad,
            ],
        )

    after_surplus_wad = (await equalizer.get_surplus().execute()).result.amount
    assert_equalish(from_wad(after_surplus_wad), Decimal("0"))

    if initial_surplus_wad % 10 == 0:
        assert after_surplus_wad == 0
    else:
        assert after_surplus_wad > 0


@pytest.mark.asyncio
async def test_set_allocator_pass(shrine, equalizer, allocator, alt_allocator):
    tx = await equalizer.set_allocator(alt_allocator.contract_address).execute(caller_address=EQUALIZER_OWNER)

    assert_event_emitted(
        tx,
        equalizer.contract_address,
        "AllocatorUpdated",
        [allocator.contract_address, alt_allocator.contract_address],
    )

    # Check `equalize`
    surplus_wad = DEBT_INCREMENT_WAD
    await shrine.increase_total_debt(surplus_wad).execute(caller_address=SHRINE_OWNER)

    expected_recipients_count = len(SUBSEQUENT_RECIPIENTS)
    expected_recipients = SUBSEQUENT_RECIPIENTS
    expected_percentages_ray = SUBSEQUENT_PERCENTAGES_RAY

    before_yin_supply = from_uint((await shrine.totalSupply().execute()).result.total_supply)
    before_recipients_bal = (await get_token_balances([shrine], expected_recipients))[0]

    tx = await equalizer.equalize().execute()

    after_recipients_bal = (await get_token_balances([shrine], expected_recipients))[0]
    surplus = from_wad(surplus_wad)

    for recipient, percentage_ray, before_bal, after_bal in zip(
        expected_recipients, expected_percentages_ray, before_recipients_bal, after_recipients_bal
    ):
        percentage = from_ray(percentage_ray)
        expected_increment = percentage * surplus
        assert_equalish(after_bal, before_bal + expected_increment)

        assert_event_emitted(
            tx,
            shrine.contract_address,
            "Transfer",
            lambda d: d[:2] == [ZERO_ADDRESS, recipient],
        )

    after_yin_supply = from_uint((await shrine.totalSupply().execute()).result.total_supply)
    assert after_yin_supply == before_yin_supply + surplus_wad

    assert_event_emitted(
        tx,
        equalizer.contract_address,
        "Equalize",
        [
            expected_recipients_count,
            *expected_recipients,
            expected_recipients_count,
            *expected_percentages_ray,
            surplus_wad,
        ],
    )

    after_surplus_wad = (await equalizer.get_surplus().execute()).result.amount
    assert_equalish(from_wad(after_surplus_wad), Decimal("0"))


@pytest.mark.asyncio
async def test_set_allocator_fail(equalizer, alt_allocator):
    # unauthorized
    with pytest.raises(StarkException, match=f"AccessControl: Caller is missing role {EqualizerRoles.SET_ALLOCATOR}"):
        await equalizer.set_allocator(alt_allocator.contract_address).execute(caller_address=BAD_GUY)
