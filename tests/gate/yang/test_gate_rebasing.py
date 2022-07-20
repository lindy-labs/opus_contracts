from decimal import Decimal

import pytest
from starkware.starknet.testing.objects import StarknetTransactionExecutionInfo
from starkware.starknet.testing.starknet import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.gate.yang.constants import *  # noqa: F403
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
# Helper functions
#

TROVE_1 = 1


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

# Convenience fixture
@pytest.fixture
def gate(gate_rebasing) -> StarknetContract:
    _, gate = gate_rebasing
    yield gate


@pytest.fixture
def asset(gate_rebasing) -> StarknetContract:
    asset, _ = gate_rebasing
    yield asset


@pytest.fixture
async def shrine_authed(shrine, gate, asset, users) -> StarknetContract:
    shrine_owner = await users("shrine owner")

    # Add Gate as authorized
    await shrine_owner.send_tx(shrine.contract_address, "authorize", [gate.contract_address])

    # Add asset as Yang
    await shrine_owner.send_tx(
        shrine.contract_address,
        "add_yang",
        [asset.contract_address, to_wad(1000), to_ray(Decimal("0.8")), to_wad(1000)],
    )

    yield shrine


@pytest.fixture
async def gate_deposit(users, shrine_authed, gate, asset) -> StarknetTransactionExecutionInfo:
    shrine_user = await users("shrine user")
    abbot = await users("abbot")

    # Approve Gate to transfer tokens from user
    await shrine_user.send_tx(asset.contract_address, "approve", [gate.contract_address, *MAX_UINT256])

    # Call deposit
    deposit = await abbot.send_tx(gate.contract_address, "deposit", [FIRST_DEPOSIT_AMT, shrine_user.address, 1])
    return deposit


@pytest.fixture
async def rebase(users, gate, asset, gate_deposit) -> StarknetTransactionExecutionInfo:
    """
    Rebase the gate contract's balance by adding 10%
    """
    shrine_user = await users("shrine user")

    tx = await shrine_user.send_tx(
        asset.contract_address,
        "mint",
        [gate.contract_address, *FIRST_REBASE_AMT_UINT],
    )
    return tx


@pytest.fixture
async def sync(users, gate, asset, rebase) -> StarknetTransactionExecutionInfo:
    abbot = await users("abbot")
    # Update Gate's balance and charge tax
    sync = await abbot.send_tx(gate.contract_address, "sync", [])
    return sync


#
# Tests
#


@pytest.mark.asyncio
async def test_gate_setup(gate, asset, users):
    # Check system is live
    live = (await gate.get_live().invoke()).result.bool
    assert live == TRUE

    # Check asset address
    assert (await gate.get_asset().invoke()).result.address == asset.contract_address

    # Check total assets
    asset_bal = from_uint((await gate.get_total_assets().invoke()).result.uint)
    assert asset_bal == 0

    # Check Abbot address is authorized
    abbot = await users("abbot")
    authorized = (await gate.get_auth(abbot.address).invoke()).result.bool
    assert authorized == TRUE

    # Check tax
    tax = (await gate.get_tax().invoke()).result.ray
    assert tax == TAX_RAY

    # Check tax collector
    tax_collector = await users("tax collector")
    tax_collector_address = (await gate.get_tax_collector_address().invoke()).result.address
    assert tax_collector_address == tax_collector.address

    # Check initial values
    assert (await gate.get_total_yang().invoke()).result.wad == 0

    # Check initial exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == 0


@pytest.mark.asyncio
async def test_gate_constructor_invalid_tax(users, shrine, starknet, asset):
    contract = compile_contract("contracts/gate/yang/gate_rebasing.cairo")
    abbot = await users("abbot")
    tax_collector = await users("tax collector")

    with pytest.raises(StarkException, match="Gate: Maximum tax exceeded"):
        await starknet.deploy(
            contract_class=contract,
            constructor_calldata=[
                abbot.address,
                shrine.contract_address,
                asset.contract_address,
                to_ray(TAX_MAX) + 1,
                tax_collector.address,
            ],
        )


@pytest.mark.asyncio
async def test_gate_set_tax_pass(gate, users):
    abbot = await users("abbot")

    tx = await abbot.send_tx(gate.contract_address, "set_tax", [TAX_RAY // 2])
    assert_event_emitted(tx, gate.contract_address, "TaxUpdated", [TAX_RAY, TAX_RAY // 2])

    new_tax = (await gate.get_tax().invoke()).result.ray
    assert new_tax == TAX_RAY // 2


@pytest.mark.asyncio
async def test_gate_set_tax_fail(gate, users):
    abbot = await users("abbot")

    # Fails due to max tax exceeded
    with pytest.raises(StarkException, match="Gate: Maximum tax exceeded"):
        await abbot.send_tx(gate.contract_address, "set_tax", [to_ray(TAX_MAX) + 1])


@pytest.mark.asyncio
async def test_gate_set_tax_collector(gate, users):
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

    res = (await gate.get_tax_collector_address().invoke()).result.address
    assert res == new_tax_collector


#
# Tests - ERC4626
#


@pytest.mark.asyncio
async def test_gate_deposit_pass(users, shrine_authed, gate, asset, gate_deposit):
    shrine_user = await users("shrine user")

    # Check vault asset balance
    total_bal = from_uint((await asset.balanceOf(gate.contract_address).invoke()).result.balance)
    total_assets = from_uint((await gate.get_total_assets().invoke()).result.uint)
    assert total_bal == total_assets == FIRST_DEPOSIT_AMT

    asset_bal = (await gate.get_last_asset_balance().invoke()).result.wad
    assert asset_bal == total_bal

    # Check vault shares balance
    total_shares = (await gate.get_total_yang().invoke()).result.wad
    user_shares = (await shrine_authed.get_deposit(TROVE_1, asset.contract_address).invoke()).result.wad
    assert total_shares == user_shares == FIRST_DEPOSIT_AMT

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == to_wad(1)

    # Check event
    assert_event_emitted(
        gate_deposit,
        gate.contract_address,
        "Deposit",
        [shrine_user.address, TROVE_1, total_assets, user_shares],
    )


@pytest.mark.asyncio
async def test_gate_sync(users, shrine_authed, gate, asset, rebase):
    abbot = await users("abbot")
    tax_collector = await users("tax collector")

    # Get balances before sync
    before_tax_collector_bal = from_uint((await asset.balanceOf(tax_collector.address).invoke()).result.balance)
    rebased_bal = from_uint((await asset.balanceOf(gate.contract_address).invoke()).result.balance)

    # Check gage token contract for rebased balance
    assert rebased_bal == FIRST_DEPOSIT_AMT + FIRST_REBASE_AMT

    # Fetch last asset balance
    before_asset_bal = (await gate.get_last_asset_balance().invoke()).result.wad

    # Update Gate's balance and charge tax
    sync = await abbot.send_tx(gate.contract_address, "sync", [])

    # Check Gate's managed assets and balance
    after_gate_bal = from_uint((await gate.get_total_assets().invoke()).result.uint)
    after_asset_bal = (await gate.get_last_asset_balance().invoke()).result.wad

    increment = FIRST_REBASE_AMT - FIRST_TAX_AMT

    assert after_gate_bal == after_asset_bal == rebased_bal - FIRST_TAX_AMT == before_asset_bal + increment

    # Check that user's redeemable balance has increased
    user_shares = (await shrine_authed.get_deposit(TROVE_1, asset.contract_address).invoke()).result.wad
    user_asset = from_uint((await gate.preview_redeem(user_shares).invoke()).result.wad)
    assert user_asset == after_gate_bal

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    user_shares = from_wad(user_shares)
    expected_exchange_rate = int(after_gate_bal / Decimal(user_shares))
    assert exchange_rate == expected_exchange_rate

    # Check event emitted
    assert_event_emitted(
        sync,
        gate.contract_address,
        "Sync",
        [before_asset_bal, after_asset_bal, FIRST_TAX_AMT],
    )

    # Check tax collector has received tax
    after_tax_collector_bal = from_uint((await asset.balanceOf(tax_collector.address).invoke()).result.balance)
    assert after_tax_collector_bal == before_tax_collector_bal + FIRST_TAX_AMT


@pytest.mark.asyncio
async def test_gate_subsequent_deposit(users, shrine_authed, gate, asset, sync):
    abbot = await users("abbot")
    shrine_user = await users("shrine user")

    # Check expected shares
    before_total_shares = (await gate.get_total_yang().invoke()).result.wad
    before_total_assets = from_uint((await gate.get_total_assets().invoke()).result.uint)
    preview_shares = (await gate.preview_deposit(SECOND_DEPOSIT_AMT).invoke()).result.wad
    expected_shares = get_shares_from_assets(before_total_shares, before_total_assets, SECOND_DEPOSIT_AMT)
    assert_equalish(from_wad(preview_shares), expected_shares)

    # Get user's shares before subsequent deposit
    before_user_shares = (await shrine_authed.get_deposit(TROVE_1, asset.contract_address).invoke()).result.wad

    # Call deposit
    deposit = await abbot.send_tx(
        gate.contract_address,
        "deposit",
        [SECOND_DEPOSIT_AMT, shrine_user.address, TROVE_1],
    )

    # Check gate asset balance
    after_total_bal = from_uint((await asset.balanceOf(gate.contract_address).invoke()).result.balance)
    total_assets = from_uint((await gate.get_total_assets().invoke()).result.uint)
    expected_bal = INITIAL_AMT + FIRST_REBASE_AMT - FIRST_TAX_AMT
    assert after_total_bal == total_assets == expected_bal

    asset_bal = (await gate.get_last_asset_balance().invoke()).result.wad
    assert asset_bal == after_total_bal

    # Check vault shares balance
    after_total_shares = (await gate.get_total_yang().invoke()).result.wad
    assert_equalish(from_wad(after_total_shares), from_wad(before_total_shares) + expected_shares)

    # Check user's shares
    after_user_shares = (await shrine_authed.get_deposit(TROVE_1, asset.contract_address).invoke()).result.wad
    assert_equalish(from_wad(after_user_shares), from_wad(before_user_shares) + expected_shares)

    # Check event emitted
    assert_event_emitted(
        deposit,
        gate.contract_address,
        "Deposit",
        [
            shrine_user.address,
            TROVE_1,
            SECOND_DEPOSIT_AMT,
            preview_shares,
        ],
    )


@pytest.mark.asyncio
async def test_gate_redeem_before_sync_pass(users, shrine_authed, gate, asset, gate_deposit):
    """
    Redeem all shares before sync.
    """
    abbot = await users("abbot")
    shrine_user = await users("shrine user")

    # Redeem
    await abbot.send_tx(
        gate.contract_address,
        "redeem",
        [FIRST_DEPOSIT_AMT, shrine_user.address, TROVE_1],
    )

    # Fetch post-redemption balances
    after_user_balance = (await asset.balanceOf(shrine_user.address).invoke()).result.balance
    after_gate_balance = (await asset.balanceOf(gate.contract_address).invoke()).result.balance

    assert from_uint(after_user_balance) == INITIAL_AMT
    assert from_uint(after_gate_balance) == 0

    # Fetch post-redemption shares
    after_user_shares = (await shrine_authed.get_deposit(TROVE_1, asset.contract_address).invoke()).result.wad
    total_shares = (await gate.get_total_yang().invoke()).result.wad

    assert after_user_shares == total_shares == 0

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == 0


@pytest.mark.asyncio
async def test_gate_redeem_after_sync_pass(users, shrine_authed, gate, asset, gate_deposit, sync):
    """
    Redeem all shares after sync.
    """
    abbot = await users("abbot")
    shrine_user = await users("shrine user")

    # Redeem
    await abbot.send_tx(
        gate.contract_address,
        "redeem",
        [FIRST_DEPOSIT_AMT, shrine_user.address, TROVE_1],
    )

    # Fetch post-redemption balances
    after_user_balance = (await asset.balanceOf(shrine_user.address).invoke()).result.balance
    after_gate_balance = (await asset.balanceOf(gate.contract_address).invoke()).result.balance

    assert from_uint(after_user_balance) == INITIAL_AMT + FIRST_REBASE_AMT - FIRST_TAX_AMT
    assert from_uint(after_gate_balance) == 0

    # Fetch post-redemption shares
    after_user_shares = (await shrine_authed.get_deposit(TROVE_1, asset.contract_address).invoke()).result.wad
    total_shares = (await gate.get_total_yang().invoke()).result.wad

    assert after_user_shares == total_shares == 0

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == 0


@pytest.mark.asyncio
async def test_kill(users, shrine_authed, gate, asset, gate_deposit, sync):
    abbot = await users("abbot")
    shrine_user = await users("shrine user")

    # Kill
    await abbot.send_tx(gate.contract_address, "kill", [])
    assert (await gate.get_live().invoke()).result.bool == FALSE

    # Assert deposit fails
    with pytest.raises(StarkException, match="Gate: Gate is not live"):
        await abbot.send_tx(
            gate.contract_address,
            "deposit",
            [SECOND_DEPOSIT_AMT, shrine_user.address, TROVE_1],
        )

    # Assert redeem succeeds
    redeem_amt = to_wad(5)

    before_user_balance = from_uint((await asset.balanceOf(shrine_user.address).invoke()).result.balance)
    before_gate_balance = from_uint((await asset.balanceOf(gate.contract_address).invoke()).result.balance)

    before_user_shares = (await shrine_authed.get_deposit(TROVE_1, asset.contract_address).invoke()).result.wad
    before_gate_shares = (await gate.get_total_yang().invoke()).result.wad

    expected_assets = get_assets_from_shares(before_gate_shares, before_gate_balance, redeem_amt)

    await abbot.send_tx(
        gate.contract_address,
        "redeem",
        [redeem_amt, shrine_user.address, TROVE_1],
    )

    after_user_balance = from_uint((await asset.balanceOf(shrine_user.address).invoke()).result.balance)
    after_gate_balance = from_uint((await asset.balanceOf(gate.contract_address).invoke()).result.balance)

    after_user_shares = (await shrine_authed.get_deposit(TROVE_1, asset.contract_address).invoke()).result.wad
    after_gate_shares = (await gate.get_total_yang().invoke()).result.wad

    assert_equalish(from_wad(after_user_balance), from_wad(before_user_balance) + expected_assets)
    assert_equalish(from_wad(after_gate_balance), from_wad(before_gate_balance) - expected_assets)

    assert after_user_shares == before_user_shares - redeem_amt
    assert after_gate_shares == before_gate_shares - redeem_amt


@pytest.mark.asyncio
async def test_unauthorized_deposit(users, asset, gate):
    """Test third-party initiated"""
    shrine_user = await users("shrine user")
    bad_guy = await users("bad guy")

    # Seed unauthorized address with asset
    await bad_guy.send_tx(asset.contract_address, "mint", [bad_guy.address, *INITIAL_AMT_UINT])
    # Sanity check
    assert from_uint((await asset.balanceOf(bad_guy.address).invoke()).result.balance) == INITIAL_AMT

    with pytest.raises(StarkException):
        await bad_guy.send_tx(
            gate.contract_address,
            "deposit",
            [FIRST_DEPOSIT_AMT, shrine_user.address, TROVE_1],
        )


@pytest.mark.asyncio
async def test_unauthorized_redeem(users, shrine_authed, gate, asset, gate_deposit):
    """Test user-initiated"""
    shrine_user = await users("shrine user")

    # Sanity check
    bal = (await shrine_authed.get_deposit(TROVE_1, asset.contract_address).invoke()).result.wad
    assert bal == INITIAL_AMT - FIRST_DEPOSIT_AMT

    with pytest.raises(StarkException):
        await shrine_user.send_tx(
            gate.contract_address,
            "redeem",
            [FIRST_MINT_AMT, shrine_user.address, TROVE_1],
        )
