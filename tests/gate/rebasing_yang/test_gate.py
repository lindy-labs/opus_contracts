from decimal import Decimal

import pytest
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.objects import StarknetCallInfo
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

from tests.gate.rebasing_yang.constants import *  # noqa: F403
from tests.roles import GateRoles, ShrineRoles
from tests.utils import (
    BAD_GUY,
    DEPLOYMENT_TIMESTAMP,
    FALSE,
    GATE_OWNER,
    GATE_ROLE_FOR_SENTINEL,
    MAX_UINT256,
    SHRINE_OWNER,
    TROVE1_OWNER,
    TROVE2_OWNER,
    TROVE_1,
    TROVE_2,
    TRUE,
    WAD_DECIMALS,
    WAD_ERROR_MARGIN,
    WAD_SCALE,
    ZERO_ADDRESS,
    YangConfig,
    assert_equalish,
    assert_event_emitted,
    compile_code,
    custom_error_margin,
    from_fixed_point,
    from_uint,
    from_wad,
    get_contract_code_with_addition,
    get_contract_code_with_replacement,
    set_block_timestamp,
    str_to_felt,
    to_fixed_point,
    to_ray,
    to_uint,
    to_wad,
)

#
# Constants
#

MOCK_ABBOT_WITH_SENTINEL = str_to_felt("abbot with sentinel")


#
# Helper functions
#


def get_yang_from_assets(total_yang: int, total_assets: int, assets_amt: int, decimals: int) -> Decimal:
    """
    Helper function to calculate the number of yang given a deposit of assets.

    Arguments
    ---------
    total_yang : int
        Total supply of yang before deposit in wad.
    total_assets : int
        Total assets held by vault in the denomination of the decimals of the asset.
    assets_amt : int
        Amount of assets to be deposited in the denomination of the decimals of the asset.
    decimals : int
        Number of decimals for the asset.

    Returns
    -------
    Amount of yang to be issued in Decimal.
    """
    return from_wad(total_yang) * from_fixed_point(assets_amt, decimals) / from_fixed_point(total_assets, decimals)


def get_assets_from_yang(total_yang: int, total_assets: int, yang_amt: int, decimals: int) -> Decimal:
    """
    Helper function to calculate the number of assets to be deposited to issue the
    given value of yang.

    Arguments
    ---------
    total_yang : int
        Total supply of yang before deposit in wad.
    total_assets : int
        Total assets held by vault in the denomination of the decimals of the asset.
    yang_amt : int
        Amount of yang to be issued in wad.
    decimals: int
        Number of decimals for the asset.

    Returns
    -------
    Amount of assets to be deposited in Decimal.
    """
    return from_fixed_point(total_assets, decimals) * from_wad(yang_amt) / from_wad(total_yang)


#
# Fixtures
#


@pytest.fixture
async def taxable_gate_contract() -> StarknetContract:
    """
    Helper fixture to modify the taxable gate contract with a custom `compound`
    function for testing.
    """
    taxable_gate_code = get_contract_code_with_replacement(
        "contracts/gate/rebasing_yang/gate_taxable.cairo",
        {
            """
func compound{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    return ();
}
""": ""
        },
    )

    # Function to simulate compounding by minting the underlying token
    additional_code = """
@contract_interface
namespace MockRebasingToken {
    func mint(recipient: felt, amount: Uint256) {
    }
}

const REBASE_RATIO = 10 * WadRay.RAY_PERCENT;  // 10%

func compound{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    // Get asset and gate addresses
    let asset: address = Gate.get_asset();
    let gate: address = get_contract_address();

    // Calculate rebase amount based on 10% of current gate's balance
    let current_assets: ufelt = Gate.get_total_assets();
    let rebase_amount: ufelt = WadRay.rmul(current_assets, REBASE_RATIO);
    let (rebase_amount_uint: Uint256) = WadRay.to_uint(rebase_amount);

    // Minting tokens
    MockRebasingToken.mint(contract_address=asset, recipient=gate, amount=rebase_amount_uint);

    return ();
}
    """

    taxable_gate_code = get_contract_code_with_addition(taxable_gate_code, additional_code)
    taxable_gate_contract = compile_code(taxable_gate_code)

    return taxable_gate_contract


@pytest.fixture
async def funded_users(steth_token, wbtc_token):
    steth_token_decimals = (await steth_token.decimals().execute()).result.decimals
    steth_inital_amt = to_fixed_point(INITIAL_AMT, steth_token_decimals)
    await steth_token.mint(TROVE1_OWNER, (steth_inital_amt, 0)).execute(caller_address=TROVE1_OWNER)
    await steth_token.mint(TROVE2_OWNER, (steth_inital_amt, 0)).execute(caller_address=TROVE2_OWNER)

    wbtc_token_decimals = (await wbtc_token.decimals().execute()).result.decimals
    wbtc_inital_amt = to_fixed_point(INITIAL_AMT, wbtc_token_decimals)
    await wbtc_token.mint(TROVE1_OWNER, (wbtc_inital_amt, 0)).execute(caller_address=TROVE1_OWNER)
    await wbtc_token.mint(TROVE2_OWNER, (wbtc_inital_amt, 0)).execute(caller_address=TROVE2_OWNER)


@pytest.fixture
async def steth_gate_taxable_info(
    starknet: Starknet, shrine, taxable_gate_contract, steth_token, steth_yang: YangConfig
) -> tuple[StarknetContract, int, StarknetContract]:
    """
    Deploys an instance of the Gate module with autocompounding and tax.

    Returns a tuple of the token contract instance, the token decimals and the gate contract instance.
    """
    gate = await starknet.deploy(
        contract_class=taxable_gate_contract,
        constructor_calldata=[
            GATE_OWNER,
            shrine.contract_address,
            steth_token.contract_address,
            TAX_RAY,
            TAX_COLLECTOR,
        ],
    )

    # Grant `Sentinel` access to `enter` and `exit`
    await gate.grant_role(GATE_ROLE_FOR_SENTINEL, MOCK_ABBOT_WITH_SENTINEL).execute(caller_address=GATE_OWNER)
    return steth_token, steth_yang.decimals, gate


@pytest.fixture
async def steth_gate_info(
    steth_token, steth_gate, steth_yang: YangConfig
) -> tuple[StarknetContract, int, StarknetContract]:
    """
    Returns a tuple of the token contract instance, the token decimals and the gate contract instance.
    """
    # Grant `Sentinel` access to `enter` and `exit
    await steth_gate.grant_role(GATE_ROLE_FOR_SENTINEL, MOCK_ABBOT_WITH_SENTINEL).execute(caller_address=GATE_OWNER)
    return steth_token, steth_yang.decimals, steth_gate


@pytest.fixture
async def wbtc_gate_taxable_info(
    starknet: Starknet, shrine, taxable_gate_contract, wbtc_token, wbtc_yang: YangConfig
) -> tuple[StarknetContract, int, StarknetContract]:
    """
    Deploys an instance of the Gate module with autocompounding and tax.

    Returns a tuple of the token contract instance, the token decimals and the gate contract instance.
    """
    gate = await starknet.deploy(
        contract_class=taxable_gate_contract,
        constructor_calldata=[
            GATE_OWNER,
            shrine.contract_address,
            wbtc_token.contract_address,
            TAX_RAY,
            TAX_COLLECTOR,
        ],
    )

    # Grant `Sentinel` access to `enter` and `exit`
    await gate.grant_role(GATE_ROLE_FOR_SENTINEL, MOCK_ABBOT_WITH_SENTINEL).execute(caller_address=GATE_OWNER)
    return wbtc_token, wbtc_yang.decimals, gate


@pytest.fixture
async def wbtc_gate_info(
    wbtc_token, wbtc_gate, wbtc_yang: YangConfig
) -> tuple[StarknetContract, int, StarknetContract]:
    """
    Returns a tuple of the token contract instance, the token decimals and the gate contract instance.
    """
    # Grant `Sentinel` access to `enter` and `exit
    await wbtc_gate.grant_role(GATE_ROLE_FOR_SENTINEL, MOCK_ABBOT_WITH_SENTINEL).execute(caller_address=GATE_OWNER)
    return wbtc_token, wbtc_yang.decimals, wbtc_gate


@pytest.fixture
async def shrine_authed(starknet: Starknet, shrine, steth_token, wbtc_token) -> StarknetContract:
    """
    Add Sentinel as an authorized address of Shrine.
    """

    # Grant `Abbot` access to `deposit` and `withdraw` in `Shrine`
    role_value = ShrineRoles.DEPOSIT + ShrineRoles.WITHDRAW
    await shrine.grant_role(role_value, MOCK_ABBOT_WITH_SENTINEL).execute(caller_address=SHRINE_OWNER)

    set_block_timestamp(starknet, DEPLOYMENT_TIMESTAMP)

    # Add steth_token as Yang
    await shrine.add_yang(
        steth_token.contract_address,
        to_ray(Decimal("0.8")),
        to_wad(1000),
        to_ray(Decimal("0.02")),
        0,
    ).execute(caller_address=SHRINE_OWNER)

    await shrine.add_yang(
        wbtc_token.contract_address,
        to_ray(Decimal("0.8")),
        to_wad(10_000),
        to_ray(Decimal("0.01")),
        0,
    ).execute(caller_address=SHRINE_OWNER)

    return shrine


@pytest.fixture
async def trove_1_enter(shrine_authed, gate_info, funded_users) -> StarknetCallInfo:
    """
    Deposit to trove 1 by user 1.
    """
    token, decimals, gate = gate_info

    await token.approve(gate.contract_address, MAX_UINT256).execute(caller_address=TROVE1_OWNER)

    scaled_deposit_amt = to_fixed_point(FIRST_DEPOSIT_AMT, decimals)

    yang_wad = (await gate.preview_enter(scaled_deposit_amt).execute()).result.yang_amt
    enter = await gate.enter(TROVE1_OWNER, TROVE_1, scaled_deposit_amt).execute(caller_address=MOCK_ABBOT_WITH_SENTINEL)
    await shrine_authed.deposit(token.contract_address, TROVE_1, yang_wad).execute(
        caller_address=MOCK_ABBOT_WITH_SENTINEL
    )

    return enter


@pytest.fixture
async def trove_2_enter_before_rebase(shrine_authed, gate_info, trove_1_enter) -> StarknetCallInfo:
    """
    Deposit to trove 2 by user 2 after user 1 has deposited to trove 1 but before rebase.
    """
    token, decimals, gate = gate_info

    await token.approve(gate.contract_address, MAX_UINT256).execute(caller_address=TROVE2_OWNER)

    scaled_deposit_amt = to_fixed_point(FIRST_DEPOSIT_AMT, decimals)

    yang_wad = (await gate.preview_enter(scaled_deposit_amt).execute()).result.yang_amt
    enter = await gate.enter(TROVE2_OWNER, TROVE_2, scaled_deposit_amt).execute(caller_address=MOCK_ABBOT_WITH_SENTINEL)
    await shrine_authed.deposit(token.contract_address, TROVE_2, yang_wad).execute(
        caller_address=MOCK_ABBOT_WITH_SENTINEL
    )

    return enter


@pytest.fixture
async def trove_2_enter_after_rebase(shrine_authed, gate_info, trove_1_enter, rebase) -> StarknetCallInfo:
    """
    Deposit by to trove 2 by user 2 after user 1 has deposited to trove 1 and after rebase.
    """
    token, decimals, gate = gate_info

    await token.approve(gate.contract_address, MAX_UINT256).execute(caller_address=TROVE2_OWNER)

    scaled_deposit_amt = to_fixed_point(FIRST_DEPOSIT_AMT, decimals)

    yang_wad = (await gate.preview_enter(scaled_deposit_amt).execute()).result.yang_amt
    enter = await gate.enter(TROVE2_OWNER, TROVE_2, scaled_deposit_amt).execute(caller_address=MOCK_ABBOT_WITH_SENTINEL)
    await shrine_authed.deposit(token.contract_address, TROVE_2, yang_wad).execute(
        caller_address=MOCK_ABBOT_WITH_SENTINEL
    )

    return enter


@pytest.fixture
async def rebase(gate_info, trove_1_enter) -> StarknetCallInfo:
    """
    Rebase the gate contract's balance by adding 10%
    """
    token, decimals, gate = gate_info

    scaled_rebase_amt = to_fixed_point(FIRST_REBASE_AMT, decimals)

    tx = await token.mint(gate.contract_address, to_uint(scaled_rebase_amt)).execute(caller_address=TROVE1_OWNER)
    return tx


@pytest.fixture
def gate_info(request) -> StarknetContract:
    """
    Wrapper fixture to pass the non-taxable and taxable instances of the respective gate fixtures
    to `pytest.parametrize`.

    Returns a tuple of the token contract instance, the token decimals and the gate contract instance.
    """
    return request.getfixturevalue(request.param)


#
# Tests - Setup
#


@pytest.mark.parametrize(
    "gate_info",
    ["steth_gate_info", "steth_gate_taxable_info", "wbtc_gate_info", "wbtc_gate_taxable_info"],
    indirect=["gate_info"],
)
@pytest.mark.asyncio
async def test_gate_setup(gate_info):
    steth_token, _, gate = gate_info
    # Check system is live
    live = (await gate.get_live().execute()).result.is_live
    assert live == TRUE

    # Check asset address
    assert (await gate.get_asset().execute()).result.asset == steth_token.contract_address

    # Check total assets
    asset_bal = (await gate.get_total_assets().execute()).result.total
    assert asset_bal == 0

    # Check Sentinel address is authorized to `enter` and `exit`
    GATE_ROLE_FOR_SENTINEL = (await gate.get_roles(MOCK_ABBOT_WITH_SENTINEL).execute()).result.roles
    assert GATE_ROLE_FOR_SENTINEL == GATE_ROLE_FOR_SENTINEL

    # Check initial values
    assert (await gate.get_total_yang().execute()).result.total == 0

    # Check initial exchange rate
    asset_amt_per_yang = (await gate.get_asset_amt_per_yang().execute()).result.amt
    assert asset_amt_per_yang == WAD_SCALE

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


@pytest.mark.parametrize(
    "gate_info",
    ["steth_gate_info", "steth_gate_taxable_info", "wbtc_gate_info", "wbtc_gate_taxable_info"],
    indirect=["gate_info"],
)
@pytest.mark.asyncio
async def test_gate_enter_pass(shrine_authed, gate_info, trove_1_enter, collect_gas_cost):
    token, decimals, gate = gate_info

    # 2 unique key updated for ERC20 transfer (Gate's balance, user's balance)
    collect_gas_cost("gate/enter", trove_1_enter, 2, 1)

    # Check gate asset balance
    total_bal = (await gate.get_total_assets().execute()).result.total
    assert total_bal == to_fixed_point(FIRST_DEPOSIT_AMT, decimals)

    # Check gate yang balance
    total_yang = (await gate.get_total_yang().execute()).result.total
    user_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_1).execute()).result.balance
    assert total_yang == user_yang == FIRST_DEPOSIT_YANG

    # Check exchange rate
    asset_amt_per_yang = (await gate.get_asset_amt_per_yang().execute()).result.amt
    assert asset_amt_per_yang == WAD_SCALE

    # Check event
    assert_event_emitted(
        trove_1_enter,
        gate.contract_address,
        "Enter",
        [TROVE1_OWNER, TROVE_1, total_bal, user_yang],
    )


@pytest.mark.usefixtures("rebase")
@pytest.mark.parametrize(
    "gate_info",
    ["steth_gate_info", "steth_gate_taxable_info", "wbtc_gate_info", "wbtc_gate_taxable_info"],
    indirect=["gate_info"],
)
@pytest.mark.asyncio
async def test_gate_subsequent_enter_with_rebase(shrine_authed, gate_info):
    token, decimals, gate = gate_info

    # Get gate asset and yang balance
    before_total_yang = (await gate.get_total_yang().execute()).result.total
    before_total_assets = (await gate.get_total_assets().execute()).result.total

    # Calculate expected yang
    deposit_amt = to_fixed_point(SECOND_DEPOSIT_AMT, decimals)
    expected_yang = get_yang_from_assets(before_total_yang, before_total_assets, deposit_amt, decimals)

    # Get user's yang before subsequent deposit
    before_user_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_1).execute()).result.balance

    # Deposit to trove 1

    yang_wad = (await gate.preview_enter(deposit_amt).execute()).result.yang_amt
    enter = await gate.enter(TROVE1_OWNER, TROVE_1, deposit_amt).execute(caller_address=MOCK_ABBOT_WITH_SENTINEL)
    await shrine_authed.deposit(token.contract_address, TROVE_1, yang_wad).execute(
        caller_address=MOCK_ABBOT_WITH_SENTINEL
    )

    # Check gate asset balance
    total_assets = (await gate.get_total_assets().execute()).result.total
    expected_bal = to_fixed_point(INITIAL_AMT + FIRST_REBASE_AMT, decimals)
    assert total_assets == expected_bal

    # Check vault yang balance
    after_total_yang = (await gate.get_total_yang().execute()).result.total
    assert_equalish(
        from_wad(after_total_yang),
        from_wad(before_total_yang) + expected_yang,
        WAD_ERROR_MARGIN,
    )

    # Check user's yang
    after_user_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_1).execute()).result.balance
    assert_equalish(
        from_wad(after_user_yang),
        from_wad(before_user_yang) + expected_yang,
        WAD_ERROR_MARGIN,
    )

    # Check event emitted
    assert_event_emitted(
        enter,
        gate.contract_address,
        "Enter",
        [TROVE1_OWNER, TROVE_1, deposit_amt, to_wad(expected_yang)],
    )


@pytest.mark.parametrize(
    "gate_info",
    ["steth_gate_info", "steth_gate_taxable_info", "wbtc_gate_info", "wbtc_gate_taxable_info"],
    indirect=["gate_info"],
)
@pytest.mark.asyncio
async def test_gate_subsequent_unique_enter_before_rebase(shrine_authed, gate_info, trove_2_enter_before_rebase):
    token, decimals, gate = gate_info

    # Check gate asset balance
    after_total_bal = (await gate.get_total_assets().execute()).result.total
    expected_bal = to_fixed_point(FIRST_DEPOSIT_AMT * 2, decimals)
    assert after_total_bal == expected_bal

    # Check gate yang balance
    after_total_yang = (await gate.get_total_yang().execute()).result.total
    assert after_total_yang == FIRST_DEPOSIT_YANG * 2

    # Check user's yang
    expected_yang = FIRST_DEPOSIT_YANG
    after_user_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_2).execute()).result.balance
    assert after_user_yang == expected_yang

    # Check event emitted
    assert_event_emitted(
        trove_2_enter_before_rebase,
        gate.contract_address,
        "Enter",
        [TROVE2_OWNER, TROVE_2, to_fixed_point(FIRST_DEPOSIT_AMT, decimals), expected_yang],
    )


@pytest.mark.parametrize(
    "gate_info",
    ["steth_gate_info", "steth_gate_taxable_info", "wbtc_gate_info", "wbtc_gate_taxable_info"],
    indirect=["gate_info"],
)
@pytest.mark.asyncio
async def test_gate_subsequent_unique_enter_after_rebase(shrine_authed, gate_info, trove_2_enter_after_rebase):
    token, decimals, gate = gate_info

    # Check gate asset balance
    after_total_bal = (await gate.get_total_assets().execute()).result.total
    expected_bal = to_fixed_point(FIRST_DEPOSIT_AMT * 2 + FIRST_REBASE_AMT, decimals)
    assert after_total_bal == expected_bal

    # Calculate expected yang
    deposit_amt = to_fixed_point(FIRST_DEPOSIT_AMT, decimals)
    deposited_amt = deposit_amt + to_fixed_point(FIRST_REBASE_AMT, decimals)
    expected_yang = get_yang_from_assets(FIRST_DEPOSIT_YANG, deposited_amt, deposit_amt, decimals)

    # Check gate yang balance
    after_total_yang = (await gate.get_total_yang().execute()).result.total
    assert_equalish(
        from_wad(after_total_yang),
        from_wad(FIRST_DEPOSIT_YANG) + expected_yang,
        WAD_ERROR_MARGIN,
    )

    # Check user's yang
    after_user_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_2).execute()).result.balance
    assert_equalish(from_wad(after_user_yang), expected_yang, WAD_ERROR_MARGIN)

    # Check event emitted
    assert_event_emitted(
        trove_2_enter_after_rebase,
        gate.contract_address,
        "Enter",
        [TROVE2_OWNER, TROVE_2, deposit_amt, after_user_yang],
    )


@pytest.mark.usefixtures("trove_1_enter")
@pytest.mark.parametrize(
    "gate_info",
    ["steth_gate_info", "steth_gate_taxable_info", "wbtc_gate_info", "wbtc_gate_taxable_info"],
    indirect=["gate_info"],
)
@pytest.mark.asyncio
async def test_gate_exit_before_rebase(shrine_authed, gate_info, collect_gas_cost):
    """
    Withdraw all yang before rebase.
    """
    token, decimals, gate = gate_info

    # Withdraw from trove 1
    gate_exit = await gate.exit(TROVE1_OWNER, TROVE_1, FIRST_DEPOSIT_YANG).execute(
        caller_address=MOCK_ABBOT_WITH_SENTINEL
    )
    collect_gas_cost("gate/exit", gate_exit, 2, 1)
    await shrine_authed.withdraw(token.contract_address, TROVE_1, FIRST_DEPOSIT_YANG).execute(
        caller_address=MOCK_ABBOT_WITH_SENTINEL
    )

    # Fetch post-withdrawal balances
    after_user_balance = (await token.balanceOf(TROVE1_OWNER).execute()).result.balance
    after_gate_balance = (await gate.get_total_assets().execute()).result.total

    # Assert user receives initial deposit
    assert from_uint(after_user_balance) == to_fixed_point(INITIAL_AMT, decimals)
    assert after_gate_balance == 0

    # Fetch post-withdrawal yang
    after_user_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_1).execute()).result.balance
    total_yang = (await gate.get_total_yang().execute()).result.total

    assert after_user_yang == total_yang == 0

    # Check exchange rate
    asset_amt_per_yang = (await gate.get_asset_amt_per_yang().execute()).result.amt
    assert asset_amt_per_yang == WAD_SCALE

    # Check event
    deposit_amt = to_fixed_point(FIRST_DEPOSIT_AMT, decimals)
    assert_event_emitted(
        gate_exit,
        gate.contract_address,
        "Exit",
        [TROVE1_OWNER, TROVE_1, deposit_amt, FIRST_DEPOSIT_YANG],
    )


@pytest.mark.usefixtures("rebase")
@pytest.mark.parametrize(
    "gate_info",
    ["steth_gate_info", "steth_gate_taxable_info", "wbtc_gate_info", "wbtc_gate_taxable_info"],
    indirect=["gate_info"],
)
@pytest.mark.asyncio
async def test_gate_exit_after_rebase_pass(shrine_authed, gate_info):
    """
    Withdraw all yang after rebase.
    """
    token, decimals, gate = gate_info

    # Withdraw from trove 1
    gate_exit = await gate.exit(TROVE1_OWNER, TROVE_1, FIRST_DEPOSIT_YANG).execute(
        caller_address=MOCK_ABBOT_WITH_SENTINEL
    )
    await shrine_authed.withdraw(token.contract_address, TROVE_1, FIRST_DEPOSIT_YANG).execute(
        caller_address=MOCK_ABBOT_WITH_SENTINEL
    )

    # Fetch post-withdrawal balances
    after_user_balance = (await token.balanceOf(TROVE1_OWNER).execute()).result.balance
    after_gate_balance = (await gate.get_total_assets().execute()).result.total

    # Assert user receives initial deposit and rebased amount
    expected_user_balance = to_fixed_point(INITIAL_AMT + FIRST_REBASE_AMT, decimals)
    assert from_uint(after_user_balance) == expected_user_balance
    assert after_gate_balance == 0

    # Fetch post-withdrawal yang
    after_user_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_1).execute()).result.balance
    total_yang = (await gate.get_total_yang().execute()).result.total

    assert after_user_yang == total_yang == 0

    # Check exchange rate
    asset_amt_per_yang = (await gate.get_asset_amt_per_yang().execute()).result.amt
    assert asset_amt_per_yang == WAD_SCALE

    expected_withdrawn_assets = to_fixed_point(FIRST_DEPOSIT_AMT + FIRST_REBASE_AMT, decimals)
    # Check event
    assert_event_emitted(
        gate_exit,
        gate.contract_address,
        "Exit",
        [TROVE1_OWNER, TROVE_1, expected_withdrawn_assets, FIRST_DEPOSIT_YANG],
    )


@pytest.mark.usefixtures("trove_2_enter_before_rebase")
@pytest.mark.parametrize(
    "gate_info",
    ["steth_gate_info", "steth_gate_taxable_info", "wbtc_gate_info", "wbtc_gate_taxable_info"],
    indirect=["gate_info"],
)
@pytest.mark.asyncio
async def test_gate_multi_user_exit_without_rebase(shrine_authed, gate_info):
    token, decimals, gate = gate_info
    asset_error_margin = custom_error_margin(decimals)

    deposit_amt = to_fixed_point(FIRST_DEPOSIT_AMT, decimals)

    # Get initial exchange rate
    start_asset_amt_per_yang = (await gate.get_asset_amt_per_yang().execute()).result.amt

    # Get initial balance for trove 2
    trove_2_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_2).execute()).result.balance

    # Check gate asset balance
    start_total_bal = (await gate.get_total_assets().execute()).result.total
    start_total_yang = (await gate.get_total_yang().execute()).result.total
    start_user_bal = from_uint((await token.balanceOf(TROVE2_OWNER).execute()).result.balance)

    # Withdraw from trove 2
    trove_2_gate_exit = await gate.exit(TROVE2_OWNER, TROVE_2, trove_2_yang).execute(
        caller_address=MOCK_ABBOT_WITH_SENTINEL
    )
    await shrine_authed.withdraw(token.contract_address, TROVE_2, trove_2_yang).execute(
        caller_address=MOCK_ABBOT_WITH_SENTINEL
    )

    # Calculate expected assets
    expected_assets = get_assets_from_yang(start_total_yang, start_total_bal, trove_2_yang, decimals)

    # Check gate asset balance
    after_total_bal = (await gate.get_total_assets().execute()).result.total
    assert_equalish(
        from_fixed_point(after_total_bal, decimals),
        from_fixed_point(start_total_bal, decimals) - expected_assets,
        asset_error_margin,
    )

    # Check gate yang balance
    after_total_yang = (await gate.get_total_yang().execute()).result.total
    assert after_total_yang == start_total_yang - FIRST_DEPOSIT_YANG

    # Check user's yang
    after_user_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_2).execute()).result.balance
    assert after_user_yang == 0

    after_user_bal = from_uint((await token.balanceOf(TROVE2_OWNER).execute()).result.balance)
    assert_equalish(
        from_fixed_point(after_user_bal, decimals),
        from_fixed_point(start_user_bal, decimals) + expected_assets,
        asset_error_margin,
    )

    # Check exchange rate
    after_asset_amt_per_yang = (await gate.get_asset_amt_per_yang().execute()).result.amt
    assert after_asset_amt_per_yang == start_asset_amt_per_yang

    # Check event emitted
    assert_event_emitted(
        trove_2_gate_exit,
        gate.contract_address,
        "Exit",
        [TROVE2_OWNER, TROVE_2, deposit_amt, FIRST_DEPOSIT_YANG],
    )

    # Get user balance
    start_user_bal = from_uint((await token.balanceOf(TROVE1_OWNER).execute()).result.balance)

    # Get initial balance for trove 2
    trove_1_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_1).execute()).result.balance

    # Withdraw from trove 1
    trove_1_gate_exit = await gate.exit(TROVE1_OWNER, TROVE_1, trove_1_yang).execute(
        caller_address=MOCK_ABBOT_WITH_SENTINEL
    )
    await shrine_authed.withdraw(token.contract_address, TROVE_1, trove_1_yang).execute(
        caller_address=MOCK_ABBOT_WITH_SENTINEL
    )

    # Calculate expected assets
    expected_assets = get_assets_from_yang(after_total_yang, after_total_bal, trove_1_yang, decimals)

    # Check gate asset balance
    end_total_bal = (await gate.get_total_assets().execute()).result.total
    assert_equalish(
        from_fixed_point(end_total_bal, decimals),
        from_fixed_point(after_total_bal, decimals) - expected_assets,
        asset_error_margin,
    )

    # Check gate yang balance
    end_total_yang = (await gate.get_total_yang().execute()).result.total
    assert end_total_yang == 0

    # Check user's yang
    after_user_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_1).execute()).result.balance
    assert after_user_yang == 0

    after_user_bal = from_uint((await token.balanceOf(TROVE1_OWNER).execute()).result.balance)
    assert_equalish(
        from_fixed_point(after_user_bal, decimals),
        from_fixed_point(start_user_bal, decimals) + expected_assets,
        asset_error_margin,
    )

    # Check exchange rate
    end_asset_amt_per_yang = (await gate.get_asset_amt_per_yang().execute()).result.amt
    assert end_asset_amt_per_yang == WAD_SCALE

    # Check event emitted
    assert_event_emitted(
        trove_1_gate_exit,
        gate.contract_address,
        "Exit",
        [TROVE1_OWNER, TROVE_1, deposit_amt, FIRST_DEPOSIT_YANG],
    )


@pytest.mark.usefixtures("trove_2_enter_after_rebase")
@pytest.mark.parametrize(
    "gate_info",
    ["steth_gate_info", "steth_gate_taxable_info", "wbtc_gate_info", "wbtc_gate_taxable_info"],
    indirect=["gate_info"],
)
@pytest.mark.asyncio
async def test_gate_multi_user_exit_with_rebase(shrine_authed, gate_info):
    token, decimals, gate = gate_info
    asset_error_margin = custom_error_margin(decimals)

    # Get initial exchange rate
    start_asset_amt_per_yang = (await gate.get_asset_amt_per_yang().execute()).result.amt

    # Check gate asset balance
    start_total_bal = (await gate.get_total_assets().execute()).result.total
    start_total_yang = (await gate.get_total_yang().execute()).result.total
    start_user_bal = from_uint((await token.balanceOf(TROVE2_OWNER).execute()).result.balance)
    trove_2_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_2).execute()).result.balance

    # Withdraw from trove 2
    await gate.exit(TROVE2_OWNER, TROVE_2, trove_2_yang).execute(caller_address=MOCK_ABBOT_WITH_SENTINEL)
    await shrine_authed.withdraw(token.contract_address, TROVE_2, trove_2_yang).execute(
        caller_address=MOCK_ABBOT_WITH_SENTINEL
    )

    # Calculate expected assets
    expected_assets = get_assets_from_yang(start_total_yang, start_total_bal, trove_2_yang, decimals)

    # Check gate asset balance
    after_total_bal = (await gate.get_total_assets().execute()).result.total

    assert_equalish(
        from_fixed_point(after_total_bal, decimals),
        from_fixed_point(start_total_bal, decimals) - expected_assets,
        asset_error_margin,
    )

    # Check gate yang balance
    after_total_yang = (await gate.get_total_yang().execute()).result.total
    assert after_total_yang == start_total_yang - trove_2_yang

    # Check user's yang
    after_user_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_2).execute()).result.balance
    assert after_user_yang == 0

    after_user_bal = from_uint((await token.balanceOf(TROVE2_OWNER).execute()).result.balance)

    assert_equalish(
        from_fixed_point(after_user_bal, decimals),
        from_fixed_point(start_user_bal, decimals) + expected_assets,
        asset_error_margin,
    )

    # Check exchange rate
    after_asset_amt_per_yang = (await gate.get_asset_amt_per_yang().execute()).result.amt
    assert after_asset_amt_per_yang == start_asset_amt_per_yang

    # Get user balance
    start_user_bal = from_uint((await token.balanceOf(TROVE1_OWNER).execute()).result.balance)
    trove_1_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_1).execute()).result.balance

    # Calculate expected assets
    expected_assets = get_assets_from_yang(after_total_yang, after_total_bal, trove_1_yang, decimals)

    # Withdraw from trove 1
    await gate.exit(TROVE1_OWNER, TROVE_1, trove_1_yang).execute(caller_address=MOCK_ABBOT_WITH_SENTINEL)
    await shrine_authed.withdraw(token.contract_address, TROVE_1, trove_1_yang).execute(
        caller_address=MOCK_ABBOT_WITH_SENTINEL
    )

    # Check gate asset balance
    end_total_bal = (await gate.get_total_assets().execute()).result.total
    assert_equalish(
        from_fixed_point(end_total_bal, decimals),
        from_fixed_point(after_total_bal, decimals) - expected_assets,
        asset_error_margin,
    )

    # Check gate yang balance
    end_total_yang = (await gate.get_total_yang().execute()).result.total
    assert end_total_yang == 0

    # Check user's yang
    after_user_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_1).execute()).result.balance
    assert after_user_yang == 0

    after_user_bal = from_uint((await token.balanceOf(TROVE1_OWNER).execute()).result.balance)
    assert_equalish(
        from_fixed_point(after_user_bal, decimals),
        from_fixed_point(start_user_bal, decimals) + expected_assets,
        asset_error_margin,
    )

    # Check exchange rate
    end_asset_amt_per_yang = (await gate.get_asset_amt_per_yang().execute()).result.amt
    assert end_asset_amt_per_yang == WAD_SCALE


@pytest.mark.usefixtures("rebase")
@pytest.mark.parametrize(
    "gate_info",
    ["steth_gate_info", "steth_gate_taxable_info", "wbtc_gate_info", "wbtc_gate_taxable_info"],
    indirect=["gate_info"],
)
@pytest.mark.asyncio
async def test_kill(shrine_authed, gate_info):
    token, decimals, gate = gate_info
    asset_error_margin = custom_error_margin(decimals)

    # Kill
    await gate.kill().execute(caller_address=GATE_OWNER)
    assert (await gate.get_live().execute()).result.is_live == FALSE

    # Assert enter fails
    with pytest.raises(StarkException, match="Gate: Gate is not live"):
        deposit_amt = to_fixed_point(SECOND_DEPOSIT_AMT, decimals)
        await gate.enter(TROVE1_OWNER, TROVE_1, deposit_amt).execute(caller_address=MOCK_ABBOT_WITH_SENTINEL)

    # Assert withdraw succeeds
    withdraw_yang_amt = to_wad(5)

    # Get user's and gate's asset and yang balances before withdraw
    before_user_balance = from_uint((await token.balanceOf(TROVE1_OWNER).execute()).result.balance)
    before_gate_balance = (await gate.get_total_assets().execute()).result.total

    before_user_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_1).execute()).result.balance
    before_gate_yang = (await gate.get_total_yang().execute()).result.total

    expected_assets = get_assets_from_yang(before_gate_yang, before_gate_balance, withdraw_yang_amt, decimals)

    # Withdraw from trove 1
    await gate.exit(TROVE1_OWNER, TROVE_1, withdraw_yang_amt).execute(caller_address=MOCK_ABBOT_WITH_SENTINEL)
    await shrine_authed.withdraw(token.contract_address, TROVE_1, withdraw_yang_amt).execute(
        caller_address=MOCK_ABBOT_WITH_SENTINEL
    )

    # Get user's and gate's asset and share balances after withdraw
    after_user_balance = from_uint((await token.balanceOf(TROVE1_OWNER).execute()).result.balance)
    after_gate_balance = (await gate.get_total_assets().execute()).result.total

    after_user_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_1).execute()).result.balance
    after_gate_yang = (await gate.get_total_yang().execute()).result.total

    # Assert withdrawal is successful
    assert_equalish(
        from_fixed_point(after_user_balance, decimals),
        from_fixed_point(before_user_balance, decimals) + expected_assets,
        asset_error_margin,
    )
    assert_equalish(
        from_fixed_point(after_gate_balance, decimals),
        from_fixed_point(before_gate_balance, decimals) - expected_assets,
        asset_error_margin,
    )

    assert after_user_yang == before_user_yang - withdraw_yang_amt
    assert after_gate_yang == before_gate_yang - withdraw_yang_amt


@pytest.mark.usefixtures("shrine_authed", "funded_users")
@pytest.mark.parametrize(
    "gate_info",
    ["steth_gate_info", "steth_gate_taxable_info", "wbtc_gate_info", "wbtc_gate_taxable_info"],
    indirect=["gate_info"],
)
@pytest.mark.asyncio
async def test_gate_enter_insufficient_fail(gate_info):
    token, decimals, gate = gate_info

    # Approve Gate to transfer asset from user
    await token.approve(gate.contract_address, MAX_UINT256).execute(TROVE1_OWNER)
    # Call enter with more asset than user has
    with pytest.raises(StarkException, match="Gate: Transfer of asset failed"):
        invalid_deposit_amt = to_fixed_point(INITIAL_AMT, decimals) + 1
        await gate.enter(TROVE1_OWNER, TROVE_1, invalid_deposit_amt).execute(caller_address=MOCK_ABBOT_WITH_SENTINEL)


@pytest.mark.usefixtures("trove_1_enter")
@pytest.mark.parametrize(
    "gate_info",
    ["steth_gate_info", "steth_gate_taxable_info", "wbtc_gate_info", "wbtc_gate_taxable_info"],
    indirect=["gate_info"],
)
@pytest.mark.asyncio
async def test_gate_exit_insufficient_fail(shrine_authed, gate_info):
    token, decimals, gate = gate_info
    # Call withdraw with more gate yang than in the gate
    trove_bal = (await shrine_authed.get_deposit(token.contract_address, TROVE_1).execute()).result.balance

    # Note that there is precision loss for tokens with less than 18 decimals if the excess amount is too small
    # Therefore, we scale the excess by the difference in number of decimals
    excess = 1 * 10 ** (WAD_DECIMALS - decimals)
    with pytest.raises(StarkException, match="Gate: Transfer of asset failed"):
        await gate.exit(TROVE1_OWNER, TROVE_1, trove_bal + excess).execute(caller_address=MOCK_ABBOT_WITH_SENTINEL)


@pytest.mark.parametrize(
    "gate_info",
    ["steth_gate_info", "steth_gate_taxable_info", "wbtc_gate_info", "wbtc_gate_taxable_info"],
    indirect=["gate_info"],
)
@pytest.mark.asyncio
async def test_unauthorized_enter(gate_info):
    """Test third-party initiated"""
    token, decimals, gate = gate_info

    # Seed unauthorized address with asset
    mint_amt = to_fixed_point(INITIAL_AMT, decimals)
    await token.mint(BAD_GUY, to_uint(mint_amt)).execute(caller_address=BAD_GUY)

    # Sanity check
    assert from_uint((await token.balanceOf(BAD_GUY).execute()).result.balance) == mint_amt

    with pytest.raises(StarkException):
        deposit_amt = to_fixed_point(FIRST_DEPOSIT_AMT, decimals)
        await gate.enter(TROVE1_OWNER, TROVE_1, deposit_amt).execute(caller_address=BAD_GUY)


@pytest.mark.usefixtures("trove_1_enter")
@pytest.mark.parametrize(
    "gate_info",
    ["steth_gate_info", "steth_gate_taxable_info", "wbtc_gate_info", "wbtc_gate_taxable_info"],
    indirect=["gate_info"],
)
@pytest.mark.asyncio
async def test_unauthorized_exit(shrine_authed, gate_info):
    """Test user-initiated"""
    token, decimals, gate = gate_info

    # Sanity check
    bal = (await shrine_authed.get_deposit(token.contract_address, TROVE_1).execute()).result.balance
    assert bal == FIRST_DEPOSIT_YANG

    with pytest.raises(StarkException):
        await gate.exit(TROVE1_OWNER, TROVE_1, FIRST_DEPOSIT_YANG).execute(caller_address=TROVE1_OWNER)


@pytest.mark.usefixtures("trove_1_enter")
@pytest.mark.parametrize(
    "gate_info",
    ["steth_gate_info", "steth_gate_taxable_info", "wbtc_gate_info", "wbtc_gate_taxable_info"],
    indirect=["gate_info"],
)
@pytest.mark.parametrize("fn", ["enter", "exit"])
@pytest.mark.asyncio
async def test_zero_enter_exit(shrine_authed, gate_info, fn):
    token, decimals, gate = gate_info

    # Get balance before
    before_yang_bal = (await shrine_authed.get_deposit(token.contract_address, TROVE_1).execute()).result.balance
    before_asset_bal = from_uint((await token.balanceOf(TROVE1_OWNER).execute()).result.balance)

    # Call test function
    await getattr(gate, fn)(TROVE1_OWNER, TROVE_1, 0).execute(caller_address=MOCK_ABBOT_WITH_SENTINEL)

    # Get balance after
    after_yang_bal = (await shrine_authed.get_deposit(token.contract_address, TROVE_1).execute()).result.balance
    after_asset_bal = from_uint((await token.balanceOf(TROVE1_OWNER).execute()).result.balance)

    assert before_yang_bal == after_yang_bal
    assert before_asset_bal == after_asset_bal


#
# Tests - Tax
#


@pytest.mark.asyncio
async def test_gate_constructor_invalid_tax(starknet: Starknet, shrine, taxable_gate_contract, steth_token):
    with pytest.raises(StarkException):
        await starknet.deploy(
            contract_class=taxable_gate_contract,
            constructor_calldata=[
                MOCK_ABBOT_WITH_SENTINEL,
                shrine.contract_address,
                steth_token.contract_address,
                to_ray(TAX_MAX) + 1,
                TAX_COLLECTOR,
            ],
        )


@pytest.mark.parametrize("gate_info", ["steth_gate_taxable_info", "wbtc_gate_taxable_info"], indirect=["gate_info"])
@pytest.mark.asyncio
async def test_gate_set_tax_pass(gate_info):
    _, _, gate = gate_info

    tx = await gate.set_tax(TAX_RAY // 2).execute(caller_address=GATE_OWNER)
    assert_event_emitted(tx, gate.contract_address, "TaxUpdated", [TAX_RAY, TAX_RAY // 2])

    new_tax = (await gate.get_tax().execute()).result.tax
    assert new_tax == TAX_RAY // 2


@pytest.mark.parametrize("gate_info", ["steth_gate_taxable_info", "wbtc_gate_taxable_info"], indirect=["gate_info"])
@pytest.mark.asyncio
async def test_gate_set_tax_collector(gate_info):
    _, _, gate = gate_info

    new_tax_collector = 9876
    tx = await gate.set_tax_collector(new_tax_collector).execute(caller_address=GATE_OWNER)

    assert_event_emitted(
        tx,
        gate.contract_address,
        "TaxCollectorUpdated",
        [TAX_COLLECTOR, new_tax_collector],
    )

    res = (await gate.get_tax_collector().execute()).result.tax_collector
    assert res == new_tax_collector


@pytest.mark.parametrize("gate_info", ["steth_gate_taxable_info", "wbtc_gate_taxable_info"], indirect=["gate_info"])
@pytest.mark.asyncio
async def test_gate_set_tax_parameters_fail(gate_info):
    _, _, gate = gate_info

    # Fails due to max tax exceeded
    with pytest.raises(StarkException, match="Gate: Maximum tax exceeded"):
        await gate.set_tax(to_ray(TAX_MAX) + 1).execute(caller_address=GATE_OWNER)

    # Fails due to non-authorised address
    set_tax_role = GateRoles.SET_TAX
    with pytest.raises(StarkException, match=f"AccessControl: Caller is missing role {set_tax_role}"):
        await gate.set_tax(TAX_RAY).execute(caller_address=BAD_GUY)
        await gate.set_tax_collector(BAD_GUY).execute(caller_address=BAD_GUY)

    # Fails due to zero address
    with pytest.raises(StarkException, match="Gate: Invalid tax collector address"):
        await gate.set_tax_collector(ZERO_ADDRESS).execute(caller_address=GATE_OWNER)


@pytest.mark.usefixtures("trove_1_enter")
@pytest.mark.parametrize("gate_info", ["steth_gate_taxable_info", "wbtc_gate_taxable_info"], indirect=["gate_info"])
@pytest.mark.asyncio
async def test_gate_levy(shrine_authed, gate_info):
    token, decimals, gate = gate_info

    # Get balances before levy
    before_tax_collector_bal = from_uint((await token.balanceOf(TAX_COLLECTOR).execute()).result.balance)
    before_gate_bal = (await gate.get_total_assets().execute()).result.total

    # Update Gate's balance and charge tax
    levy = await gate.levy().execute(caller_address=MOCK_ABBOT_WITH_SENTINEL)
    levied_amt = to_fixed_point(FIRST_TAX_AMT, decimals)

    # Check Gate's managed assets and balance
    after_gate_bal = (await gate.get_total_assets().execute()).result.total
    assert after_gate_bal > before_gate_bal
    assert after_gate_bal == before_gate_bal * COMPOUND_MULTIPLIER - levied_amt

    # Check that user's withdrawable balance has increased
    user_yang = (await shrine_authed.get_deposit(token.contract_address, TROVE_1).execute()).result.balance
    expected_user_assets = (await gate.preview_exit(user_yang).execute()).result.asset_amt
    assert expected_user_assets == after_gate_bal

    # Check exchange rate
    asset_amt_per_yang = (await gate.get_asset_amt_per_yang().execute()).result.amt
    scaled_after_gate_bal = after_gate_bal * 10 ** (WAD_DECIMALS - decimals)
    expected_asset_amt_per_yang = int(scaled_after_gate_bal / from_wad(user_yang))
    assert asset_amt_per_yang == expected_asset_amt_per_yang

    # Check tax collector has received tax
    after_tax_collector_bal = from_uint((await token.balanceOf(TAX_COLLECTOR).execute()).result.balance)
    assert after_tax_collector_bal == before_tax_collector_bal + levied_amt

    # Event should be emitted if tax is successfully transferred to tax collector.
    assert_event_emitted(levy, gate.contract_address, "TaxLevied", [levied_amt])

    # Check balances before exit
    before_user_bal = from_uint((await token.balanceOf(TROVE1_OWNER).execute()).result.balance)

    # Exit
    await gate.exit(TROVE1_OWNER, TROVE_1, user_yang).execute(caller_address=MOCK_ABBOT_WITH_SENTINEL)
    await shrine_authed.withdraw(token.contract_address, TROVE_1, user_yang).execute(
        caller_address=MOCK_ABBOT_WITH_SENTINEL
    )

    # Get balances after exit
    after_user_bal = from_uint((await token.balanceOf(TROVE1_OWNER).execute()).result.balance)
    assert after_user_bal == before_user_bal + expected_user_assets
