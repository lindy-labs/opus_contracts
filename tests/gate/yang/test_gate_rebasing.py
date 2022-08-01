from decimal import Decimal

import pytest
from starkware.starknet.testing.objects import StarknetTransactionExecutionInfo
from starkware.starknet.testing.starknet import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.gate.yang.constants import *  # noqa: F403
from tests.shrine.constants import TROVE_1
from tests.utils import (
    FALSE,
    MAX_UINT256,
    TRUE,
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

CUSTOM_ERROR_MARGIN = Decimal("10e18")

#
# Helper functions
#


def get_shares_from_assets(total_shares, total_assets, assets_amt):
    """
    Helper function to calculate the number of shares given a deposit of assets.

    Arguments
    ---------
    total_shares : int
        Total supply of vault shares before deposit in wad.
    total_assets : int
        Total assets held by vault in wad.
    assets_amt : int
        Amount of assets to be deposited in wad.

    Returns
    -------
    Amount of vault shares to be issued in Decimal.
    """
    return from_wad(total_shares) * from_wad(assets_amt) / from_wad(total_assets)


def get_assets_from_shares(total_shares, total_assets, shares_amt):
    """
    Helper function to calculate the number of assets to be deposited to issue the
    given value of shares.

    Arguments
    ---------
    total_shares : int
        Total supply of vault shares before deposit in wad.
    total_assets : int
        Total assets held by vault in wad.
    shares_amt : int
        Amount of shares to be issued in wad.

    Returns
    -------
    Amount of assets to be deposited in Decimal.
    """
    return from_wad(total_assets) * from_wad(shares_amt) / from_wad(total_shares)


#
# Fixtures
#


@pytest.fixture
async def gate_rebasing_tax(starknet_func_scope, users, shrine, rebasing_token) -> StarknetContract:
    """
    Deploys an instance of the Gate module with autocompounding and tax.
    """
    starknet = starknet_func_scope

    contract = compile_contract("contracts/gate/yang/gate_rebasing_tax.cairo")
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

    yield gate


@pytest.fixture
async def gate_rebasing(starknet_func_scope, users, shrine, rebasing_token) -> StarknetContract:
    """
    Deploys an instance of the Gate module, without any autocompounding or tax.
    """
    starknet = starknet_func_scope

    contract = compile_contract("contracts/gate/yang/gate_rebasing.cairo")
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

    yield gate


@pytest.fixture
async def shrine_authed(users, shrine, gate, rebasing_token) -> StarknetContract:
    shrine_owner = await users("shrine owner")

    # Add Gate as authorized
    await shrine_owner.send_tx(shrine.contract_address, "authorize", [gate.contract_address])

    # Add rebasing_token as Yang
    await shrine_owner.send_tx(
        shrine.contract_address,
        "add_yang",
        [rebasing_token.contract_address, to_wad(1000), to_ray(Decimal("0.8")), to_wad(1000)],
    )

    yield shrine


@pytest.fixture
async def gate_deposit(users, shrine_authed, gate, rebasing_token) -> StarknetTransactionExecutionInfo:
    aura_user = await users("aura user")
    abbot = await users("abbot")

    # Approve Gate to transfer tokens from user
    await aura_user.send_tx(rebasing_token.contract_address, "approve", [gate.contract_address, *MAX_UINT256])

    # Call deposit
    deposit = await abbot.send_tx(gate.contract_address, "deposit", [aura_user.address, TROVE_1, FIRST_DEPOSIT_AMT])
    yield deposit


@pytest.fixture
async def rebase(users, gate, rebasing_token, gate_deposit) -> StarknetTransactionExecutionInfo:
    """
    Rebase the gate contract's balance by adding 10%
    """
    aura_user = await users("aura user")

    tx = await aura_user.send_tx(
        rebasing_token.contract_address, "mint", [gate.contract_address, *FIRST_REBASE_AMT_UINT]
    )
    yield tx


@pytest.fixture
def gate(request):
    """
    Wrapper fixture to pass the non-taxable and taxable instances of Gate module
    to `pytest.parametrize`.
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

    aura_user = await users("aura user")

    # Check vault asset balance
    total_bal = from_uint((await rebasing_token.balanceOf(gate.contract_address).invoke()).result.balance)
    total_assets = (await gate.get_total_assets().invoke()).result.wad
    assert total_bal == total_assets == FIRST_DEPOSIT_AMT

    # Check vault shares balance
    total_shares = (await gate.get_total_yang().invoke()).result.wad
    user_shares = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    assert total_shares == user_shares == FIRST_DEPOSIT_AMT

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == to_wad(1)

    # Check event
    assert_event_emitted(
        gate_deposit,
        gate.contract_address,
        "Deposit",
        [aura_user.address, TROVE_1, total_assets, user_shares],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_subsequent_deposit_with_rebase(users, shrine_authed, gate, rebasing_token, rebase):
    abbot = await users("abbot")
    aura_user = await users("aura user")

    # Check expected shares
    before_total_shares = (await gate.get_total_yang().invoke()).result.wad
    before_total_assets = (await gate.get_total_assets().invoke()).result.wad

    expected_shares = get_shares_from_assets(before_total_shares, before_total_assets, SECOND_DEPOSIT_AMT)

    # Get user's shares before subsequent deposit
    before_user_shares = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad

    # Call deposit
    deposit = await abbot.send_tx(
        gate.contract_address,
        "deposit",
        [aura_user.address, TROVE_1, SECOND_DEPOSIT_AMT],
    )

    # Check gate asset balance
    after_total_bal = from_uint((await rebasing_token.balanceOf(gate.contract_address).invoke()).result.balance)
    total_assets = (await gate.get_total_assets().invoke()).result.wad
    expected_bal = INITIAL_AMT + FIRST_REBASE_AMT
    assert after_total_bal == total_assets == expected_bal

    # Check vault shares balance
    after_total_shares = (await gate.get_total_yang().invoke()).result.wad
    assert_equalish(from_wad(after_total_shares), from_wad(before_total_shares) + expected_shares, CUSTOM_ERROR_MARGIN)

    # Check user's shares
    after_user_shares = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    assert_equalish(from_wad(after_user_shares), from_wad(before_user_shares) + expected_shares, CUSTOM_ERROR_MARGIN)

    # Check event emitted
    assert_event_emitted(
        deposit,
        gate.contract_address,
        "Deposit",
        [aura_user.address, TROVE_1, SECOND_DEPOSIT_AMT, to_wad(expected_shares)],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_redeem_before_rebase(users, shrine_authed, gate, rebasing_token, gate_deposit, collect_gas_cost):
    """
    Redeem all shares before rebase.
    """
    # 2 unique key updated for ERC20 transfer (Gate's balance, user's balance)
    # 2 keys updated for Shrine (`shrine_yangs_storage`, `shrine_deposits_storage`)
    #
    # Note that ReentrancyGuard updates 1 key but storage is not charged because value is reset
    # at the end of the transaction.
    collect_gas_cost("gate/redeem", gate_deposit, 4, 2)

    abbot = await users("abbot")
    aura_user = await users("aura user")

    # Redeem
    redeem = await abbot.send_tx(
        gate.contract_address,
        "redeem",
        [aura_user.address, TROVE_1, FIRST_DEPOSIT_AMT],
    )

    # Fetch post-redemption balances
    after_user_balance = (await rebasing_token.balanceOf(aura_user.address).invoke()).result.balance
    after_gate_balance = (await rebasing_token.balanceOf(gate.contract_address).invoke()).result.balance

    assert from_uint(after_user_balance) == INITIAL_AMT
    assert from_uint(after_gate_balance) == 0

    # Fetch post-redemption shares
    after_user_shares = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    total_shares = (await gate.get_total_yang().invoke()).result.wad

    assert after_user_shares == total_shares == 0

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == 0

    # Check event
    assert_event_emitted(
        redeem,
        gate.contract_address,
        "Redeem",
        [aura_user.address, TROVE_1, FIRST_DEPOSIT_AMT, FIRST_DEPOSIT_AMT],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_redeem_after_rebase_pass(users, shrine_authed, gate, rebasing_token, gate_deposit, rebase):
    """
    Redeem all shares after rebase.
    """
    abbot = await users("abbot")
    aura_user = await users("aura user")

    # Redeem
    redeem = await abbot.send_tx(
        gate.contract_address,
        "redeem",
        [aura_user.address, TROVE_1, FIRST_DEPOSIT_AMT],
    )

    # Fetch post-redemption balances
    after_user_balance = (await rebasing_token.balanceOf(aura_user.address).invoke()).result.balance
    after_gate_balance = (await rebasing_token.balanceOf(gate.contract_address).invoke()).result.balance
    expected_user_balance = INITIAL_AMT + FIRST_REBASE_AMT
    assert from_uint(after_user_balance) == expected_user_balance
    assert from_uint(after_gate_balance) == 0

    # Fetch post-redemption shares
    after_user_shares = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    total_shares = (await gate.get_total_yang().invoke()).result.wad

    assert after_user_shares == total_shares == 0

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == 0

    expected_withdrawn_assets = FIRST_DEPOSIT_AMT + FIRST_REBASE_AMT
    # Check event
    assert_event_emitted(
        redeem,
        gate.contract_address,
        "Redeem",
        [aura_user.address, TROVE_1, expected_withdrawn_assets, FIRST_DEPOSIT_AMT],
    )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_kill(users, shrine_authed, gate, rebasing_token, gate_deposit, rebase):
    abbot = await users("abbot")
    aura_user = await users("aura user")

    # Kill
    await abbot.send_tx(gate.contract_address, "kill", [])
    assert (await gate.get_live().invoke()).result.bool == FALSE

    # Assert deposit fails
    with pytest.raises(StarkException, match="Gate: Gate is not live"):
        await abbot.send_tx(
            gate.contract_address,
            "deposit",
            [aura_user.address, TROVE_1, SECOND_DEPOSIT_AMT],
        )

    # Assert redeem succeeds
    redeem_amt = to_wad(5)

    before_user_balance = from_uint((await rebasing_token.balanceOf(aura_user.address).invoke()).result.balance)
    before_gate_balance = from_uint((await rebasing_token.balanceOf(gate.contract_address).invoke()).result.balance)

    before_user_shares = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    before_gate_shares = (await gate.get_total_yang().invoke()).result.wad

    expected_assets = get_assets_from_shares(before_gate_shares, before_gate_balance, redeem_amt)

    await abbot.send_tx(gate.contract_address, "redeem", [aura_user.address, TROVE_1, redeem_amt])

    after_user_balance = from_uint((await rebasing_token.balanceOf(aura_user.address).invoke()).result.balance)
    after_gate_balance = from_uint((await rebasing_token.balanceOf(gate.contract_address).invoke()).result.balance)

    after_user_shares = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    after_gate_shares = (await gate.get_total_yang().invoke()).result.wad

    assert_equalish(from_wad(after_user_balance), from_wad(before_user_balance) + expected_assets, CUSTOM_ERROR_MARGIN)
    assert_equalish(from_wad(after_gate_balance), from_wad(before_gate_balance) - expected_assets, CUSTOM_ERROR_MARGIN)

    assert after_user_shares == before_user_shares - redeem_amt
    assert after_gate_shares == before_gate_shares - redeem_amt


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_deposit_insufficient_fail(users, shrine_authed, gate, rebasing_token):
    aura_user = await users("aura user")
    abbot = await users("abbot")

    # Approve Gate to transfer tokens from user
    await aura_user.send_tx(rebasing_token.contract_address, "approve", [gate.contract_address, *MAX_UINT256])

    # Call deposit with more asset than user has
    with pytest.raises(StarkException, match="Gate: Transfer of asset failed"):
        await abbot.send_tx(gate.contract_address, "deposit", [aura_user.address, TROVE_1, INITIAL_AMT + 1])


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_redeem_insufficient_fail(users, shrine_authed, gate, rebasing_token, gate_deposit):
    aura_user = await users("aura user")
    abbot = await users("abbot")

    # Call redeem with more gate shares than user has
    with pytest.raises(StarkException, match="Shrine: Insufficient yang"):
        await abbot.send_tx(
            gate.contract_address,
            "redeem",
            [aura_user.address, TROVE_1, FIRST_DEPOSIT_AMT + 1],
        )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_unauthorized_deposit(users, rebasing_token, gate):
    """Test third-party initiated"""
    aura_user = await users("aura user")
    bad_guy = await users("bad guy")

    # Seed unauthorized address with asset
    await bad_guy.send_tx(rebasing_token.contract_address, "mint", [bad_guy.address, *INITIAL_AMT_UINT])
    # Sanity check
    assert from_uint((await rebasing_token.balanceOf(bad_guy.address).invoke()).result.balance) == INITIAL_AMT

    with pytest.raises(StarkException):
        await bad_guy.send_tx(
            gate.contract_address,
            "deposit",
            [aura_user.address, TROVE_1, FIRST_DEPOSIT_AMT],
        )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_unauthorized_redeem(users, shrine_authed, gate, rebasing_token, gate_deposit):
    """Test user-initiated"""
    aura_user = await users("aura user")

    # Sanity check
    bal = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    assert bal == INITIAL_AMT - FIRST_DEPOSIT_AMT

    with pytest.raises(StarkException):
        await aura_user.send_tx(
            gate.contract_address,
            "redeem",
            [aura_user.address, TROVE_1, FIRST_MINT_AMT],
        )


@pytest.mark.parametrize("gate", ["gate_rebasing", "gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.parametrize("fn", ["deposit", "redeem"])
@pytest.mark.asyncio
async def test_zero_deposit_redeem(users, shrine_authed, gate, rebasing_token, gate_deposit, fn):
    abbot = await users("abbot")
    aura_user = await users("aura user")

    # Get balance before
    before_yang_bal = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    before_asset_bal = from_uint((await rebasing_token.balanceOf(aura_user.address).invoke()).result.balance)

    # Call deposit
    await abbot.send_tx(gate.contract_address, fn, [aura_user.address, TROVE_1, 0])

    # Get balance after
    after_yang_bal = (await shrine_authed.get_deposit(TROVE_1, rebasing_token.contract_address).invoke()).result.wad
    after_asset_bal = from_uint((await rebasing_token.balanceOf(aura_user.address).invoke()).result.balance)

    assert before_yang_bal == after_yang_bal
    assert before_asset_bal == after_asset_bal


#
# Tests - Tax
#


@pytest.mark.asyncio
async def test_gate_constructor_invalid_tax(users, shrine, starknet, rebasing_token):
    contract = compile_contract("contracts/gate/yang/gate_rebasing_tax.cairo")
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
    ZERO_ADDRESS = 0
    with pytest.raises(StarkException, match="Gate: Invalid tax collector address"):
        await abbot.send_tx(gate.contract_address, "set_tax_collector", [ZERO_ADDRESS])


"""
@pytest.mark.parametrize("gate", ["gate_rebasing_tax"], indirect=["gate"])
@pytest.mark.asyncio
async def test_gate_levy(users, shrine_authed, gate, asset, rebase, collect_gas_cost):
    # `rebase` fixture simulates an autocompounding
    abbot = await users("abbot")
    tax_collector = await users("tax collector")

    # Get balances before levy
    before_tax_collector_bal = from_uint((await asset.balanceOf(tax_collector.address).invoke()).result.balance)
    rebased_bal = from_uint((await asset.balanceOf(gate.contract_address).invoke()).result.balance)

    # Check gage token contract for rebased balance
    assert rebased_bal == FIRST_DEPOSIT_AMT + FIRST_REBASE_AMT

    # Update Gate's balance and charge tax
    levy = await abbot.send_tx(gate.contract_address, "levy", [])

    # 2 unique keys updated for ERC20 transfer of tax (Gate's balance, tax collector's balance)
    # 1 key updated for Gate (`gate_last_asset_balance_storage`)
    collect_gas_cost("gate/levy", levy, 3, 2)

    # Check Gate's managed assets and balance
    after_gate_bal = (await gate.get_total_assets().invoke()).result.wad
    assert after_gate_bal == rebased_bal - FIRST_TAX_AMT

    # Check that user's redeemable balance has increased
    user_shares = (await shrine_authed.get_deposit(TROVE_1, asset.contract_address).invoke()).result.wad
    user_asset = (await gate.preview_redeem(user_shares).invoke()).result.wad
    assert user_asset == after_gate_bal

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    user_shares = from_wad(user_shares)
    expected_exchange_rate = int(after_gate_bal / Decimal(user_shares))
    assert exchange_rate == expected_exchange_rate

    # Check event emitted
    assert_event_emitted(
        levy,
        gate.contract_address,
        "TaxLevied",
        [FIRST_TAX_AMT],
    )

    # Check tax collector has received tax
    after_tax_collector_bal = from_uint((await asset.balanceOf(tax_collector.address).invoke()).result.balance)
    assert after_tax_collector_bal == before_tax_collector_bal + FIRST_TAX_AMT

    # Ensure that second levy has no effect
    levy = await abbot.send_tx(gate.contract_address, "levy", [])
    redundant_gate_bal = (await gate.get_assets().invoke()).result.wad
    assert redundant_gate_bal == after_gate_balance
"""
