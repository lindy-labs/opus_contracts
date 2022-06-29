import pytest
from starkware.starknet.testing.objects import StarknetTransactionExecutionInfo

from tests.gate.constants import FIRST_DEPOSIT_AMT, FIRST_REBASE_AMT, TAX
from tests.utils import MAX_UINT256, TRUE, from_ray, from_uint, to_uint

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
    asset_bal = (await gate.totalAssets().invoke()).result.totalManagedAssets
    assert asset_bal == to_uint(0)

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

    shrine_user = await users("shrine user")

    # Check vault underlying balance
    total_bal = (await gage_rebasing.balanceOf(gate.contract_address).invoke()).result.balance
    total_assets = (await gate.totalAssets().invoke()).result.totalManagedAssets
    assert total_bal == total_assets == to_uint(FIRST_DEPOSIT_AMT)

    # Check vault shares balance
    total_shares = (await gate.totalSupply().invoke()).result.totalSupply
    user_shares = (await gate.balanceOf(shrine_user.address).invoke()).result.balance
    assert total_shares == user_shares == to_uint(FIRST_DEPOSIT_AMT)

    # TODO Test events


@pytest.mark.asyncio
async def test_gate_sync(users, gate_gage_rebasing, gage_rebasing, rebase):
    gate = gate_gage_rebasing

    abbot = await users("abbot")

    # Check gage token contract for rebased balance
    rebased_bal = (await gage_rebasing.balanceOf(gate.contract_address).invoke()).result.balance
    assert rebased_bal == to_uint(FIRST_DEPOSIT_AMT + FIRST_REBASE_AMT)

    # Update Gate's balance and charge tax
    sync = await abbot.send_tx(gate.contract_address, "sync", [])
    after_bal = (await gate.totalAssets().invoke()).result.totalManagedAssets
    assert after_bal.low == rebased_bal.low - (from_ray(TAX) * FIRST_REBASE_AMT)

    # TODO Test events
