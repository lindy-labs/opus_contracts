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
    str_to_felt,
    to_ray,
    to_wad,
)

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

# Convenience fixture
@pytest.fixture
def gate(gate_rebasing) -> StarknetContract:
    _, gate = gate_rebasing
    yield gate


@pytest.fixture
def underlying(gate_rebasing) -> StarknetContract:
    underlying, _ = gate_rebasing
    yield underlying


@pytest.fixture
async def gate_deposit(users, gate, underlying) -> StarknetTransactionExecutionInfo:
    shrine_user = await users("shrine user")
    abbot = await users("abbot")

    # Approve Gate to transfer tokens from user
    await shrine_user.send_tx(underlying.contract_address, "approve", [gate.contract_address, *MAX_UINT256])

    # Call deposit
    deposit = await abbot.send_tx(gate.contract_address, "deposit", [*FIRST_DEPOSIT_AMT_UINT, shrine_user.address])
    return deposit


@pytest.fixture
async def gate_mint(users, gate, underlying) -> StarknetTransactionExecutionInfo:
    shrine_user = await users("shrine user")
    abbot = await users("abbot")

    # Approve Gate to transfer tokens from user
    await shrine_user.send_tx(underlying.contract_address, "approve", [gate.contract_address, *MAX_UINT256])

    # Call deposit
    mint = await abbot.send_tx(gate.contract_address, "deposit", [*FIRST_MINT_AMT_UINT, shrine_user.address])
    return mint


@pytest.fixture
async def rebase(users, gate, underlying, gate_deposit) -> StarknetTransactionExecutionInfo:
    """
    Rebase the gate contract's balance by adding 10%
    """
    shrine_user = await users("shrine user")

    tx = await shrine_user.send_tx(
        underlying.contract_address,
        "mint",
        [gate.contract_address, *FIRST_REBASE_AMT_UINT],
    )
    return tx


@pytest.fixture
async def sync(users, gate, underlying, rebase) -> StarknetTransactionExecutionInfo:
    abbot = await users("abbot")
    # Update Gate's balance and charge tax
    sync = await abbot.send_tx(gate.contract_address, "sync", [])
    return sync


@pytest.fixture
async def gate_subsequent_deposit(users, gate, underlying, sync):
    shrine_user = await users("shrine user")
    abbot = await users("abbot")

    # Approve Gate to transfer tokens from user
    await shrine_user.send_tx(underlying.contract_address, "approve", [gate.contract_address, *MAX_UINT256])

    # Call deposit
    deposit = await abbot.send_tx(
        gate.contract_address,
        "deposit",
        [*SECOND_DEPOSIT_AMT_UINT, shrine_user.address],
    )
    return deposit


@pytest.fixture
async def gate_subsequent_mint(users, gate, underlying, sync):
    shrine_user = await users("shrine user")
    abbot = await users("abbot")

    # Approve Gate to transfer tokens from user
    await shrine_user.send_tx(underlying.contract_address, "approve", [gate.contract_address, *MAX_UINT256])

    # Call deposit
    mint = await abbot.send_tx(gate.contract_address, "mint", [*SECOND_MINT_AMT_UINT, shrine_user.address])
    return mint


#
# Tests
#


@pytest.mark.asyncio
async def test_gate_setup(gate, underlying, users):
    # Check system is live
    live = (await gate.get_live().invoke()).result.bool
    assert live == TRUE

    # Check asset address
    asset = (await gate.asset().invoke()).result.address
    assert asset == underlying.contract_address

    # Check total assets
    asset_bal = from_uint((await gate.totalAssets().invoke()).result.uint)
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
    assert from_uint((await gate.totalSupply().invoke()).result.uint) == 0

    # Check initial exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == 0


@pytest.mark.asyncio
async def test_gate_constructor_invalid_tax(users, starknet, underlying):
    contract = compile_contract("contracts/gate/yang/gate_rebasing.cairo")
    abbot = await users("abbot")
    tax_collector = await users("tax collector")

    with pytest.raises(StarkException, match="Gate: Maximum tax exceeded"):
        await starknet.deploy(
            contract_class=contract,
            constructor_calldata=[
                abbot.address,
                str_to_felt("Aura Staked ETH"),
                str_to_felt("auStETH"),
                underlying.contract_address,
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
async def test_gate_deposit_pass(users, gate, underlying, gate_deposit):
    abbot = await users("abbot")
    shrine_user = await users("shrine user")

    # Check vault underlying balance
    total_bal = from_uint((await underlying.balanceOf(gate.contract_address).invoke()).result.balance)
    total_assets = (await gate.totalAssets().invoke()).result.uint
    assert total_bal == from_uint(total_assets) == FIRST_DEPOSIT_AMT

    underlying_bal = (await gate.get_last_underlying_balance().invoke()).result.wad
    assert underlying_bal == total_bal

    # Check vault shares balance
    total_shares = from_uint((await gate.totalSupply().invoke()).result.uint)
    user_shares = (await gate.balanceOf(shrine_user.address).invoke()).result.uint
    assert total_shares == from_uint(user_shares) == FIRST_DEPOSIT_AMT

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == to_wad(1)

    # Check event
    assert_event_emitted(
        gate_deposit,
        gate.contract_address,
        "Deposit",
        [abbot.address, shrine_user.address, *total_assets, *user_shares],
    )


@pytest.mark.asyncio
async def test_gate_mint(users, gate, underlying, gate_mint):
    abbot = await users("abbot")
    shrine_user = await users("shrine user")

    # Check vault underlying balance
    total_bal = from_uint((await underlying.balanceOf(gate.contract_address).invoke()).result.balance)
    total_assets = (await gate.totalAssets().invoke()).result.uint
    assert total_bal == from_uint(total_assets) == FIRST_DEPOSIT_AMT

    underlying_bal = (await gate.get_last_underlying_balance().invoke()).result.wad
    assert underlying_bal == total_bal

    # Check vault shares balance
    total_shares = from_uint((await gate.totalSupply().invoke()).result.uint)
    user_shares = (await gate.balanceOf(shrine_user.address).invoke()).result.uint
    assert total_shares == from_uint(user_shares) == FIRST_DEPOSIT_AMT

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == to_wad(1)

    # Check event
    assert_event_emitted(
        gate_mint,
        gate.contract_address,
        "Deposit",
        [abbot.address, shrine_user.address, *total_assets, *user_shares],
    )


@pytest.mark.asyncio
async def test_gate_sync(users, gate, underlying, rebase):
    abbot = await users("abbot")
    tax_collector = await users("tax collector")
    shrine_user = await users("shrine user")

    # Get balances before sync
    before_tax_collector_bal = from_uint((await underlying.balanceOf(tax_collector.address).invoke()).result.balance)
    rebased_bal = from_uint((await underlying.balanceOf(gate.contract_address).invoke()).result.balance)

    # Check gage token contract for rebased balance
    assert rebased_bal == FIRST_DEPOSIT_AMT + FIRST_REBASE_AMT

    # Fetch last underlying balance
    before_underlying_bal = (await gate.get_last_underlying_balance().invoke()).result.wad

    # Update Gate's balance and charge tax
    sync = await abbot.send_tx(gate.contract_address, "sync", [])

    # Check Gate's managed assets and balance
    after_gate_bal = from_uint((await gate.totalAssets().invoke()).result.uint)
    after_underlying_bal = (await gate.get_last_underlying_balance().invoke()).result.wad

    increment = FIRST_REBASE_AMT - FIRST_TAX_AMT

    assert after_gate_bal == after_underlying_bal == rebased_bal - FIRST_TAX_AMT == before_underlying_bal + increment

    # Check that user's redeemable balance has increased
    user_shares_uint = (await gate.balanceOf(shrine_user.address).invoke()).result.uint
    user_underlying = from_uint((await gate.previewRedeem(user_shares_uint).invoke()).result.uint)
    assert user_underlying == after_gate_bal

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    user_shares = from_wad(from_uint(user_shares_uint))
    expected_exchange_rate = int(after_gate_bal / Decimal(user_shares))
    assert exchange_rate == expected_exchange_rate

    # Check event emitted
    assert_event_emitted(
        sync,
        gate.contract_address,
        "Sync",
        [before_underlying_bal, after_underlying_bal, FIRST_TAX_AMT],
    )

    # Check tax collector has received tax
    after_tax_collector_bal = from_uint((await underlying.balanceOf(tax_collector.address).invoke()).result.balance)
    assert after_tax_collector_bal == before_tax_collector_bal + FIRST_TAX_AMT


@pytest.mark.asyncio
async def test_gate_subsequent_deposit(users, gate, underlying, sync):
    abbot = await users("abbot")
    shrine_user = await users("shrine user")

    # Check expected shares
    before_total_shares = from_uint((await gate.totalSupply().invoke()).result.uint)
    before_total_assets = from_uint((await gate.totalAssets().invoke()).result.uint)
    preview_shares_uint = (await gate.previewDeposit(SECOND_DEPOSIT_AMT_UINT).invoke()).result.uint
    preview_shares = from_uint(preview_shares_uint)
    expected_shares = get_shares_from_assets(before_total_shares, before_total_assets, SECOND_DEPOSIT_AMT)
    assert_equalish(from_wad(preview_shares), expected_shares)

    # Get user's shares before subsequent deposit
    before_user_shares = from_uint((await gate.balanceOf(shrine_user.address).invoke()).result.uint)

    # Call deposit
    deposit = await abbot.send_tx(
        gate.contract_address,
        "deposit",
        [*SECOND_DEPOSIT_AMT_UINT, shrine_user.address],
    )

    # Check vault underlying balance
    after_total_bal = from_uint((await underlying.balanceOf(gate.contract_address).invoke()).result.balance)
    total_assets = from_uint((await gate.totalAssets().invoke()).result.uint)
    expected_bal = INITIAL_AMT + FIRST_REBASE_AMT - FIRST_TAX_AMT
    assert after_total_bal == total_assets == expected_bal

    underlying_bal = (await gate.get_last_underlying_balance().invoke()).result.wad
    assert underlying_bal == after_total_bal

    # Check vault shares balance
    after_total_shares = from_uint((await gate.totalSupply().invoke()).result.uint)
    assert_equalish(from_wad(after_total_shares), from_wad(before_total_shares) + expected_shares)

    # Check user's shares
    after_user_shares = from_uint((await gate.balanceOf(shrine_user.address).invoke()).result.uint)
    assert_equalish(from_wad(after_user_shares), from_wad(before_user_shares) + expected_shares)

    # Check event emitted
    assert_event_emitted(
        deposit,
        gate.contract_address,
        "Deposit",
        [
            abbot.address,
            shrine_user.address,
            *SECOND_DEPOSIT_AMT_UINT,
            *preview_shares_uint,
        ],
    )


@pytest.mark.asyncio
async def test_gate_subsequent_mint(users, gate, underlying, sync):
    abbot = await users("abbot")
    shrine_user = await users("shrine user")

    # Check expected shares
    before_total_shares = from_uint((await gate.totalSupply().invoke()).result.uint)
    before_total_assets = from_uint((await gate.totalAssets().invoke()).result.uint)
    preview_assets_uint = (await gate.previewMint(SECOND_MINT_AMT_UINT).invoke()).result.uint
    preview_assets = from_uint(preview_assets_uint)
    expected_assets = get_assets_from_shares(before_total_shares, before_total_assets, SECOND_MINT_AMT)
    assert_equalish(from_wad(preview_assets), expected_assets)

    # Get user's shares before subsequent deposit
    before_user_shares = from_uint((await gate.balanceOf(shrine_user.address).invoke()).result.uint)

    # Call mint
    mint = await abbot.send_tx(gate.contract_address, "mint", [*SECOND_MINT_AMT_UINT, shrine_user.address])

    # Check vault underlying balance
    after_total_bal = from_uint((await underlying.balanceOf(gate.contract_address).invoke()).result.balance)
    total_assets = from_uint((await gate.totalAssets().invoke()).result.uint)
    assert after_total_bal == total_assets
    expected_bal = from_wad(before_total_assets) + expected_assets
    assert_equalish(from_wad(after_total_bal), expected_bal)

    underlying_bal = (await gate.get_last_underlying_balance().invoke()).result.wad
    assert underlying_bal == after_total_bal

    # Check vault shares balance and user's shares balance
    after_total_shares = from_uint((await gate.totalSupply().invoke()).result.uint)
    after_user_shares = from_uint((await gate.balanceOf(shrine_user.address).invoke()).result.uint)
    assert after_total_shares == before_total_shares + SECOND_MINT_AMT
    assert after_user_shares == before_user_shares + SECOND_MINT_AMT

    # Check event emitted
    assert_event_emitted(
        mint,
        gate.contract_address,
        "Deposit",
        [
            abbot.address,
            shrine_user.address,
            *preview_assets_uint,
            *SECOND_MINT_AMT_UINT,
        ],
    )


@pytest.mark.asyncio
async def test_gate_redeem_before_sync_pass(users, gate, underlying, gate_deposit):
    """
    Redeem all shares before sync.
    """
    abbot = await users("abbot")
    shrine_user = await users("shrine user")

    # Redeem
    await abbot.send_tx(
        gate.contract_address,
        "redeem",
        [*FIRST_DEPOSIT_AMT_UINT, shrine_user.address, shrine_user.address],
    )

    # Fetch post-withdrawal balances
    after_user_balance = (await underlying.balanceOf(shrine_user.address).invoke()).result.balance
    after_gate_balance = (await underlying.balanceOf(gate.contract_address).invoke()).result.balance

    assert from_uint(after_user_balance) == INITIAL_AMT
    assert from_uint(after_gate_balance) == 0

    # Fetch post-withdrawal shares
    after_user_shares = (await gate.balanceOf(shrine_user.address).invoke()).result.uint
    total_shares = (await gate.totalSupply().invoke()).result.uint

    assert from_uint(after_user_shares) == 0
    assert from_uint(total_shares) == 0

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == 0


@pytest.mark.asyncio
async def test_gate_redeem_after_sync_pass(users, gate, underlying, gate_deposit, sync):
    """
    Redeem all shares after sync.
    """
    abbot = await users("abbot")
    shrine_user = await users("shrine user")

    # Redeem
    await abbot.send_tx(
        gate.contract_address,
        "redeem",
        [*FIRST_DEPOSIT_AMT_UINT, shrine_user.address, shrine_user.address],
    )

    # Fetch post-withdrawal balances
    after_user_balance = (await underlying.balanceOf(shrine_user.address).invoke()).result.balance
    after_gate_balance = (await underlying.balanceOf(gate.contract_address).invoke()).result.balance

    assert from_uint(after_user_balance) == INITIAL_AMT + FIRST_REBASE_AMT - FIRST_TAX_AMT
    assert from_uint(after_gate_balance) == 0

    # Fetch post-withdrawal shares
    after_user_shares = (await gate.balanceOf(shrine_user.address).invoke()).result.uint
    total_shares = (await gate.totalSupply().invoke()).result.uint

    assert from_uint(after_user_shares) == 0
    assert from_uint(total_shares) == 0

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == 0


@pytest.mark.asyncio
async def test_gate_withdraw_before_sync_pass(users, gate, underlying, gate_deposit):
    """
    Withdraw initially deposited assets before sync.
    """
    abbot = await users("abbot")
    shrine_user = await users("shrine user")

    # Redeem
    await abbot.send_tx(
        gate.contract_address,
        "withdraw",
        [*FIRST_DEPOSIT_AMT_UINT, shrine_user.address, shrine_user.address],
    )

    # Fetch post-withdrawal balances
    after_user_balance = (await underlying.balanceOf(shrine_user.address).invoke()).result.balance
    after_gate_balance = (await underlying.balanceOf(gate.contract_address).invoke()).result.balance

    assert from_uint(after_user_balance) == INITIAL_AMT
    assert from_uint(after_gate_balance) == 0

    # Fetch post-withdrawal shares
    after_user_shares = (await gate.balanceOf(shrine_user.address).invoke()).result.uint
    total_shares = (await gate.totalSupply().invoke()).result.uint

    assert from_uint(after_user_shares) == 0
    assert from_uint(total_shares) == 0

    # Check exchange rate
    exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert exchange_rate == 0


@pytest.mark.asyncio
async def test_gate_withdraw_after_sync_pass(users, gate, underlying, gate_deposit, sync):
    """
    Withdraw initially deposited assets after sync.
    """
    abbot = await users("abbot")
    shrine_user = await users("shrine user")

    # Get exchange rate, underlying balances and share balances before sync
    before_exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad

    before_user_balance = from_uint((await underlying.balanceOf(shrine_user.address).invoke()).result.balance)
    before_gate_balance = from_uint((await underlying.balanceOf(gate.contract_address).invoke()).result.balance)

    before_user_shares = from_uint((await gate.balanceOf(shrine_user.address).invoke()).result.uint)
    before_gate_shares = from_uint((await gate.totalSupply().invoke()).result.uint)

    # Get expected shares
    expected_shares_withdrawn = get_shares_from_assets(before_gate_shares, before_gate_balance, FIRST_DEPOSIT_AMT)

    # Redeem
    await abbot.send_tx(
        gate.contract_address,
        "withdraw",
        [*FIRST_DEPOSIT_AMT_UINT, shrine_user.address, shrine_user.address],
    )

    # Fetch post-withdrawal balances
    after_user_balance = from_uint((await underlying.balanceOf(shrine_user.address).invoke()).result.balance)
    after_gate_balance = from_uint((await underlying.balanceOf(gate.contract_address).invoke()).result.balance)

    assert after_user_balance == before_user_balance + FIRST_DEPOSIT_AMT
    assert after_gate_balance == before_gate_balance - FIRST_DEPOSIT_AMT

    # Fetch post-withdrawal shares
    after_user_shares = from_uint((await gate.balanceOf(shrine_user.address).invoke()).result.uint)
    after_gate_shares = from_uint((await gate.totalSupply().invoke()).result.uint)

    assert_equalish(
        from_wad(after_user_shares),
        from_wad(before_user_shares) - expected_shares_withdrawn,
    )
    assert_equalish(
        from_wad(after_gate_shares),
        from_wad(before_gate_shares) - expected_shares_withdrawn,
    )

    # Check exchange rate remains unchanged
    after_exchange_rate = (await gate.get_exchange_rate().invoke()).result.wad
    assert after_exchange_rate == before_exchange_rate


@pytest.mark.asyncio
async def test_kill(users, gate, underlying, gate_deposit, sync):
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
            [*SECOND_DEPOSIT_AMT_UINT, shrine_user.address],
        )

    # Assert mint fails
    with pytest.raises(StarkException, match="Gate: Gate is not live"):
        await abbot.send_tx(gate.contract_address, "mint", [*SECOND_MINT_AMT_UINT, shrine_user.address])

    # Assert withdraw succeeds
    withdraw_amt = to_wad(5)
    withdraw_amt_uint = to_uint(withdraw_amt)

    before_user_balance = from_uint((await underlying.balanceOf(shrine_user.address).invoke()).result.balance)
    before_gate_balance = from_uint((await underlying.balanceOf(gate.contract_address).invoke()).result.balance)

    before_user_shares = from_uint((await gate.balanceOf(shrine_user.address).invoke()).result.uint)
    before_gate_shares = from_uint((await gate.totalSupply().invoke()).result.uint)

    expected_shares = get_shares_from_assets(before_gate_shares, before_gate_balance, withdraw_amt)

    await abbot.send_tx(
        gate.contract_address,
        "withdraw",
        [*withdraw_amt_uint, shrine_user.address, shrine_user.address],
    )

    after_user_balance = from_uint((await underlying.balanceOf(shrine_user.address).invoke()).result.balance)
    after_gate_balance = from_uint((await underlying.balanceOf(gate.contract_address).invoke()).result.balance)

    after_user_shares = from_uint((await gate.balanceOf(shrine_user.address).invoke()).result.uint)
    after_gate_shares = from_uint((await gate.totalSupply().invoke()).result.uint)

    assert after_user_balance == before_user_balance + withdraw_amt
    assert after_gate_balance == before_gate_balance - withdraw_amt

    assert_equalish(from_wad(after_user_shares), from_wad(before_user_shares) - expected_shares)
    assert_equalish(from_wad(after_gate_shares), from_wad(before_gate_shares) - expected_shares)

    # Assert redeem succeeds
    redeem_amt = to_wad(5)
    redeem_amt_uint = to_uint(redeem_amt)

    before_user_balance = from_uint((await underlying.balanceOf(shrine_user.address).invoke()).result.balance)
    before_gate_balance = from_uint((await underlying.balanceOf(gate.contract_address).invoke()).result.balance)

    before_user_shares = from_uint((await gate.balanceOf(shrine_user.address).invoke()).result.uint)
    before_gate_shares = from_uint((await gate.totalSupply().invoke()).result.uint)

    expected_assets = get_assets_from_shares(before_gate_shares, before_gate_balance, redeem_amt)

    await abbot.send_tx(
        gate.contract_address,
        "redeem",
        [*redeem_amt_uint, shrine_user.address, shrine_user.address],
    )

    after_user_balance = from_uint((await underlying.balanceOf(shrine_user.address).invoke()).result.balance)
    after_gate_balance = from_uint((await underlying.balanceOf(gate.contract_address).invoke()).result.balance)

    after_user_shares = from_uint((await gate.balanceOf(shrine_user.address).invoke()).result.uint)
    after_gate_shares = from_uint((await gate.totalSupply().invoke()).result.uint)

    assert_equalish(from_wad(after_user_balance), from_wad(before_user_balance) + expected_assets)
    assert_equalish(from_wad(after_gate_balance), from_wad(before_gate_balance) - expected_assets)

    assert after_user_shares == before_user_shares - redeem_amt
    assert after_gate_shares == before_gate_shares - redeem_amt


@pytest.mark.asyncio
async def test_unauthorized_mint_deposit(users, underlying, gate):
    """Test third-party initiated"""
    shrine_user = await users("shrine user")
    bad_guy = await users("bad guy")

    # Seed unauthorized address with underlying
    await bad_guy.send_tx(underlying.contract_address, "mint", [bad_guy.address, *INITIAL_AMT_UINT])
    # Sanity check
    assert from_uint((await underlying.balanceOf(bad_guy.address).invoke()).result.balance) == INITIAL_AMT

    with pytest.raises(StarkException):
        await bad_guy.send_tx(gate.contract_address, "mint", [*FIRST_MINT_AMT_UINT, shrine_user.address])
        await bad_guy.send_tx(
            gate.contract_address,
            "deposit",
            [*FIRST_DEPOSIT_AMT_UINT, shrine_user.address],
        )


@pytest.mark.asyncio
async def test_unauthorized_redeem_withdraw(users, gate, gate_deposit):
    """Test user-initiated"""
    shrine_user = await users("shrine user")

    # Sanity check
    bal = from_uint((await gate.balanceOf(shrine_user.address).invoke()).result.uint)
    assert bal == INITIAL_AMT - FIRST_DEPOSIT_AMT

    with pytest.raises(StarkException):
        await shrine_user.send_tx(
            gate.contract_address,
            "redeem",
            [*FIRST_MINT_AMT_UINT, shrine_user.address, shrine_user.address],
        )
        await shrine_user.send_tx(
            gate.contract_address,
            "withdraw",
            [*FIRST_DEPOSIT_AMT_UINT, shrine_user.address, shrine_user.address],
        )


#
# Tests - Restricted approve and transfers
#


@pytest.mark.asyncio
async def test_gate_transferfrom_pass(users, gate, gate_deposit):
    abbot = await users("abbot")
    shrine_user = await users("shrine user")
    shrine_guest = await users("shrine guest")

    transfer = await abbot.send_tx(
        gate.contract_address,
        "transferFrom",
        [shrine_user.address, shrine_guest.address, *FIRST_DEPOSIT_AMT_UINT],
    )
    assert transfer.call_info.result[1] == TRUE

    # Fetch sender and recipient balances after transfer
    after_sender_balance = (await gate.balanceOf(shrine_user.address).invoke()).result.uint
    after_recipient_balance = (await gate.balanceOf(shrine_guest.address).invoke()).result.uint

    assert from_uint(after_sender_balance) == 0
    assert from_uint(after_recipient_balance) == FIRST_DEPOSIT_AMT


@pytest.mark.asyncio
async def test_gate_approve_transferfrom_fail(users, gate, gate_subsequent_deposit):
    shrine_user = await users("shrine user")
    shrine_guest = await users("shrine guest")

    amt = to_wad(1)
    amt_uint = to_uint(amt)

    approve = await shrine_user.send_tx(gate.contract_address, "approve", [shrine_guest.address, *amt_uint])
    assert approve.call_info.result[1] == FALSE

    allowance = (await gate.allowance(shrine_user.address, shrine_guest.address).invoke()).result.uint
    assert from_uint(allowance) == 0

    # Fetch sender and recipient balances before transfer
    before_sender_balance = (await gate.balanceOf(shrine_user.address).invoke()).result.uint
    before_recipient_balance = (await gate.balanceOf(shrine_guest.address).invoke()).result.uint

    transfer = await shrine_user.send_tx(
        gate.contract_address,
        "transferFrom",
        [shrine_user.address, shrine_guest.address, *amt_uint],
    )
    assert transfer.call_info.result[1] == FALSE

    # Fetch sender and recipient balances after transfer
    after_sender_balance = (await gate.balanceOf(shrine_user.address).invoke()).result.uint
    after_recipient_balance = (await gate.balanceOf(shrine_guest.address).invoke()).result.uint

    # Assert no changes
    assert before_sender_balance == after_sender_balance
    assert before_recipient_balance == after_recipient_balance


@pytest.mark.asyncio
async def test_gate_transfer_fail(users, gate, gate_subsequent_deposit):
    shrine_user = await users("shrine user")
    shrine_guest = await users("shrine guest")

    amt = to_wad(1)
    amt_uint = to_uint(amt)

    # Fetch sender and recipient balances before transfer
    before_sender_balance = (await gate.balanceOf(shrine_user.address).invoke()).result.uint
    before_recipient_balance = (await gate.balanceOf(shrine_guest.address).invoke()).result.uint

    transfer = await shrine_user.send_tx(gate.contract_address, "transfer", [shrine_guest.address, *amt_uint])
    assert transfer.call_info.result[1] == FALSE

    # Fetch sender and recipient balances after transfer
    after_sender_balance = (await gate.balanceOf(shrine_user.address).invoke()).result.uint
    after_recipient_balance = (await gate.balanceOf(shrine_guest.address).invoke()).result.uint

    # Assert no changes
    assert before_sender_balance == after_sender_balance
    assert before_recipient_balance == after_recipient_balance
