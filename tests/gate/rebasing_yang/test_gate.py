from decimal import Decimal

import pytest
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.objects import StarknetCallInfo
from starkware.starkware_utils.error_handling import StarkException

from tests.gate.rebasing_yang.constants import *  # noqa: F403
from tests.shrine.constants import TROVE_1, TROVE_2, ShrineRoles
from tests.utils import (
    ABBOT,
    ADMIN,
    BAD_GUY,
    FALSE,
    MAX_UINT256,
    SHRINE_OWNER,
    TROVE1_OWNER,
    TROVE2_OWNER,
    TRUE,
    ZERO_ADDRESS,
    assert_equalish,
    assert_event_emitted,
    compile_contract,
    from_uint,
    from_wad,
    to_ray,
    to_wad,
)

#
# Constants
#

CUSTOM_ERROR_MARGIN = Decimal("10e-18")

#
# Helper functions
#


def get_yang_from_assets(total_yang: int, total_assets: int, assets_amt: int) -> Decimal:
    """
    Helper function to calculate the number of yang given a deposit of assets.

    Arguments
    ---------
    total_yang : int
        Total supply of yang before deposit in wad.
    total_assets : int
        Total assets held by vault in wad.
    assets_amt : int
        Amount of assets to be deposited in wad.

    Returns
    -------
    Amount of yang to be issued in Decimal.
    """
    return from_wad(total_yang) * from_wad(assets_amt) / from_wad(total_assets)


def get_assets_from_yang(total_yang: int, total_assets: int, yang_amt: int) -> Decimal:
    """
    Helper function to calculate the number of assets to be deposited to issue the
    given value of yang.

    Arguments
    ---------
    total_yang : int
        Total supply of yang before deposit in wad.
    total_assets : int
        Total assets held by vault in wad.
    yang_amt : int
        Amount of yang to be issued in wad.

    Returns
    -------
    Amount of assets to be deposited in Decimal.
    """
    return from_wad(total_assets) * from_wad(yang_amt) / from_wad(total_yang)


#
# Fixtures
#


@pytest.fixture
async def gate_rebasing_tax(starknet, shrine, rebasing_token) -> StarknetContract:
    """
    Deploys an instance of the Gate module with autocompounding and tax.
    """
    contract = compile_contract("tests/gate/rebasing_yang/test_gate_taxable.cairo")

    gate = await starknet.deploy(
        contract_class=contract,
        constructor_calldata=[
            ADMIN,
            shrine.contract_address,
            rebasing_token.contract_address,
            TAX_RAY,
            TAX_COLLECTOR,
        ],
    )

    # Grant `Abbot` access to `deposit` and `withdraw
    await gate.grant_role(ABBOT_ROLE, ABBOT).execute(caller_address=ADMIN)
    return gate


@pytest.fixture
async def gate_rebasing(starknet, shrine, rebasing_token) -> StarknetContract:
    """
    Deploys an instance of the Gate module, without any autocompounding or tax.
    """
    contract = compile_contract("contracts/gate/rebasing_yang/gate.cairo")
    gate = await starknet.deploy(
        contract_class=contract,
        constructor_calldata=[
            ADMIN,
            shrine.contract_address,
            rebasing_token.contract_address,
        ],
    )

    # Grant `Abbot` access to `deposit` and `withdraw
    await gate.grant_role(ABBOT_ROLE, ABBOT).execute(caller_address=ADMIN)
    return gate


@pytest.fixture
async def shrine_authed(shrine, gate, rebasing_token) -> StarknetContract:
    """
    Add Gate as an authorized address of Shrine.
    """

    # Grant `Gate` access to `deposit` and `withdraw` in `Shrine`
    role_value = ShrineRoles.DEPOSIT + ShrineRoles.WITHDRAW
    await shrine.grant_role(role_value, gate.contract_address).execute(caller_address=SHRINE_OWNER)

    # Add rebasing_token as Yang
    await shrine.add_yang(
        rebasing_token.contract_address,
        to_wad(1000),
        to_ray(Decimal("0.8")),
        to_wad(1000),
    ).execute(caller_address=SHRINE_OWNER)

    return shrine


@pytest.fixture
async def gate_deposit(shrine_authed, gate, rebasing_token) -> StarknetCallInfo:
    """
    Deposit by user 1.
    """

    # Approve Gate to transfer tokens from user
    await rebasing_token.approve(gate.contract_address, MAX_UINT256).execute(caller_address=TROVE1_OWNER)

    # Call deposit
    deposit = await gate.deposit(TROVE1_OWNER, TROVE_1, FIRST_DEPOSIT_AMT).execute(caller_address=ABBOT)

    return deposit


@pytest.fixture
async def gate_deposit_alt(gate, rebasing_token, gate_deposit) -> StarknetCallInfo:
    """
    Deposit by user 2 after user 1 has deposited but before rebase.
    """

    # Approve Gate to transfer tokens from user
    await rebasing_token.approve(gate.contract_address, MAX_UINT256).execute(caller_address=TROVE2_OWNER)

    # Call deposit
    deposit = await gate.deposit(TROVE2_OWNER, TROVE_2, FIRST_DEPOSIT_AMT).execute(caller_address=ABBOT)

    return deposit


@pytest.fixture
async def gate_deposit_alt_with_rebase(gate, rebasing_token, gate_deposit, rebase) -> StarknetCallInfo:
    """
    Deposit by user 2 after user 1 has deposited and after rebase.
    """

    # Approve Gate to transfer tokens from user
    await rebasing_token.approve(gate.contract_address, MAX_UINT256).execute(caller_address=TROVE2_OWNER)

    # Call deposit
    deposit = await gate.deposit(TROVE2_OWNER, TROVE_2, FIRST_DEPOSIT_AMT).execute(caller_address=ABBOT)
    return deposit


@pytest.fixture
async def rebase(gate, rebasing_token, gate_deposit) -> StarknetCallInfo:
    """
    Rebase the gate contract's balance by adding 10%
    """

    tx = await rebasing_token.mint(gate.contract_address, FIRST_REBASE_AMT_UINT).execute(caller_address=TROVE1_OWNER)
    return tx


@pytest.fixture
def gate(request) -> StarknetContract:
    """
    Wrapper fixture to pass the non-taxable and taxable instances of Gate module to `pytest.parametrize`.
    """
    return request.getfixturevalue(request.param)


#
# Tests - Setup
#


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_setup(gate, rebasing_token):
    # Check system is live
    live = (await gate.get_live().execute()).result.is_live
    assert live == TRUE

    # Check asset address
    assert (await gate.get_asset().execute()).result.asset == rebasing_token.contract_address

    # Check total assets
    asset_bal = (await gate.get_total_assets().execute()).result.total
    assert asset_bal == 0

    # Check Abbot address is authorized to deposit and withdraw
    abbot_role = (await gate.get_roles(ABBOT).execute()).result.roles
    assert abbot_role == ABBOT_ROLE

    # Check initial values
    assert (await gate.get_total_yang().execute()).result.total == 0

    # Check initial exchange rate
    exchange_rate = (await gate.get_exchange_rate().execute()).result.rate
    assert exchange_rate == 0

    if "get_tax" in gate._contract_functions:
        # Check tax
        tax = (await gate.get_tax().execute()).result.tax
        assert tax == TAX_RAY

        # Check tax collector
        tax_collector_address = (await gate.get_tax_collector().execute()).result.tax_collector
        assert tax_collector_address == TAX_COLLECTOR


#
# Tests - Gate
#


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_deposit_pass(shrine_authed, gate, rebasing_token, gate_deposit, collect_gas_cost):
    # 2 unique key updated for ERC20 transfer (Gate's balance, user's balance)
    # 2 keys updated for Shrine (`shrine_yangs_storage`, `shrine_deposits_storage`)
    #
    # Note that ReentrancyGuard updates 1 key but storage is not charged because value is reset
    # at the end of the transaction.
    collect_gas_cost("gate/deposit", gate_deposit, 4, 2)

    # Check gate asset balance
    total_bal = (await gate.get_total_assets().execute()).result.total
    assert total_bal == FIRST_DEPOSIT_AMT

    # Check gate yang balance
    total_yang = (await gate.get_total_yang().execute()).result.total
    user_yang = (await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_1).execute()).result.balance
    assert total_yang == user_yang == FIRST_DEPOSIT_AMT

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().execute()).result.rate
    assert exchange_rate == to_wad(1)

    # Check event
    assert_event_emitted(
        gate_deposit,
        gate.contract_address,
        "Deposit",
        [TROVE1_OWNER, TROVE_1, total_bal, user_yang],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_subsequent_deposit_with_rebase(shrine_authed, gate, rebasing_token, rebase):

    # Get gate asset and yang balance
    before_total_yang = (await gate.get_total_yang().execute()).result.total
    before_total_assets = (await gate.get_total_assets().execute()).result.total

    # Calculate expected yang
    expected_yang = get_yang_from_assets(before_total_yang, before_total_assets, SECOND_DEPOSIT_AMT)

    # Get user's yang before subsequent deposit
    before_user_yang = (
        await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_1).execute()
    ).result.balance

    # Call deposit
    deposit = await gate.deposit(TROVE1_OWNER, TROVE_1, SECOND_DEPOSIT_AMT).execute(caller_address=ABBOT)

    # Check gate asset balance
    total_assets = (await gate.get_total_assets().execute()).result.total
    expected_bal = INITIAL_AMT + FIRST_REBASE_AMT
    assert total_assets == expected_bal

    # Check vault yang balance
    after_total_yang = (await gate.get_total_yang().execute()).result.total
    assert_equalish(
        from_wad(after_total_yang),
        from_wad(before_total_yang) + expected_yang,
        CUSTOM_ERROR_MARGIN,
    )

    # Check user's yang
    after_user_yang = (
        await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_1).execute()
    ).result.balance
    assert_equalish(
        from_wad(after_user_yang),
        from_wad(before_user_yang) + expected_yang,
        CUSTOM_ERROR_MARGIN,
    )

    # Check event emitted
    assert_event_emitted(
        deposit,
        gate.contract_address,
        "Deposit",
        [TROVE1_OWNER, TROVE_1, SECOND_DEPOSIT_AMT, to_wad(expected_yang)],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_subsequent_unique_deposit_before_rebase(shrine_authed, gate, rebasing_token, gate_deposit_alt):

    # Check gate asset balance
    after_total_bal = (await gate.get_total_assets().execute()).result.total
    expected_bal = FIRST_DEPOSIT_AMT * 2
    assert after_total_bal == expected_bal

    # Check gate yang balance
    after_total_yang = (await gate.get_total_yang().execute()).result.total
    assert after_total_yang == after_total_bal

    # Check user's yang
    expected_yang = FIRST_DEPOSIT_AMT
    after_user_yang = (
        await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_2).execute()
    ).result.balance
    assert after_user_yang == expected_yang

    # Check event emitted
    assert_event_emitted(
        gate_deposit_alt,
        gate.contract_address,
        "Deposit",
        [TROVE2_OWNER, TROVE_2, FIRST_DEPOSIT_AMT, expected_yang],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_subsequent_unique_deposit_after_rebase(
    shrine_authed, gate, rebasing_token, gate_deposit_alt_with_rebase
):

    # Check gate asset balance
    after_total_bal = (await gate.get_total_assets().execute()).result.total
    expected_bal = FIRST_DEPOSIT_AMT * 2 + FIRST_REBASE_AMT
    assert after_total_bal == expected_bal

    # Calculate expected yang
    expected_yang = get_yang_from_assets(FIRST_DEPOSIT_AMT, FIRST_DEPOSIT_AMT + FIRST_REBASE_AMT, FIRST_DEPOSIT_AMT)

    # Check gate yang balance
    after_total_yang = (await gate.get_total_yang().execute()).result.total
    assert_equalish(
        from_wad(after_total_yang),
        from_wad(FIRST_DEPOSIT_AMT) + expected_yang,
        CUSTOM_ERROR_MARGIN,
    )

    # Check user's yang
    after_user_yang = (
        await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_2).execute()
    ).result.balance
    assert_equalish(from_wad(after_user_yang), expected_yang, CUSTOM_ERROR_MARGIN)

    # Check event emitted
    assert_event_emitted(
        gate_deposit_alt_with_rebase,
        gate.contract_address,
        "Deposit",
        [TROVE2_OWNER, TROVE_2, FIRST_DEPOSIT_AMT, after_user_yang],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_withdraw_before_rebase(shrine_authed, gate, rebasing_token, gate_deposit, collect_gas_cost):
    """
    Withdraw all yang before rebase.
    """
    # 2 unique key updated for ERC20 transfer (Gate's balance, user's balance)
    # 2 keys updated for Shrine (`shrine_yangs_storage`, `shrine_deposits_storage`)
    #
    # Note that ReentrancyGuard updates 1 key but storage is not charged because value is reset
    # at the end of the transaction.
    collect_gas_cost("gate/withdraw", gate_deposit, 4, 2)

    # Withdraw
    withdraw = await gate.withdraw(TROVE1_OWNER, TROVE_1, FIRST_DEPOSIT_AMT).execute(caller_address=ABBOT)

    # Fetch post-withdrawal balances
    after_user_balance = (await rebasing_token.balanceOf(TROVE1_OWNER).execute()).result.balance
    after_gate_balance = (await gate.get_total_assets().execute()).result.total

    # Assert user receives initial deposit
    assert from_uint(after_user_balance) == INITIAL_AMT
    assert after_gate_balance == 0

    # Fetch post-withdrawal yang
    after_user_yang = (
        await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_1).execute()
    ).result.balance
    total_yang = (await gate.get_total_yang().execute()).result.total

    assert after_user_yang == total_yang == 0

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().execute()).result.rate
    assert exchange_rate == 0

    # Check event
    assert_event_emitted(
        withdraw,
        gate.contract_address,
        "Withdraw",
        [TROVE1_OWNER, TROVE_1, FIRST_DEPOSIT_AMT, FIRST_DEPOSIT_AMT],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_withdraw_after_rebase_pass(shrine_authed, gate, rebasing_token, gate_deposit, rebase):
    """
    Withdraw all yang after rebase.
    """

    # withdraw
    withdraw = await gate.withdraw(TROVE1_OWNER, TROVE_1, FIRST_DEPOSIT_AMT).execute(caller_address=ABBOT)

    # Fetch post-withdrawal balances
    after_user_balance = (await rebasing_token.balanceOf(TROVE1_OWNER).execute()).result.balance
    after_gate_balance = (await gate.get_total_assets().execute()).result.total

    # Assert user receives initial deposit and rebased amount
    expected_user_balance = INITIAL_AMT + FIRST_REBASE_AMT
    assert from_uint(after_user_balance) == expected_user_balance
    assert after_gate_balance == 0

    # Fetch post-withdrawal yang
    after_user_yang = (
        await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_1).execute()
    ).result.balance
    total_yang = (await gate.get_total_yang().execute()).result.total

    assert after_user_yang == total_yang == 0

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().execute()).result.rate
    assert exchange_rate == 0

    expected_withdrawn_assets = FIRST_DEPOSIT_AMT + FIRST_REBASE_AMT
    # Check event
    assert_event_emitted(
        withdraw,
        gate.contract_address,
        "Withdraw",
        [TROVE1_OWNER, TROVE_1, expected_withdrawn_assets, FIRST_DEPOSIT_AMT],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_multi_user_withdraw_without_rebase(shrine_authed, gate, rebasing_token, gate_deposit_alt):

    # Get initial exchange rate
    start_exchange_rate = (await gate.get_exchange_rate().execute()).result.rate

    # Get initial balance for trove 2
    trove_2_yang = (await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_2).execute()).result.balance

    # Check gate asset balance
    start_total_bal = (await gate.get_total_assets().execute()).result.total
    start_total_yang = (await gate.get_total_yang().execute()).result.total
    start_user_bal = from_uint((await rebasing_token.balanceOf(TROVE2_OWNER).execute()).result.balance)

    # Withdraw trove 2
    trove_2_withdraw = await gate.withdraw(TROVE2_OWNER, TROVE_2, trove_2_yang).execute(caller_address=ABBOT)

    # Calculate expected assets
    expected_assets = get_assets_from_yang(start_total_yang, start_total_bal, trove_2_yang)

    # Check gate asset balance
    after_total_bal = (await gate.get_total_assets().execute()).result.total
    assert_equalish(
        from_wad(after_total_bal),
        from_wad(start_total_bal) - expected_assets,
        CUSTOM_ERROR_MARGIN,
    )

    # Check gate yang balance
    after_total_yang = (await gate.get_total_yang().execute()).result.total
    assert after_total_yang == start_total_yang - FIRST_DEPOSIT_AMT

    # Check user's yang
    after_user_yang = (
        await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_2).execute()
    ).result.balance
    assert after_user_yang == 0

    after_user_bal = from_uint((await rebasing_token.balanceOf(TROVE2_OWNER).execute()).result.balance)
    assert_equalish(
        from_wad(after_user_bal),
        from_wad(start_user_bal) + expected_assets,
        CUSTOM_ERROR_MARGIN,
    )

    # Check exchange rate
    after_exchange_rate = (await gate.get_exchange_rate().execute()).result.rate
    assert after_exchange_rate == start_exchange_rate

    # Check event emitted
    assert_event_emitted(
        trove_2_withdraw,
        gate.contract_address,
        "Withdraw",
        [TROVE2_OWNER, TROVE_2, FIRST_DEPOSIT_AMT, FIRST_DEPOSIT_AMT],
    )

    # Get user balance
    start_user_bal = from_uint((await rebasing_token.balanceOf(TROVE1_OWNER).execute()).result.balance)

    # Get initial balance for trove 2
    trove_1_yang = (await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_1).execute()).result.balance

    # Withdraw from trove 1
    trove_1_withdraw = await gate.withdraw(TROVE1_OWNER, TROVE_1, trove_1_yang).execute(caller_address=ABBOT)

    # Calculate expected assets
    expected_assets = get_assets_from_yang(after_total_yang, after_total_bal, trove_1_yang)

    # Check gate asset balance
    end_total_bal = (await gate.get_total_assets().execute()).result.total
    assert_equalish(
        from_wad(end_total_bal),
        from_wad(after_total_bal) - expected_assets,
        CUSTOM_ERROR_MARGIN,
    )

    # Check gate yang balance
    end_total_yang = (await gate.get_total_yang().execute()).result.total
    assert end_total_yang == 0

    # Check user's yang
    after_user_yang = (
        await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_1).execute()
    ).result.balance
    assert after_user_yang == 0

    after_user_bal = from_uint((await rebasing_token.balanceOf(TROVE1_OWNER).execute()).result.balance)
    assert_equalish(
        from_wad(after_user_bal),
        from_wad(start_user_bal) + expected_assets,
        CUSTOM_ERROR_MARGIN,
    )

    # Check exchange rate
    end_exchange_rate = (await gate.get_exchange_rate().execute()).result.rate
    assert end_exchange_rate == 0

    # Check event emitted
    assert_event_emitted(
        trove_1_withdraw,
        gate.contract_address,
        "Withdraw",
        [TROVE1_OWNER, TROVE_1, FIRST_DEPOSIT_AMT, FIRST_DEPOSIT_AMT],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_multi_user_withdraw_with_rebase(shrine_authed, gate, rebasing_token, gate_deposit_alt_with_rebase):

    # Get initial exchange rate
    start_exchange_rate = (await gate.get_exchange_rate().execute()).result.rate

    # Check gate asset balance
    start_total_bal = (await gate.get_total_assets().execute()).result.total
    start_total_yang = (await gate.get_total_yang().execute()).result.total
    start_user_bal = from_uint((await rebasing_token.balanceOf(TROVE2_OWNER).execute()).result.balance)
    trove_2_yang = (await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_2).execute()).result.balance

    # Withdraw from trove 2
    await gate.withdraw(TROVE2_OWNER, TROVE_2, trove_2_yang).execute(caller_address=ABBOT)

    # Calculate expected assets
    expected_assets = get_assets_from_yang(start_total_yang, start_total_bal, trove_2_yang)

    # Check gate asset balance
    after_total_bal = (await gate.get_total_assets().execute()).result.total

    # Using `assert_equalish` due to rounding error
    assert_equalish(
        from_wad(after_total_bal),
        from_wad(start_total_bal) - expected_assets,
        CUSTOM_ERROR_MARGIN,
    )

    # Check gate yang balance
    after_total_yang = (await gate.get_total_yang().execute()).result.total
    assert after_total_yang == start_total_yang - trove_2_yang

    # Check user's yang
    after_user_yang = (
        await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_2).execute()
    ).result.balance
    assert after_user_yang == 0

    after_user_bal = from_uint((await rebasing_token.balanceOf(TROVE2_OWNER).execute()).result.balance)

    # Using `assert_equalish` due to rounding error
    assert_equalish(
        from_wad(after_user_bal),
        from_wad(start_user_bal) + expected_assets,
        CUSTOM_ERROR_MARGIN,
    )

    # Check exchange rate
    after_exchange_rate = (await gate.get_exchange_rate().execute()).result.rate
    assert after_exchange_rate == start_exchange_rate

    # Get user balance
    start_user_bal = from_uint((await rebasing_token.balanceOf(TROVE1_OWNER).execute()).result.balance)
    trove_1_yang = (await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_1).execute()).result.balance

    # Calculate expected assets
    expected_assets = get_assets_from_yang(after_total_yang, after_total_bal, trove_1_yang)

    # Withdraw from trove 1
    await gate.withdraw(TROVE1_OWNER, TROVE_1, trove_1_yang).execute(caller_address=ABBOT)

    # Check gate asset balance
    end_total_bal = (await gate.get_total_assets().execute()).result.total
    assert_equalish(
        from_wad(end_total_bal),
        from_wad(after_total_bal) - expected_assets,
        CUSTOM_ERROR_MARGIN,
    )

    # Check gate yang balance
    end_total_yang = (await gate.get_total_yang().execute()).result.total
    assert end_total_yang == 0

    # Check user's yang
    after_user_yang = (
        await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_1).execute()
    ).result.balance
    assert after_user_yang == 0

    after_user_bal = from_uint((await rebasing_token.balanceOf(TROVE1_OWNER).execute()).result.balance)
    assert_equalish(
        from_wad(after_user_bal),
        from_wad(start_user_bal) + expected_assets,
        CUSTOM_ERROR_MARGIN,
    )

    # Check exchange rate
    end_exchange_rate = (await gate.get_exchange_rate().execute()).result.rate
    assert end_exchange_rate == 0


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_kill(shrine_authed, gate, rebasing_token, gate_deposit, rebase):

    # Kill
    await gate.kill().execute(caller_address=ADMIN)
    assert (await gate.get_live().execute()).result.is_live == FALSE

    # Assert deposit fails
    with pytest.raises(StarkException, match="Gate: Gate is not live"):
        await gate.deposit(TROVE1_OWNER, TROVE_1, SECOND_DEPOSIT_AMT).execute(caller_address=ABBOT)

    # Assert withdraw succeeds
    withdraw_amt = to_wad(5)

    # Get user's and gate's asset and yang balances before withdraw
    before_user_balance = from_uint((await rebasing_token.balanceOf(TROVE1_OWNER).execute()).result.balance)
    before_gate_balance = (await gate.get_total_assets().execute()).result.total

    before_user_yang = (
        await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_1).execute()
    ).result.balance
    before_gate_yang = (await gate.get_total_yang().execute()).result.total

    expected_assets = get_assets_from_yang(before_gate_yang, before_gate_balance, withdraw_amt)

    # Withdraw
    await gate.withdraw(TROVE1_OWNER, TROVE_1, withdraw_amt).execute(caller_address=ABBOT)

    # Get user's and gate's asset and share balances after withdraw
    after_user_balance = from_uint((await rebasing_token.balanceOf(TROVE1_OWNER).execute()).result.balance)
    after_gate_balance = (await gate.get_total_assets().execute()).result.total

    after_user_yang = (
        await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_1).execute()
    ).result.balance
    after_gate_yang = (await gate.get_total_yang().execute()).result.total

    # Assert withdrawal is successful
    assert_equalish(
        from_wad(after_user_balance),
        from_wad(before_user_balance) + expected_assets,
        CUSTOM_ERROR_MARGIN,
    )
    assert_equalish(
        from_wad(after_gate_balance),
        from_wad(before_gate_balance) - expected_assets,
        CUSTOM_ERROR_MARGIN,
    )

    assert after_user_yang == before_user_yang - withdraw_amt
    assert after_gate_yang == before_gate_yang - withdraw_amt


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_deposit_insufficient_fail(shrine_authed, gate, rebasing_token):

    # Approve Gate to transfer asset from user
    await rebasing_token.approve(gate.contract_address, MAX_UINT256).execute(TROVE1_OWNER)
    # Call deposit with more asset than user has
    with pytest.raises(StarkException, match="Gate: Transfer of asset failed"):
        await gate.deposit(TROVE1_OWNER, TROVE_1, INITIAL_AMT + 1).execute(caller_address=ABBOT)


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_withdraw_insufficient_fail(shrine_authed, gate, rebasing_token, gate_deposit):

    # Call withdraw with more gate yang than user has
    with pytest.raises(StarkException, match="Shrine: Insufficient yang"):
        await gate.withdraw(TROVE1_OWNER, TROVE_1, FIRST_DEPOSIT_AMT + 1).execute(caller_address=ABBOT)


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_unauthorized_deposit(rebasing_token, gate):
    """Test third-party initiated"""

    # Seed unauthorized address with asset
    await rebasing_token.mint(BAD_GUY, INITIAL_AMT_UINT).execute(caller_address=BAD_GUY)

    # Sanity check
    assert from_uint((await rebasing_token.balanceOf(BAD_GUY).execute()).result.balance) == INITIAL_AMT

    with pytest.raises(StarkException):
        await gate.deposit(TROVE1_OWNER, TROVE_1, FIRST_DEPOSIT_AMT).execute(caller_address=BAD_GUY)


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_unauthorized_withdraw(shrine_authed, gate, rebasing_token, gate_deposit):
    """Test user-initiated"""

    # Sanity check
    bal = (await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_1).execute()).result.balance
    assert bal == INITIAL_AMT - FIRST_DEPOSIT_AMT

    with pytest.raises(StarkException):
        await gate.withdraw(TROVE1_OWNER, TROVE_1, FIRST_MINT_AMT).execute(caller_address=TROVE1_OWNER)


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.parametrize("fn", ["deposit", "withdraw"])
@pytest.mark.asyncio
async def test_zero_deposit_withdraw(shrine_authed, gate, rebasing_token, gate_deposit, fn):

    # Get balance before
    before_yang_bal = (
        await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_1).execute()
    ).result.balance
    before_asset_bal = from_uint((await rebasing_token.balanceOf(TROVE1_OWNER).execute()).result.balance)

    # Call deposit
    await getattr(gate, fn)(TROVE1_OWNER, TROVE_1, 0).execute(caller_address=ABBOT)

    # Get balance after
    after_yang_bal = (
        await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_1).execute()
    ).result.balance
    after_asset_bal = from_uint((await rebasing_token.balanceOf(TROVE1_OWNER).execute()).result.balance)

    assert before_yang_bal == after_yang_bal
    assert before_asset_bal == after_asset_bal


#
# Tests - Tax
#


@pytest.mark.asyncio
async def test_gate_constructor_invalid_tax(shrine, starknet, rebasing_token):
    contract = compile_contract("contracts/gate/rebasing_yang/gate_taxable.cairo")

    with pytest.raises(StarkException):
        await starknet.deploy(
            contract_class=contract,
            constructor_calldata=[
                ABBOT,
                shrine.contract_address,
                rebasing_token.contract_address,
                to_ray(TAX_MAX) + 1,
                TAX_COLLECTOR,
            ],
        )


@pytest.mark.asyncio
async def test_gate_set_tax_pass(gate_rebasing_tax):
    gate = gate_rebasing_tax

    tx = await gate.set_tax(TAX_RAY // 2).execute(caller_address=ADMIN)
    assert_event_emitted(tx, gate.contract_address, "TaxUpdated", [TAX_RAY, TAX_RAY // 2])

    new_tax = (await gate.get_tax().execute()).result.tax
    assert new_tax == TAX_RAY // 2


@pytest.mark.asyncio
async def test_gate_set_tax_collector(gate_rebasing_tax):
    gate = gate_rebasing_tax

    new_tax_collector = 9876
    tx = await gate.set_tax_collector(new_tax_collector).execute(caller_address=ADMIN)

    assert_event_emitted(
        tx,
        gate.contract_address,
        "TaxCollectorUpdated",
        [TAX_COLLECTOR, new_tax_collector],
    )

    res = (await gate.get_tax_collector().execute()).result.tax_collector
    assert res == new_tax_collector


@pytest.mark.asyncio
async def test_gate_set_tax_parameters_fail(gate_rebasing_tax):
    gate = gate_rebasing_tax

    # Fails due to max tax exceeded
    with pytest.raises(StarkException, match="Gate: Maximum tax exceeded"):
        await gate.set_tax(to_ray(TAX_MAX) + 1).execute(caller_address=ADMIN)

    # Fails due to non-authorised address
    set_tax_role = GateRoles.SET_TAX
    with pytest.raises(StarkException, match=f"AccessControl: caller is missing role {set_tax_role}"):
        await gate.set_tax(TAX_RAY).execute(caller_address=BAD_GUY)
        await gate.set_tax_collector(BAD_GUY).execute(caller_address=BAD_GUY)

    # Fails due to zero address
    with pytest.raises(StarkException, match="Gate: Invalid tax collector address"):
        await gate.set_tax_collector(ZERO_ADDRESS).execute(caller_address=ADMIN)


@pytest.mark.parametrize("gate", ["gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_levy(shrine_authed, gate, rebasing_token, gate_deposit):
    # `rebase` fixture simulates an autocompounding

    # Get balances before levy
    before_tax_collector_bal = from_uint((await rebasing_token.balanceOf(TAX_COLLECTOR).execute()).result.balance)
    before_gate_bal = (await gate.get_total_assets().execute()).result.total

    # Update Gate's balance and charge tax
    levy = await gate.levy().execute(caller_address=ABBOT)

    # Check Gate's managed assets and balance
    after_gate_bal = (await gate.get_total_assets().execute()).result.total
    assert after_gate_bal > before_gate_bal
    assert after_gate_bal == before_gate_bal * COMPOUND_MULTIPLIER - FIRST_TAX_AMT

    # Check that user's withdrawable balance has increased
    user_yang = (await shrine_authed.get_deposit(rebasing_token.contract_address, TROVE_1).execute()).result.balance
    expected_user_assets = (await gate.preview_withdraw(user_yang).execute()).result.preview
    assert expected_user_assets == after_gate_bal

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().execute()).result.rate
    expected_exchange_rate = int(after_gate_bal / from_wad(user_yang))
    assert exchange_rate == expected_exchange_rate

    # Check tax collector has received tax
    after_tax_collector_bal = from_uint((await rebasing_token.balanceOf(TAX_COLLECTOR).execute()).result.balance)
    assert after_tax_collector_bal == before_tax_collector_bal + FIRST_TAX_AMT

    # Check event emitted
    # Event should be emitted if tax is successfully transferred to tax collector.
    assert_event_emitted(levy, gate.contract_address, "TaxLevied", [FIRST_TAX_AMT])

    # Check balances before withdraw
    before_user_bal = from_uint((await rebasing_token.balanceOf(TROVE1_OWNER).execute()).result.balance)

    # Withdraw
    await gate.withdraw(TROVE1_OWNER, TROVE_1, user_yang).execute(caller_address=ABBOT)

    # Get balances after withdraw
    after_user_bal = from_uint((await rebasing_token.balanceOf(TROVE1_OWNER).execute()).result.balance)
    assert after_user_bal == before_user_bal + expected_user_assets
