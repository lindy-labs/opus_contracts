from decimal import Decimal

import pytest
from starkware.starknet.testing.objects import StarknetTransactionExecutionInfo
from starkware.starknet.testing.starknet import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.gate.rebasing_yang.constants import *  # noqa: F403
from tests.shrine.constants import TROVE_1, TROVE_2
from tests.utils import (
    FALSE,
    MAX_UINT256,
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
async def gate_rebasing_tax(starknet_func_scope, users, shrine, rebasing_token) -> StarknetContract:
    """
    Deploys an instance of the Gate module with autocompounding and tax.
    """
    starknet = starknet_func_scope

    contract = compile_contract("tests/gate/rebasing_yang/test_gate_taxable.cairo")
    admin = await users("admin")
    tax_collector = await users("tax collector")
    gate = await starknet.deploy(
        contract_class=contract,
        constructor_calldata=[
            admin.address,
            shrine.contract_address,
            rebasing_token.contract_address,
            TAX_RAY,
            tax_collector.address,
        ],
    )

    # Authorise Abbot
    abbot = await users("abbot")
    await admin.send_tx(gate.contract_address, "authorize", [abbot.address])

    return gate


@pytest.fixture
async def gate_rebasing(starknet_func_scope, users, shrine, rebasing_token) -> StarknetContract:
    """
    Deploys an instance of the Gate module, without any autocompounding or tax.
    """
    starknet = starknet_func_scope

    contract = compile_contract("contracts/gate/rebasing_yang/gate.cairo")
    admin = await users("admin")
    gate = await starknet.deploy(
        contract_class=contract,
        constructor_calldata=[
            admin.address,
            shrine.contract_address,
            rebasing_token.contract_address,
        ],
    )

    # Authorise Abbot
    abbot = await users("abbot")
    await admin.send_tx(gate.contract_address, "authorize", [abbot.address])

    return gate


@pytest.fixture
async def shrine_authed(users, shrine, gate, rebasing_token) -> StarknetContract:
    """
    Add Gate as an authorized address of Shrine.
    """
    shrine_owner = await users("shrine owner")

    # Add Gate as authorized
    await shrine_owner.send_tx(shrine.contract_address, "authorize", [gate.contract_address])

    # Add rebasing_token as Yang
    await shrine_owner.send_tx(
        shrine.contract_address,
        "add_yang",
        [rebasing_token.contract_address, to_wad(1000), to_ray(Decimal("0.8")), to_wad(1000)],
    )

    return shrine


@pytest.fixture
async def gate_deposit(users, shrine_authed, gate, rebasing_token) -> StarknetTransactionExecutionInfo:
    """
    Deposit by user 1.
    """
    trove_1_owner = await users("trove 1 owner")
    abbot = await users("abbot")

    # Approve Gate to transfer tokens from user
    await trove_1_owner.send_tx(rebasing_token.contract_address, "approve", [gate.contract_address, *MAX_UINT256])

    # Call deposit
    deposit = await abbot.send_tx(gate.contract_address, "deposit", [trove_1_owner.address, TROVE_1, FIRST_DEPOSIT_AMT])
    return deposit


@pytest.fixture
async def gate_deposit_alt(users, gate, rebasing_token, gate_deposit) -> StarknetTransactionExecutionInfo:
    """
    Deposit by user 2 after user 1 has deposited but before rebase.
    """
    trove_2_owner = await users("trove 2 owner")
    abbot = await users("abbot")

    # Approve Gate to transfer tokens from user
    await trove_2_owner.send_tx(rebasing_token.contract_address, "approve", [gate.contract_address, *MAX_UINT256])

    # Call deposit
    deposit = await abbot.send_tx(gate.contract_address, "deposit", [trove_2_owner.address, TROVE_2, FIRST_DEPOSIT_AMT])
    return deposit


@pytest.fixture
async def gate_deposit_alt_with_rebase(
    users, gate, rebasing_token, gate_deposit, rebase
) -> StarknetTransactionExecutionInfo:
    """
    Deposit by user 2 after user 1 has deposited and after rebase.
    """
    trove_2_owner = await users("trove 2 owner")
    abbot = await users("abbot")

    # Approve Gate to transfer tokens from user
    await trove_2_owner.send_tx(rebasing_token.contract_address, "approve", [gate.contract_address, *MAX_UINT256])

    # Call deposit
    deposit = await abbot.send_tx(gate.contract_address, "deposit", [trove_2_owner.address, TROVE_2, FIRST_DEPOSIT_AMT])
    return deposit


@pytest.fixture
async def rebase(users, gate, rebasing_token, gate_deposit) -> StarknetTransactionExecutionInfo:
    """
    Rebase the gate contract's balance by adding 10%
    """
    trove_1_owner = await users("trove 1 owner")

    tx = await trove_1_owner.send_tx(
        rebasing_token.contract_address, "mint", [gate.contract_address, *FIRST_REBASE_AMT_UINT]
    )
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
async def test_gate_setup(gate, users, rebasing_token):
    # Check system is live
    live = (await gate.get_live().invoke()).result.bool
    assert live == TRUE

    # Check asset address
    assert (await gate.get_asset().invoke()).result.address == rebasing_token.contract_address

    # Check total assets
    asset_bal = (await gate.get_total_assets().invoke()).result.wad
    assert asset_bal == 0

    # Check Abbot address is authorized
    abbot = await users("abbot")
    authorized = (await gate.get_auth(abbot.address).invoke()).result.bool
    assert authorized == TRUE

    # Check initial values
    assert (await gate.get_total_yang().invoke()).result.wad == 0

    # Check initial exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == 0

    if "get_tax" in gate._contract_functions:
        # Check tax
        tax = (await gate.get_tax().invoke()).result.ray
        assert tax == TAX_RAY

        # Check tax collector
        tax_collector = await users("tax collector")
        tax_collector_address = (await gate.get_tax_collector().invoke()).result.address
        assert tax_collector_address == tax_collector.address


#
# Tests - Gate
#


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_deposit_pass(users, shrine_authed, gate, rebasing_token, gate_deposit, collect_gas_cost):
    # 2 unique key updated for ERC20 transfer (Gate's balance, user's balance)
    # 2 keys updated for Shrine (`shrine_yangs_storage`, `shrine_deposits_storage`)
    #
    # Note that ReentrancyGuard updates 1 key but storage is not charged because value is reset
    # at the end of the transaction.
    collect_gas_cost("gate/deposit", gate_deposit, 4, 2)

    trove_1_owner = await users("trove 1 owner")

    # Check gate asset balance
    total_bal = (await gate.get_total_assets().invoke()).result.wad
    assert total_bal == FIRST_DEPOSIT_AMT

    # Check gate yang balance
    total_yang = (await gate.get_total_yang().invoke()).result.wad
    user_yang = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    assert total_yang == user_yang == FIRST_DEPOSIT_AMT

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == to_wad(1)

    # Check event
    assert_event_emitted(
        gate_deposit,
        gate.contract_address,
        "Deposit",
        [trove_1_owner.address, TROVE_1, total_bal, user_yang],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_subsequent_deposit_with_rebase(users, shrine_authed, gate, rebasing_token, rebase):
    abbot = await users("abbot")
    trove_1_owner = await users("trove 1 owner")

    # Get gate asset and yang balance
    before_total_yang = (await gate.get_total_yang().invoke()).result.wad
    before_total_assets = (await gate.get_total_assets().invoke()).result.wad

    # Calculate expected yang
    expected_yang = get_yang_from_assets(before_total_yang, before_total_assets, SECOND_DEPOSIT_AMT)

    # Get user's yang before subsequent deposit
    before_user_yang = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad

    # Call deposit
    deposit = await abbot.send_tx(
        gate.contract_address,
        "deposit",
        [trove_1_owner.address, TROVE_1, SECOND_DEPOSIT_AMT],
    )

    # Check gate asset balance
    total_assets = (await gate.get_total_assets().invoke()).result.wad
    expected_bal = INITIAL_AMT + FIRST_REBASE_AMT
    assert total_assets == expected_bal

    # Check vault yang balance
    after_total_yang = (await gate.get_total_yang().invoke()).result.wad
    assert_equalish(from_wad(after_total_yang), from_wad(before_total_yang) + expected_yang, CUSTOM_ERROR_MARGIN)

    # Check user's yang
    after_user_yang = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    assert_equalish(from_wad(after_user_yang), from_wad(before_user_yang) + expected_yang, CUSTOM_ERROR_MARGIN)

    # Check event emitted
    assert_event_emitted(
        deposit,
        gate.contract_address,
        "Deposit",
        [trove_1_owner.address, TROVE_1, SECOND_DEPOSIT_AMT, to_wad(expected_yang)],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_subsequent_unique_deposit_before_rebase(
    users, shrine_authed, gate, rebasing_token, gate_deposit_alt
):
    trove_2_owner = await users("trove 2 owner")

    # Check gate asset balance
    after_total_bal = (await gate.get_total_assets().invoke()).result.wad
    expected_bal = FIRST_DEPOSIT_AMT * 2
    assert after_total_bal == expected_bal

    # Check gate yang balance
    after_total_yang = (await gate.get_total_yang().invoke()).result.wad
    assert after_total_yang == after_total_bal

    # Check user's yang
    expected_yang = FIRST_DEPOSIT_AMT
    after_user_yang = (await shrine_authed.get_deposit(TROVE_2, rebasing_token.contract_address).invoke()).result.wad
    assert after_user_yang == expected_yang

    # Check event emitted
    assert_event_emitted(
        gate_deposit_alt,
        gate.contract_address,
        "Deposit",
        [trove_2_owner.address, TROVE_2, FIRST_DEPOSIT_AMT, expected_yang],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_subsequent_unique_deposit_after_rebase(
    users, shrine_authed, gate, rebasing_token, gate_deposit_alt_with_rebase
):
    trove_2_owner = await users("trove 2 owner")

    # Check gate asset balance
    after_total_bal = (await gate.get_total_assets().invoke()).result.wad
    expected_bal = FIRST_DEPOSIT_AMT * 2 + FIRST_REBASE_AMT
    assert after_total_bal == expected_bal

    # Calculate expected yang
    expected_yang = get_yang_from_assets(FIRST_DEPOSIT_AMT, FIRST_DEPOSIT_AMT + FIRST_REBASE_AMT, FIRST_DEPOSIT_AMT)

    # Check gate yang balance
    after_total_yang = (await gate.get_total_yang().invoke()).result.wad
    assert_equalish(from_wad(after_total_yang), from_wad(FIRST_DEPOSIT_AMT) + expected_yang, CUSTOM_ERROR_MARGIN)

    # Check user's yang
    after_user_yang = (await shrine_authed.get_deposit(TROVE_2, rebasing_token.contract_address).invoke()).result.wad
    assert_equalish(from_wad(after_user_yang), expected_yang, CUSTOM_ERROR_MARGIN)

    # Check event emitted
    assert_event_emitted(
        gate_deposit_alt_with_rebase,
        gate.contract_address,
        "Deposit",
        [trove_2_owner.address, TROVE_2, FIRST_DEPOSIT_AMT, after_user_yang],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_withdraw_before_rebase(users, shrine_authed, gate, rebasing_token, gate_deposit, collect_gas_cost):
    """
    Withdraw all yang before rebase.
    """
    # 2 unique key updated for ERC20 transfer (Gate's balance, user's balance)
    # 2 keys updated for Shrine (`shrine_yangs_storage`, `shrine_deposits_storage`)
    #
    # Note that ReentrancyGuard updates 1 key but storage is not charged because value is reset
    # at the end of the transaction.
    collect_gas_cost("gate/withdraw", gate_deposit, 4, 2)

    abbot = await users("abbot")
    trove_1_owner = await users("trove 1 owner")

    # Withdraw
    withdraw = await abbot.send_tx(
        gate.contract_address,
        "withdraw",
        [trove_1_owner.address, TROVE_1, FIRST_DEPOSIT_AMT],
    )

    # Fetch post-redemption balances
    after_user_balance = (await rebasing_token.balanceOf(trove_1_owner.address).invoke()).result.balance
    after_gate_balance = (await gate.get_total_assets().invoke()).result.wad

    # Assert user receives initial deposit
    assert from_uint(after_user_balance) == INITIAL_AMT
    assert after_gate_balance == 0

    # Fetch post-redemption yang
    after_user_yang = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    total_yang = (await gate.get_total_yang().invoke()).result.wad

    assert after_user_yang == total_yang == 0

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == 0

    # Check event
    assert_event_emitted(
        withdraw,
        gate.contract_address,
        "Withdraw",
        [trove_1_owner.address, TROVE_1, FIRST_DEPOSIT_AMT, FIRST_DEPOSIT_AMT],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_withdraw_after_rebase_pass(users, shrine_authed, gate, rebasing_token, gate_deposit, rebase):
    """
    Withdraw all yang after rebase.
    """
    abbot = await users("abbot")
    trove_1_owner = await users("trove 1 owner")

    # withdraw
    withdraw = await abbot.send_tx(
        gate.contract_address,
        "withdraw",
        [trove_1_owner.address, TROVE_1, FIRST_DEPOSIT_AMT],
    )

    # Fetch post-redemption balances
    after_user_balance = (await rebasing_token.balanceOf(trove_1_owner.address).invoke()).result.balance
    after_gate_balance = (await gate.get_total_assets().invoke()).result.wad

    # Assert user receives initial deposit and rebased amount
    expected_user_balance = INITIAL_AMT + FIRST_REBASE_AMT
    assert from_uint(after_user_balance) == expected_user_balance
    assert after_gate_balance == 0

    # Fetch post-redemption yang
    after_user_yang = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    total_yang = (await gate.get_total_yang().invoke()).result.wad

    assert after_user_yang == total_yang == 0

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == 0

    expected_withdrawn_assets = FIRST_DEPOSIT_AMT + FIRST_REBASE_AMT
    # Check event
    assert_event_emitted(
        withdraw,
        gate.contract_address,
        "Withdraw",
        [trove_1_owner.address, TROVE_1, expected_withdrawn_assets, FIRST_DEPOSIT_AMT],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_multi_user_withdraw_without_rebase(users, shrine_authed, gate, rebasing_token, gate_deposit_alt):
    abbot = await users("abbot")
    trove_1_owner = await users("trove 1 owner")
    trove_2_owner = await users("trove 2 owner")

    # Get initial exchange rate
    start_exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad

    # Get initial balance for trove 2
    trove_2_yang = (await shrine_authed.get_deposit(TROVE_2, rebasing_token.contract_address).invoke()).result.wad

    # Check gate asset balance
    start_total_bal = (await gate.get_total_assets().invoke()).result.wad
    start_total_yang = (await gate.get_total_yang().invoke()).result.wad
    start_user_bal = from_uint((await rebasing_token.balanceOf(trove_2_owner.address).invoke()).result.balance)

    # Withdraw trove 2
    trove_2_withdraw = await abbot.send_tx(
        gate.contract_address, "withdraw", [trove_2_owner.address, TROVE_2, trove_2_yang]
    )

    # Calculate expected assets
    expected_assets = get_assets_from_yang(start_total_yang, start_total_bal, trove_2_yang)

    # Check gate asset balance
    after_total_bal = (await gate.get_total_assets().invoke()).result.wad
    assert_equalish(from_wad(after_total_bal), from_wad(start_total_bal) - expected_assets, CUSTOM_ERROR_MARGIN)

    # Check gate yang balance
    after_total_yang = (await gate.get_total_yang().invoke()).result.wad
    assert after_total_yang == start_total_yang - FIRST_DEPOSIT_AMT

    # Check user's yang
    after_user_yang = (await shrine_authed.get_deposit(TROVE_2, rebasing_token.contract_address).invoke()).result.wad
    assert after_user_yang == 0

    after_user_bal = from_uint((await rebasing_token.balanceOf(trove_2_owner.address).invoke()).result.balance)
    assert_equalish(from_wad(after_user_bal), from_wad(start_user_bal) + expected_assets, CUSTOM_ERROR_MARGIN)

    # Check exchange rate
    after_exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert after_exchange_rate == start_exchange_rate

    # Check event emitted
    assert_event_emitted(
        trove_2_withdraw,
        gate.contract_address,
        "Withdraw",
        [trove_2_owner.address, TROVE_2, FIRST_DEPOSIT_AMT, FIRST_DEPOSIT_AMT],
    )

    # Get user balance
    start_user_bal = from_uint((await rebasing_token.balanceOf(trove_1_owner.address).invoke()).result.balance)

    # Get initial balance for trove 2
    trove_1_yang = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad

    # Withdraw from trove 1
    trove_1_withdraw = await abbot.send_tx(
        gate.contract_address, "withdraw", [trove_1_owner.address, TROVE_1, trove_1_yang]
    )

    # Calculate expected assets
    expected_assets = get_assets_from_yang(after_total_yang, after_total_bal, trove_1_yang)

    # Check gate asset balance
    end_total_bal = (await gate.get_total_assets().invoke()).result.wad
    assert_equalish(from_wad(end_total_bal), from_wad(after_total_bal) - expected_assets, CUSTOM_ERROR_MARGIN)

    # Check gate yang balance
    end_total_yang = (await gate.get_total_yang().invoke()).result.wad
    assert end_total_yang == 0

    # Check user's yang
    after_user_yang = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    assert after_user_yang == 0

    after_user_bal = from_uint((await rebasing_token.balanceOf(trove_1_owner.address).invoke()).result.balance)
    assert_equalish(from_wad(after_user_bal), from_wad(start_user_bal) + expected_assets, CUSTOM_ERROR_MARGIN)

    # Check exchange rate
    end_exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert end_exchange_rate == 0

    # Check event emitted
    assert_event_emitted(
        trove_1_withdraw,
        gate.contract_address,
        "Withdraw",
        [trove_1_owner.address, TROVE_1, FIRST_DEPOSIT_AMT, FIRST_DEPOSIT_AMT],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_multi_user_withdraw_with_rebase(
    users, shrine_authed, gate, rebasing_token, gate_deposit_alt_with_rebase
):
    abbot = await users("abbot")
    trove_1_owner = await users("trove 1 owner")
    trove_2_owner = await users("trove 2 owner")

    # Get initial exchange rate
    start_exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad

    # Check gate asset balance
    start_total_bal = (await gate.get_total_assets().invoke()).result.wad
    start_total_yang = (await gate.get_total_yang().invoke()).result.wad
    start_user_bal = from_uint((await rebasing_token.balanceOf(trove_2_owner.address).invoke()).result.balance)
    trove_2_yang = (await shrine_authed.get_deposit(TROVE_2, rebasing_token.contract_address).invoke()).result.wad

    # Withdraw from trove 2
    await abbot.send_tx(gate.contract_address, "withdraw", [trove_2_owner.address, TROVE_2, trove_2_yang])

    # Calculate expected assets
    expected_assets = get_assets_from_yang(start_total_yang, start_total_bal, trove_2_yang)

    # Check gate asset balance
    after_total_bal = (await gate.get_total_assets().invoke()).result.wad

    # Using `assert_equalish` due to rounding error
    assert_equalish(from_wad(after_total_bal), from_wad(start_total_bal) - expected_assets, CUSTOM_ERROR_MARGIN)

    # Check gate yang balance
    after_total_yang = (await gate.get_total_yang().invoke()).result.wad
    assert after_total_yang == start_total_yang - trove_2_yang

    # Check user's yang
    after_user_yang = (await shrine_authed.get_deposit(TROVE_2, rebasing_token.contract_address).invoke()).result.wad
    assert after_user_yang == 0

    after_user_bal = from_uint((await rebasing_token.balanceOf(trove_2_owner.address).invoke()).result.balance)

    # Using `assert_equalish` due to rounding error
    assert_equalish(from_wad(after_user_bal), from_wad(start_user_bal) + expected_assets, CUSTOM_ERROR_MARGIN)

    # Check exchange rate
    after_exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert after_exchange_rate == start_exchange_rate

    # Get user balance
    start_user_bal = from_uint((await rebasing_token.balanceOf(trove_1_owner.address).invoke()).result.balance)
    trove_1_yang = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad

    # Calculate expected assets
    expected_assets = get_assets_from_yang(after_total_yang, after_total_bal, trove_1_yang)

    # Withdraw from trove 1
    await abbot.send_tx(gate.contract_address, "withdraw", [trove_1_owner.address, TROVE_1, trove_1_yang])

    # Check gate asset balance
    end_total_bal = (await gate.get_total_assets().invoke()).result.wad
    assert_equalish(from_wad(end_total_bal), from_wad(after_total_bal) - expected_assets, CUSTOM_ERROR_MARGIN)

    # Check gate yang balance
    end_total_yang = (await gate.get_total_yang().invoke()).result.wad
    assert end_total_yang == 0

    # Check user's yang
    after_user_yang = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    assert after_user_yang == 0

    after_user_bal = from_uint((await rebasing_token.balanceOf(trove_1_owner.address).invoke()).result.balance)
    assert_equalish(from_wad(after_user_bal), from_wad(start_user_bal) + expected_assets, CUSTOM_ERROR_MARGIN)

    # Check exchange rate
    end_exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert end_exchange_rate == 0


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_kill(users, shrine_authed, gate, rebasing_token, gate_deposit, rebase):
    abbot = await users("abbot")
    trove_1_owner = await users("trove 1 owner")

    # Kill
    await abbot.send_tx(gate.contract_address, "kill", [])
    assert (await gate.get_live().invoke()).result.bool == FALSE

    # Assert deposit fails
    with pytest.raises(StarkException, match="Gate: Gate is not live"):
        await abbot.send_tx(
            gate.contract_address,
            "deposit",
            [trove_1_owner.address, TROVE_1, SECOND_DEPOSIT_AMT],
        )

    # Assert withdraw succeeds
    withdraw_amt = to_wad(5)

    # Get user's and gate's asset and yang balances before withdraw
    before_user_balance = from_uint((await rebasing_token.balanceOf(trove_1_owner.address).invoke()).result.balance)
    before_gate_balance = (await gate.get_total_assets().invoke()).result.wad

    before_user_yang = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    before_gate_yang = (await gate.get_total_yang().invoke()).result.wad

    expected_assets = get_assets_from_yang(before_gate_yang, before_gate_balance, withdraw_amt)

    # Withdraw
    await abbot.send_tx(gate.contract_address, "withdraw", [trove_1_owner.address, TROVE_1, withdraw_amt])

    # Get user's and gate's asset and share balances after withdraw
    after_user_balance = from_uint((await rebasing_token.balanceOf(trove_1_owner.address).invoke()).result.balance)
    after_gate_balance = (await gate.get_total_assets().invoke()).result.wad

    after_user_yang = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    after_gate_yang = (await gate.get_total_yang().invoke()).result.wad

    # Assert redemption is successful
    assert_equalish(from_wad(after_user_balance), from_wad(before_user_balance) + expected_assets, CUSTOM_ERROR_MARGIN)
    assert_equalish(from_wad(after_gate_balance), from_wad(before_gate_balance) - expected_assets, CUSTOM_ERROR_MARGIN)

    assert after_user_yang == before_user_yang - withdraw_amt
    assert after_gate_yang == before_gate_yang - withdraw_amt


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_deposit_insufficient_fail(users, shrine_authed, gate, rebasing_token):
    trove_1_owner = await users("trove 1 owner")
    abbot = await users("abbot")

    # Approve Gate to transfer asset from user
    await trove_1_owner.send_tx(rebasing_token.contract_address, "approve", [gate.contract_address, *MAX_UINT256])

    # Call deposit with more asset than user has
    with pytest.raises(StarkException, match="Gate: Transfer of asset failed"):
        await abbot.send_tx(gate.contract_address, "deposit", [trove_1_owner.address, TROVE_1, INITIAL_AMT + 1])


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_withdraw_insufficient_fail(users, shrine_authed, gate, rebasing_token, gate_deposit):
    trove_1_owner = await users("trove 1 owner")
    abbot = await users("abbot")

    # Call withdraw with more gate yang than user has
    with pytest.raises(StarkException, match="Shrine: Insufficient yang"):
        await abbot.send_tx(
            gate.contract_address,
            "withdraw",
            [trove_1_owner.address, TROVE_1, FIRST_DEPOSIT_AMT + 1],
        )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_unauthorized_deposit(users, rebasing_token, gate):
    """Test third-party initiated"""
    trove_1_owner = await users("trove 1 owner")
    bad_guy = await users("bad guy")

    # Seed unauthorized address with asset
    await bad_guy.send_tx(rebasing_token.contract_address, "mint", [bad_guy.address, *INITIAL_AMT_UINT])
    # Sanity check
    assert from_uint((await rebasing_token.balanceOf(bad_guy.address).invoke()).result.balance) == INITIAL_AMT

    with pytest.raises(StarkException):
        await bad_guy.send_tx(
            gate.contract_address,
            "deposit",
            [trove_1_owner.address, TROVE_1, FIRST_DEPOSIT_AMT],
        )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_unauthorized_withdraw(users, shrine_authed, gate, rebasing_token, gate_deposit):
    """Test user-initiated"""
    trove_1_owner = await users("trove 1 owner")

    # Sanity check
    bal = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    assert bal == INITIAL_AMT - FIRST_DEPOSIT_AMT

    with pytest.raises(StarkException):
        await trove_1_owner.send_tx(
            gate.contract_address,
            "withdraw",
            [trove_1_owner.address, TROVE_1, FIRST_MINT_AMT],
        )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.parametrize("fn", ["deposit", "withdraw"])
@pytest.mark.asyncio
async def test_zero_deposit_withdraw(users, shrine_authed, gate, rebasing_token, gate_deposit, fn):
    abbot = await users("abbot")
    trove_1_owner = await users("trove 1 owner")

    # Get balance before
    before_yang_bal = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    before_asset_bal = from_uint((await rebasing_token.balanceOf(trove_1_owner.address).invoke()).result.balance)

    # Call deposit
    await abbot.send_tx(gate.contract_address, fn, [trove_1_owner.address, TROVE_1, 0])

    # Get balance after
    after_yang_bal = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    after_asset_bal = from_uint((await rebasing_token.balanceOf(trove_1_owner.address).invoke()).result.balance)

    assert before_yang_bal == after_yang_bal
    assert before_asset_bal == after_asset_bal


#
# Tests - Tax
#


@pytest.mark.asyncio
async def test_gate_constructor_invalid_tax(users, shrine, starknet, rebasing_token):
    contract = compile_contract("contracts/gate/rebasing_yang/gate_taxable.cairo")
    abbot = await users("abbot")
    tax_collector = await users("tax collector")

    with pytest.raises(StarkException):
        await starknet.deploy(
            contract_class=contract,
            constructor_calldata=[
                abbot.address,
                shrine.contract_address,
                rebasing_token.contract_address,
                to_ray(TAX_MAX) + 1,
                tax_collector.address,
            ],
        )


@pytest.mark.asyncio
async def test_gate_set_tax_pass(gate_rebasing_tax, users):
    gate = gate_rebasing_tax

    abbot = await users("abbot")

    tx = await abbot.send_tx(gate.contract_address, "set_tax", [TAX_RAY // 2])
    assert_event_emitted(tx, gate.contract_address, "TaxUpdated", [TAX_RAY, TAX_RAY // 2])

    new_tax = (await gate.get_tax().invoke()).result.ray
    assert new_tax == TAX_RAY // 2


@pytest.mark.asyncio
async def test_gate_set_tax_collector(gate_rebasing_tax, users):
    gate = gate_rebasing_tax

    abbot = await users("abbot")
    tax_collector = await users("tax collector")

    new_tax_collector = 9876
    tx = await abbot.send_tx(gate.contract_address, "set_tax_collector", [new_tax_collector])
    assert_event_emitted(
        tx,
        gate.contract_address,
        "TaxCollectorUpdated",
        [tax_collector.address, new_tax_collector],
    )

    res = (await gate.get_tax_collector().invoke()).result.address
    assert res == new_tax_collector


@pytest.mark.asyncio
async def test_gate_set_tax_parameters_fail(gate_rebasing_tax, users):
    gate = gate_rebasing_tax

    abbot = await users("abbot")

    # Fails due to max tax exceeded
    with pytest.raises(StarkException, match="Gate: Maximum tax exceeded"):
        await abbot.send_tx(gate.contract_address, "set_tax", [to_ray(TAX_MAX) + 1])

    bad_guy = await users("bad guy")
    # Fails due to non-authorised address
    with pytest.raises(StarkException, match="Auth: caller not authorized"):
        await bad_guy.send_tx(gate.contract_address, "set_tax", [TAX_RAY])
        await bad_guy.send_tx(gate.contract_address, "set_tax_collector", [bad_guy.address])

    # Fails due to zero address
    with pytest.raises(StarkException, match="Gate: Invalid tax collector address"):
        await abbot.send_tx(gate.contract_address, "set_tax_collector", [ZERO_ADDRESS])


@pytest.mark.parametrize("gate", ["gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_levy(users, shrine_authed, gate, rebasing_token, gate_deposit):
    # `rebase` fixture simulates an autocompounding
    abbot = await users("abbot")
    tax_collector = await users("tax collector")
    trove_1_owner = await users("trove 1 owner")

    # Get balances before levy
    before_tax_collector_bal = from_uint(
        (await rebasing_token.balanceOf(tax_collector.address).invoke()).result.balance
    )
    before_gate_bal = (await gate.get_total_assets().invoke()).result.wad

    # Update Gate's balance and charge tax
    levy = await abbot.send_tx(gate.contract_address, "levy", [])

    # Check Gate's managed assets and balance
    after_gate_bal = (await gate.get_total_assets().invoke()).result.wad
    assert after_gate_bal > before_gate_bal
    assert after_gate_bal == before_gate_bal * COMPOUND_MULTIPLIER - FIRST_TAX_AMT

    # Check that user's withdrawable balance has increased
    user_yang = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    expected_user_assets = (await gate.preview_withdraw(user_yang).invoke()).result.wad
    assert expected_user_assets == after_gate_bal

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    expected_exchange_rate = int(after_gate_bal / from_wad(user_yang))
    assert exchange_rate == expected_exchange_rate

    # Check tax collector has received tax
    after_tax_collector_bal = from_uint((await rebasing_token.balanceOf(tax_collector.address).invoke()).result.balance)
    assert after_tax_collector_bal == before_tax_collector_bal + FIRST_TAX_AMT

    # Check event emitted
    # Event should be emitted if tax is successfully transferred to tax collector.
    assert_event_emitted(
        levy,
        gate.contract_address,
        "TaxLevied",
        [FIRST_TAX_AMT],
    )

    # Check balances before withdraw
    before_user_bal = from_uint((await rebasing_token.balanceOf(trove_1_owner.address).invoke()).result.balance)

    # Withdraw
    await abbot.send_tx(
        gate.contract_address,
        "withdraw",
        [trove_1_owner.address, TROVE_1, user_yang],
    )

    # Get balances after withdraw
    after_user_bal = from_uint((await rebasing_token.balanceOf(trove_1_owner.address).invoke()).result.balance)
    assert after_user_bal == before_user_bal + expected_user_assets
