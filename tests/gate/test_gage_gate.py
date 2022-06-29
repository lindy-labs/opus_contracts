import pytest
from starkware.starknet.testing.objects import StarknetTransactionExecutionInfo

from tests.gate.constants import FIRST_DEPOSIT_AMT, FIRST_REBASE_AMT, TAX
from tests.utils import MAX_UINT256, TRUE, assert_event_emitted, from_ray, from_uint

#
# Fixtures
#


@pytest.fixture
async def gate_deposit(users, gate_gage_rebasing, gage_rebasing) -> StarknetTransactionExecutionInfo:
    gate = gate_gage_rebasing

    shrine_user = await users("shrine user")
    abbot = await users("abbot")

    # Approve Gate to transfer tokens from user
    await shrine_user.send_tx(gage_rebasing.contract_address, "approve", [gate.contract_address, *MAX_UINT256])

    # Call deposit
    deposit = await abbot.send_tx(gate.contract_address, "deposit", [*(FIRST_DEPOSIT_AMT, 0), shrine_user.address])
    return deposit


@pytest.fixture
async def rebase(users, gate_gage_rebasing, gage_rebasing, gate_deposit) -> StarknetTransactionExecutionInfo:
    """
    Rebase the gate contract's balance by adding 10%
    """
    gate = gate_gage_rebasing
    shrine_user = await users("shrine user")

    tx = await shrine_user.send_tx(
        gage_rebasing.contract_address, "mint", [gate.contract_address, *(FIRST_REBASE_AMT, 0)]
    )
    return tx


#
# Tests
#


@pytest.mark.asyncio
async def test_gate_setup(gate_gage_rebasing, gage_rebasing, users):
    gate = gate_gage_rebasing

    # Check system is live
    live = (await gate.get_live().invoke()).result.bool
    assert live == TRUE

    # Check asset address
    asset = (await gate.asset().invoke()).result.assetTokenAddress
    assert asset == gage_rebasing.contract_address

    # Check total assets
    asset_bal = from_uint((await gate.totalAssets().invoke()).result.totalManagedAssets)
    assert asset_bal == 0

    # Check Abbot address is authorized
    abbot = await users("abbot")
    authorized = (await gate.get_auth(abbot.address).invoke()).result.bool
    assert authorized == TRUE

    # Check tax
    tax = (await gate.get_tax().invoke()).result.ray
    assert tax == TAX

    # Check taxman
    taxman = await users("taxman")
    taxman_address = (await gate.get_taxman_address().invoke()).result.address
    assert taxman_address == taxman.address

    # Check initial values
    assert from_uint((await gate.totalSupply().invoke()).result.totalSupply) == 0


@pytest.mark.asyncio
async def test_gate_deposit(users, gate_gage_rebasing, gage_rebasing, gate_deposit):
    gate = gate_gage_rebasing

    abbot = await users("abbot")
    shrine_user = await users("shrine user")

    # Check vault underlying balance
    total_bal = from_uint((await gage_rebasing.balanceOf(gate.contract_address).invoke()).result.balance)
    total_assets = (await gate.totalAssets().invoke()).result.totalManagedAssets
    assert total_bal == from_uint(total_assets) == FIRST_DEPOSIT_AMT

    underlying_bal = (await gate.get_last_underlying_balance().invoke()).result.wad
    assert underlying_bal == total_bal

    # Check vault shares balance
    total_shares = from_uint((await gate.totalSupply().invoke()).result.totalSupply)
    user_shares = (await gate.balanceOf(shrine_user.address).invoke()).result.balance
    assert total_shares == from_uint(user_shares) == FIRST_DEPOSIT_AMT

    assert_event_emitted(
        gate_deposit,
        gate.contract_address,
        "Deposit",
        [abbot.address, shrine_user.address, *total_assets, *user_shares],
    )


@pytest.mark.asyncio
async def test_gate_sync(users, gate_gage_rebasing, gage_rebasing, rebase):
    gate = gate_gage_rebasing

    abbot = await users("abbot")
    taxman = await users("taxman")
    shrine_user = await users("shrine user")

    # Get balances before sync
    before_taxman_bal = from_uint((await gage_rebasing.balanceOf(taxman.address).invoke()).result.balance)
    rebased_bal = from_uint((await gage_rebasing.balanceOf(gate.contract_address).invoke()).result.balance)

    # Check gage token contract for rebased balance
    assert rebased_bal == FIRST_DEPOSIT_AMT + FIRST_REBASE_AMT

    # Fetch last underlying balance
    before_underlying_bal = (await gate.get_last_underlying_balance().invoke()).result.wad

    # Update Gate's balance and charge tax
    sync = await abbot.send_tx(gate.contract_address, "sync", [])

    # Check Gate's managed assets and balance
    after_gate_bal = from_uint((await gate.totalAssets().invoke()).result.totalManagedAssets)
    after_underlying_bal = (await gate.get_last_underlying_balance().invoke()).result.wad

    tax = int(from_ray(TAX) * FIRST_REBASE_AMT)
    increment = FIRST_REBASE_AMT - tax

    assert after_gate_bal == after_underlying_bal == rebased_bal - tax == before_underlying_bal + increment

    # Check that user's redeemable balance has increased
    user_shares_uint = (await gate.balanceOf(shrine_user.address).invoke()).result.balance
    user_underlying = from_uint((await gate.previewRedeem(user_shares_uint).invoke()).result.assets)
    assert user_underlying == after_gate_bal

    # Check event emitted
    assert_event_emitted(sync, gate.contract_address, "Sync", [before_underlying_bal, after_underlying_bal, tax])

    # Check taxman has received tax
    after_taxman_bal = from_uint((await gage_rebasing.balanceOf(taxman.address).invoke()).result.balance)
    assert after_taxman_bal == before_taxman_bal + tax
