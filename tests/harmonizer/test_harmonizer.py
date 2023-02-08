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
async def harmonizer(starknet: Starknet, shrine, allocator) -> StarknetContract:
    harmonizer_contract = compile_contract("contracts/harmonizer/harmonizer.cairo")
    harmonizer = await starknet.deploy(
        contract_class=harmonizer_contract,
        constructor_calldata=[
            HARMONIZER_OWNER,
            shrine.contract_address,
            allocator.contract_address,
        ],
    )

    await shrine.grant_role(ShrineRoles.FORGE_WITHOUT_TROVE, harmonizer.contract_address).execute(
        caller_address=SHRINE_OWNER
    )

    return harmonizer


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
async def test_setup(harmonizer, allocator):
    allocator_address = (await harmonizer.get_allocator().execute()).result.allocator
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
async def test_restore_pass(shrine, harmonizer, initial_surplus_wad):
    initial_surplus = (await harmonizer.get_surplus().execute()).result.amount

    await shrine.increase_total_debt(initial_surplus_wad).execute(caller_address=SHRINE_OWNER)

    before_surplus = (await harmonizer.get_surplus().execute()).result.amount
    assert before_surplus == initial_surplus + initial_surplus_wad

    expected_recipients_count = len(INITIAL_RECIPIENTS)
    expected_recipients = INITIAL_RECIPIENTS
    expected_percentages_ray = INITIAL_PERCENTAGES_RAY

    before_yin_supply = from_uint((await shrine.totalSupply().execute()).result.total_supply)
    before_recipients_bal = (await get_token_balances([shrine], expected_recipients))[0]

    tx = await harmonizer.restore().execute()
    minted_surplus_wad = tx.result.minted_surplus

    after_recipients_bal = (await get_token_balances([shrine], expected_recipients))[0]
    expected_percentages = INITIAL_PERCENTAGES
    initial_surplus = from_wad(initial_surplus_wad)
    minted_surplus = from_wad(minted_surplus_wad)

    for recipient, percentage, before_bal, after_bal in zip(
        expected_recipients, expected_percentages, before_recipients_bal, after_recipients_bal
    ):
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
            harmonizer.contract_address,
            "Restore",
            [
                expected_recipients_count,
                *expected_recipients,
                expected_recipients_count,
                *expected_percentages_ray,
                minted_surplus_wad,
            ],
        )

    after_surplus_wad = (await harmonizer.get_surplus().execute()).result.amount
    assert_equalish(from_wad(after_surplus_wad), Decimal("0"))

    if initial_surplus_wad % 10 == 0:
        assert after_surplus_wad == 0
    else:
        assert after_surplus_wad > 0


@pytest.mark.asyncio
async def test_set_allocator_pass(shrine, harmonizer, allocator, alt_allocator):
    tx = await harmonizer.set_allocator(alt_allocator.contract_address).execute(caller_address=HARMONIZER_OWNER)

    assert_event_emitted(
        tx,
        harmonizer.contract_address,
        "AllocatorUpdated",
        [allocator.contract_address, alt_allocator.contract_address],
    )

    # Check `restore`
    surplus_wad = DEBT_INCREMENT_WAD
    await shrine.increase_total_debt(surplus_wad).execute(caller_address=SHRINE_OWNER)

    expected_recipients_count = len(SUBSEQUENT_RECIPIENTS)
    expected_recipients = SUBSEQUENT_RECIPIENTS
    expected_percentages_ray = SUBSEQUENT_PERCENTAGES_RAY

    before_yin_supply = from_uint((await shrine.totalSupply().execute()).result.total_supply)
    before_recipients_bal = (await get_token_balances([shrine], expected_recipients))[0]

    tx = await harmonizer.restore().execute()

    after_recipients_bal = (await get_token_balances([shrine], expected_recipients))[0]
    expected_percentages = SUBSEQUENT_PERCENTAGES
    surplus = from_wad(surplus_wad)

    for recipient, percentage, before_bal, after_bal in zip(
        expected_recipients, expected_percentages, before_recipients_bal, after_recipients_bal
    ):
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
        harmonizer.contract_address,
        "Restore",
        [
            expected_recipients_count,
            *expected_recipients,
            expected_recipients_count,
            *expected_percentages_ray,
            surplus_wad,
        ],
    )

    after_surplus_wad = (await harmonizer.get_surplus().execute()).result.amount
    assert_equalish(from_wad(after_surplus_wad), Decimal("0"))


@pytest.mark.asyncio
async def test_set_allocator_fail(harmonizer, alt_allocator):
    # unauthorized
    with pytest.raises(StarkException, match=f"AccessControl: Caller is missing role {HarmonizerRoles.SET_ALLOCATOR}"):
        await harmonizer.set_allocator(alt_allocator.contract_address).execute(caller_address=BAD_GUY)
