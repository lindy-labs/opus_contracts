from decimal import Decimal
from typing import Optional, Union

import pytest
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.objects import StarknetCallInfo
from starkware.starkware_utils.error_handling import StarkException

from tests.absorber.constants import *  # noqa: F403
from tests.roles import AbsorberRoles
from tests.shrine.constants import FEED_LEN, MAX_PRICE_CHANGE, MULTIPLIER_FEED
from tests.utils import (
    ABSORBER_OWNER,
    BAD_GUY,
    DEPLOYMENT_TIMESTAMP,
    ERROR_MARGIN,
    FALSE,
    MAX_UINT256,
    RAY_SCALE,
    SHRINE_OWNER,
    TIME_INTERVAL,
    TRUE,
    WAD_RAY_OOB_VALUES,
    ZERO_ADDRESS,
    YangConfig,
    assert_equalish,
    assert_event_emitted,
    assert_event_not_emitted,
    calculate_max_forge,
    compile_code,
    compile_contract,
    create_feed,
    custom_error_margin,
    from_fixed_point,
    from_ray,
    from_uint,
    from_wad,
    get_block_timestamp,
    get_contract_code_with_addition,
    get_contract_code_with_replacement,
    get_token_balances,
    max_approve,
    set_block_timestamp,
    to_fixed_point,
    to_ray,
    to_uint,
    to_wad,
)

#
# Helpers
#


async def simulate_update(
    shrine: StarknetContract,
    absorber: StarknetContract,
    assets: tuple[StarknetContract],
    asset_addresses: list[int],
    asset_amts: list[int],
    yin_amt_to_burn_wad: int,
) -> StarknetCallInfo:
    """
    Helper to simulate `Absorber.update` by doing:
    1. Minting `asset_amts` of freed collateral to absorber
    2. Transferring `yin_amt_to_burn_wad` amount of yin from absorber

    Arguments
    ---------
    shrine: StarknetContract
        Contract instance of Shrine.
    absorber: StarknetContract
        Contract instance of Absorber.
    assets: tuple[StarknetContract]
        Ordered tuple of token contract instances for the freed assets
    asset_addresses: list[int]
        Ordered list of token contract addresses for the freed assets
    asset_amts: list[int]
        Ordered list of amount of each asset to transfer to the absorber in wad.
    yin_amt_to_burn_wad: int
        Amount of yin to transfer from the absorber in wad

    Returns
    -------
    A tuple of:
    1. the transaction receipt for `Absorber.update`
    2. an ordered list of the freed asset addresses
    3. an ordered list of the amount of assets freed in Decimal
    """
    for token, amt in zip(assets, asset_amts):
        amt_uint = to_uint(amt)
        await token.mint(absorber.contract_address, amt_uint).execute(caller_address=MOCK_PURGER)

    # Transfer yin from absorber to burner address to simulate `absorb`
    await absorber.burn_yin(BURNER, yin_amt_to_burn_wad).execute(caller_address=ABSORBER_OWNER)

    tx = await absorber.update(
        asset_addresses,
        asset_amts,
    ).execute(caller_address=MOCK_PURGER)

    return tx, asset_addresses, asset_amts


async def assert_provider_received_absorbed_assets(
    tx: StarknetCallInfo,
    absorber: StarknetContract,
    provider: int,
    absorbed_assets: tuple[StarknetContract],
    absorbed_assets_info: tuple[YangConfig],
    before_assets_balances: list[Decimal],
    absorbed_amts: list[Decimal],
    preview_amts_wad: list[int],
    skip_idx: Optional[int] = None,
):
    """
    Helper function to assert that:
    1. a provider has received the correct amount of absorbed assets;
    2. the absorbed assets emitted the `Transfer` event; and
    3. the previewed amount returned by `preview_reap` matches the amount received.

    Arguments
    ---------
    absorber: StarknetContract
        Contract instance of Absorber.
    provider: int
        Address of the provider.
    absorbed_ssets: tuple[StarknetContract]
        Ordered tuple of token contract instances for the absorbed assets
    absorbed_assets_info: tuple[StarknetContract]
        Ordered tuple of the absorbed assets token info
    before_assets_balances: list[Decimal]
        Ordered list of the provider's absorbed token balances before `reap`, in Decimal.
    absorbed_amts: list[Decimal]
        Ordered list of the expected amount of absorbed assets the provider should receive, in Decimal.
    preview_amts: list[int]
        Ordered list of the expected amount of absorbed tokens the provider is entitled to withdraw
        based on `preview_reap`, in the token's decimal precision.
    skip_idx: Optional[int]
        The index of an absorbed asset to skip tests for, if provided.
    """
    for idx, (asset_contract, asset_info, before_bal, absorbed_amt, preview_amt_wad) in enumerate(
        zip(absorbed_assets, absorbed_assets_info, before_assets_balances, absorbed_amts, preview_amts_wad)
    ):
        if skip_idx is not None and skip_idx == idx:
            continue

        assert_event_emitted(
            tx, asset_contract.contract_address, "Transfer", lambda d: d[:2] == [absorber.contract_address, provider]
        )

        after_provider_asset_bal = from_fixed_point(
            from_uint((await asset_contract.balanceOf(provider).execute()).result.balance), asset_info.decimals
        )

        # Relax error margin by half due to loss of precision from fixed point arithmetic
        error_margin = custom_error_margin(asset_info.decimals // 2 - 1)
        assert_equalish(after_provider_asset_bal, before_bal + absorbed_amt, error_margin)

        preview_amt = from_fixed_point(preview_amt_wad, asset_info.decimals)
        assert_equalish(absorbed_amt, preview_amt, error_margin)


async def assert_reward_errors_propagated_to_next_epoch(
    absorber: StarknetContract,
    reward_assets_addresses: list[int],
    epoch: int,
):
    """
    Helper function to assert that the errors of reward tokens in the current epoch are
    propagated to the next epoch, and the cumulative asset amount per share wad is 0.

    Arguments
    ---------
    absorber: StarknetContract
        Contract instance of Absorber.
    asset_addresses: list[int]
        Ordered list of token contract addresses for the rewards.
    epoch: int
        The epoch which error is to be propagated to the next epoch.
    """
    for asset_address in reward_assets_addresses:
        before_epoch_error = (await absorber.get_asset_reward_info(asset_address, epoch).execute()).result.info.error
        after_epoch_info = (await absorber.get_asset_reward_info(asset_address, epoch + 1).execute()).result.info

        assert after_epoch_info.error == before_epoch_error
        assert after_epoch_info.asset_amt_per_share == 0


async def assert_provider_received_rewards(
    tx: StarknetCallInfo,
    absorber: StarknetContract,
    provider: int,
    epoch: int,
    reward_assets: list[StarknetContract],
    before_balances: list[Decimal],
    base_blessing_amts: list[Decimal],
    blessings_multiplier: Union[int, Decimal],
    preview_amts: list[int],
    error_margin: Optional[Decimal] = ERROR_MARGIN,
):
    """
    Helper function to assert that:
    1. a provider has received the correct amount of reward tokens;
    2. the reward assets emitted the `Transfer` event;
    3 the previewed amount returned by `preview_reap` is correct; and
    4. a provider's last cumulative asset amount per share wad value is updated for all reward tokens.

    Arguments
    ---------
    absorber: StarknetContract
        Contract instance of Absorber.
    provider: int
        Address of the provider.
    epoch: int
        The latest epoch.
    asset_addresses: list[StarknetContract]
        Ordered list of the reward tokens contracts.
    before_balances: list[Decimal]
        Ordered list of the provider's reward token balances before receiving the rewards, in Decimal.
    base_blessing_amts: list[Decimal]
        Ordered list of the amount of reward token transferred to the absorber per blessing in Decimal.
    blessings_multiplier: Union[int, Decimal]
        The multiplier to apply to `base_blessing_amts_wad` when calculating the total amount the provider should
        receive.
    preview_amts: list[int]
        Ordered list of the expected amount of reward tokens the provider is entitled to withdraw
        based on `preview_reap`, in the token's decimal precision.
    error_margin: Optional[Decimal]
        The error margin to use, if provided.
    """

    for asset, before_bal, base_blessing_amt, preview_amt_wad in zip(
        reward_assets, before_balances, base_blessing_amts, preview_amts
    ):
        # Check reward token transfer and balance
        asset_address = asset.contract_address

        blessed_amt = blessings_multiplier * base_blessing_amt
        after_provider_asset_bal = from_wad(from_uint((await asset.balanceOf(provider).execute()).result.balance))
        assert_equalish(after_provider_asset_bal, before_bal + blessed_amt, error_margin)

        assert_event_emitted(tx, asset_address, "Transfer", lambda d: d[:2] == [absorber.contract_address, provider])

        # Check preview amounts
        preview_amt = from_wad(preview_amt_wad)
        assert_equalish(blessed_amt, preview_amt, error_margin)

        # Check provider's cumulative is updated
        provider_cumulative = (
            await absorber.get_provider_last_reward_cumulative(provider, asset_address).execute()
        ).result.cumulative
        current_cumulative = (
            await absorber.get_asset_reward_info(asset_address, epoch).execute()
        ).result.info.asset_amt_per_share

        assert provider_cumulative == current_cumulative


async def assert_reward_cumulative_updated(
    absorber: StarknetContract,
    reward_assets_addresses: list[int],
    blessed_amts: list[Decimal],
    epoch: int,
    total_shares_wad: int,
):
    """
    Helper function to assert that the cumulative of reward tokens are correctly updated after a blessing.

    Arguments
    ---------
    absorber: StarknetContract
        Contract instance of Absorber.
    reward_assets_addresses: list[int]
        Ordered list of token contract addresses for the rewards.
    blessed_amts_wad: list[Decimal]
        Ordered list of the total amount of reward token transferred to the absorber in Decimal.
    epoch: int
        The epoch which error is to be propagated to the next epoch.
    total_shares_wad: int
        The total number of shares in wadthat are entitled to the rewards.
    """
    for asset_address, blessed_amt in zip(reward_assets_addresses, blessed_amts):
        asset_blessing_info = (await absorber.get_asset_reward_info(asset_address, epoch).execute()).result.info
        actual_asset_amt_per_share = from_wad(asset_blessing_info.asset_amt_per_share)
        expected_asset_amt_per_share = blessed_amt / from_wad(total_shares_wad)
        assert_equalish(actual_asset_amt_per_share, expected_asset_amt_per_share)


#
# Fixtures
#


@pytest.fixture
async def first_update_assets(yangs) -> tuple[Union[list[int], list[Decimal]]]:
    """
    Helper fixture to return a tuple of:
    1. a list of asset addresses;
    2. a list of asset amounts in the asset's decimals
    3. a list of asset amounts in Decimal
    """
    asset_addresses = [asset_info.contract_address for asset_info in yangs]
    asset_amts = [
        to_fixed_point(i, asset_info.decimals)
        for i, asset_info in zip(
            FIRST_UPDATE_ASSETS_AMT,
            yangs,
        )
    ]
    return asset_addresses, asset_amts, FIRST_UPDATE_ASSETS_AMT


@pytest.fixture
async def second_update_assets(yangs) -> tuple[Union[list[int], list[Decimal]]]:
    """
    Helper fixture to return a tuple of:
    1. a list of asset addresses
    2. a list of asset amounts in the asset's decimals
    3. a list of asset amounts in Decimal
    """
    asset_addresses = [asset_info.contract_address for asset_info in yangs]
    asset_amts = [
        to_fixed_point(i, asset_info.decimals)
        for i, asset_info in zip(
            SECOND_UPDATE_ASSETS_AMT,
            yangs,
        )
    ]
    return asset_addresses, asset_amts, SECOND_UPDATE_ASSETS_AMT


@pytest.fixture
async def shrine(shrine_deploy) -> StarknetContract:
    # Update debt ceiling
    shrine = shrine_deploy
    await shrine.set_ceiling(DEBT_CEILING_WAD).execute(caller_address=SHRINE_OWNER)
    return shrine


@pytest.fixture
async def absorber_deploy(starknet, shrine, sentinel) -> StarknetContract:
    absorber_code = get_contract_code_with_replacement(
        "contracts/absorber/absorber.cairo",
        {
            "func convert_to_shares": "@view\nfunc convert_to_shares",
            "func convert_epoch_shares": "@view\nfunc convert_epoch_shares",
            "func get_shrine_ltv_to_threshold": "@view\nfunc get_shrine_ltv_to_threshold",
        },
    )

    # Helper function to simulate melting of absorber's yin in `Purger.absorb`
    additional_code = """
@external
func burn_yin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    dst: address, amt: wad
) {
    let shrine: address = absorber_shrine.read();
    let amt_uint: Uint256 = WadRay.to_uint(amt);
    IERC20.transfer(shrine, dst, amt_uint);

    return();
}
    """
    absorber_code = get_contract_code_with_addition(absorber_code, additional_code)
    absorber_contract = compile_code(absorber_code)
    absorber = await starknet.deploy(
        contract_class=absorber_contract,
        constructor_calldata=[
            ABSORBER_OWNER,
            shrine.contract_address,
            sentinel.contract_address,
            REMOVAL_LIMIT_RAY,
        ],
    )

    return absorber


@pytest.fixture
async def absorber(absorber_deploy) -> StarknetContract:
    absorber = absorber_deploy
    # Set purger in absorber
    await absorber.set_purger(MOCK_PURGER).execute(caller_address=ABSORBER_OWNER)
    await absorber.grant_role(AbsorberRoles.COMPENSATE | AbsorberRoles.UPDATE, MOCK_PURGER).execute(
        caller_address=ABSORBER_OWNER
    )
    return absorber


@pytest.fixture
async def absorber_killed(absorber) -> StarknetContract:
    await absorber.kill().execute(caller_address=ABSORBER_OWNER)
    return absorber


@pytest.fixture
def absorber_both(request) -> StarknetContract:
    """
    Wrapper fixture to pass the regular and killed instances of absorber to `pytest.parametrize`.
    """
    return request.getfixturevalue(request.param)


@pytest.fixture
async def aura_token_blesser(starknet, absorber, aura_token) -> StarknetContract:
    blesser_contract = compile_contract("tests/absorber/mock_blesser.cairo")
    blesser = await starknet.deploy(
        contract_class=blesser_contract,
        constructor_calldata=[
            BLESSER_OWNER,
            aura_token.contract_address,
            absorber.contract_address,
        ],
    )

    return blesser


@pytest.fixture
async def vested_aura_token_blesser(starknet, absorber, vested_aura_token) -> StarknetContract:
    blesser_code = get_contract_code_with_replacement(
        "tests/absorber/mock_blesser.cairo",
        {
            "1000 * WadRay.WAD_SCALE": f"{VESTED_AURA_BLESS_AMT} * WadRay.WAD_SCALE",
        },
    )
    blesser_contract = compile_code(blesser_code)
    blesser = await starknet.deploy(
        contract_class=blesser_contract,
        constructor_calldata=[
            BLESSER_OWNER,
            vested_aura_token.contract_address,
            absorber.contract_address,
        ],
    )

    return blesser


@pytest.fixture
async def shrine_feeds(starknet, sentinel_with_yangs, shrine, yangs) -> list[list[int]]:
    # Creating the price feeds
    feeds = [create_feed(from_wad(yang.price_wad), FEED_LEN, MAX_PRICE_CHANGE) for yang in yangs]

    # Putting the price feeds in the `shrine_yang_price_storage` storage variable
    for i in range(FEED_LEN):
        timestamp = DEPLOYMENT_TIMESTAMP + i * TIME_INTERVAL
        set_block_timestamp(starknet, timestamp)

        for j in range(len(yangs)):
            await shrine.advance(yangs[j].contract_address, feeds[j][i]).execute(caller_address=SHRINE_OWNER)

        await shrine.set_multiplier(MULTIPLIER_FEED[i]).execute(caller_address=SHRINE_OWNER)

    return feeds


@pytest.fixture
async def funded_absorber_providers(shrine, shrine_feeds, abbot, absorber, steth_token, steth_yang: YangConfig):
    troves = [PROVIDER_1_TROVE, PROVIDER_2_TROVE]
    trove_owners = [PROVIDER_1, PROVIDER_2]

    for trove, owner in zip(troves, trove_owners):
        await steth_token.mint(owner, to_uint(PROVIDER_STETH_DEPOSIT_WAD)).execute(caller_address=owner)
        await max_approve(steth_token, owner, steth_yang.gate_address)

        steth_price = from_wad(
            (await shrine.get_current_yang_price(steth_yang.contract_address).execute()).result.price
        )

        max_forge_amt = calculate_max_forge(
            [steth_price], [from_wad(PROVIDER_STETH_DEPOSIT_WAD)], [from_ray(steth_yang.threshold)]
        )
        forge_amt = to_wad(max_forge_amt / 2)

        await abbot.open_trove(
            forge_amt,
            [steth_yang.contract_address],
            [PROVIDER_STETH_DEPOSIT_WAD],
        ).execute(caller_address=owner)

        await max_approve(shrine, owner, absorber.contract_address)


@pytest.fixture
async def first_epoch_first_provider(shrine, absorber, funded_absorber_providers) -> tuple[StarknetCallInfo, int]:
    provider = PROVIDER_1
    provider_yin_amt_uint = (await shrine.balanceOf(provider).execute()).result.balance
    provider_yin_amt = int(from_uint(provider_yin_amt_uint) / Decimal("3.5"))

    tx = await absorber.provide(provider_yin_amt).execute(caller_address=provider)
    return tx, provider_yin_amt


@pytest.fixture
async def first_epoch_second_provider(shrine, absorber, funded_absorber_providers) -> tuple[StarknetCallInfo, int]:
    provider = PROVIDER_2
    provider_yin_amt_uint = (await shrine.balanceOf(provider).execute()).result.balance
    provider_yin_amt = from_uint(provider_yin_amt_uint)

    tx = await absorber.provide(provider_yin_amt).execute(caller_address=provider)
    return tx, provider_yin_amt


@pytest.fixture
async def update(
    request, shrine, absorber, yang_tokens, first_update_assets
) -> tuple[StarknetCallInfo, Decimal, int, int, int, list[int], list[int], list[Decimal]]:
    """
    Fixture that takes in a Decimal value for the percentage of the absorber's yin balance to drain
    to simulate an absorption.
    """
    percentage_to_drain = request.param

    # Fetch the total shares and epoch beforehand because it will be reset
    # if percentage to drain is 100%
    total_shares_wad = (await absorber.get_total_shares_for_current_epoch().execute()).result.total
    epoch = (await absorber.get_current_epoch().execute()).result.epoch

    # Transfer yin from absorber to burner address to simulate `absorb`
    absorber_yin_bal_wad = from_uint((await shrine.balanceOf(absorber.contract_address).execute()).result.balance)
    burn_amt_wad = int(percentage_to_drain * Decimal(absorber_yin_bal_wad))

    # Call `update`
    asset_addresses, asset_amts, asset_amts_dec = first_update_assets
    tx, asset_addresses, asset_amts = await simulate_update(
        shrine,
        absorber,
        yang_tokens,
        asset_addresses,
        asset_amts,
        burn_amt_wad,
    )

    remaining_amt_wad = absorber_yin_bal_wad - burn_amt_wad
    return (
        tx,
        percentage_to_drain,
        remaining_amt_wad,
        epoch,
        total_shares_wad,
        asset_addresses,
        asset_amts,
        asset_amts_dec,
    )


@pytest.fixture
async def add_aura_reward(absorber, aura_token, aura_token_blesser) -> StarknetCallInfo:
    tx = await absorber.set_reward(
        aura_token.contract_address,
        aura_token_blesser.contract_address,
        TRUE,
    ).execute(caller_address=ABSORBER_OWNER)

    # Mint tokens to blesser contract
    vesting_amt = to_uint(to_wad(AURA_BLESSER_STARTING_BAL))
    await aura_token.mint(aura_token_blesser.contract_address, vesting_amt).execute(caller_address=BLESSER_OWNER)

    return tx


@pytest.fixture
async def add_vested_aura_reward(absorber, vested_aura_token, vested_aura_token_blesser) -> StarknetCallInfo:
    tx = await absorber.set_reward(
        vested_aura_token.contract_address,
        vested_aura_token_blesser.contract_address,
        TRUE,
    ).execute(caller_address=ABSORBER_OWNER)

    # Mint tokens to blesser contract
    vesting_amt = to_uint(to_wad(VESTED_AURA_BLESSER_STARTING_BAL))
    await vested_aura_token.mint(vested_aura_token_blesser.contract_address, vesting_amt).execute(
        caller_address=BLESSER_OWNER
    )

    return tx


@pytest.fixture
async def blessing(aura_token, vested_aura_token) -> tuple[list[StarknetContract], list[int], list[int], list[Decimal]]:
    """
    Helper fixture for tests related to rewards.

    Returns a tuple of
    1. an ordered list of the reward tokens
    2. an ordered list of the reward tokens addresses
    3. an ordered list of the amount distributed by the Blesser to the Absorber per distribution in
       each token's decimal precision
    4. an ordered list of (4) in Decimal
    """
    reward_assets = [aura_token, vested_aura_token]
    reward_assets_addresses = [asset.contract_address for asset in reward_assets]
    expected_asset_amts = [AURA_BLESS_AMT_WAD, VESTED_AURA_BLESS_AMT_WAD]
    expected_asset_amts_dec = [from_wad(i) for i in expected_asset_amts]
    return reward_assets, reward_assets_addresses, expected_asset_amts, expected_asset_amts_dec


@pytest.fixture
async def first_provider_request(starknet, absorber):
    await absorber.request().execute(caller_address=PROVIDER_1)

    current_timestamp = get_block_timestamp(starknet)
    new_timestamp = current_timestamp + REQUEST_BASE_TIMELOCK_SECONDS
    set_block_timestamp(starknet, new_timestamp)


#
# Tests - Setup and admin functions
#


@pytest.mark.asyncio
async def test_absorber_setup(shrine, absorber):
    purger_address = (await absorber.get_purger().execute()).result.purger
    assert purger_address == MOCK_PURGER

    shares = (await absorber.get_total_shares_for_current_epoch().execute()).result.total
    assert shares == 0

    epoch = (await absorber.get_current_epoch().execute()).result.epoch
    assert epoch == 0

    absorptions_count = (await absorber.get_absorptions_count().execute()).result.count
    assert absorptions_count == 0

    rewards_count = (await absorber.get_rewards_count().execute()).result.count
    assert rewards_count == 0

    rewards = (await absorber.get_rewards().execute()).result.rewards
    rewards == []

    limit = (await absorber.get_removal_limit().execute()).result.limit
    assert limit == REMOVAL_LIMIT_RAY

    is_live = (await absorber.get_live().execute()).result.is_live
    assert is_live == TRUE

    admin_role = (await absorber.get_roles(ABSORBER_OWNER).execute()).result.roles
    assert (
        admin_role
        == AbsorberRoles.KILL + AbsorberRoles.SET_PURGER + AbsorberRoles.SET_REMOVAL_LIMIT + AbsorberRoles.SET_REWARD
    )


@pytest.mark.asyncio
async def test_set_purger(shrine, absorber):
    old_purger = (await absorber.get_purger().execute()).result.purger
    new_purger = NEW_MOCK_PURGER

    tx = await absorber.set_purger(NEW_MOCK_PURGER).execute(caller_address=ABSORBER_OWNER)

    assert_event_emitted(tx, absorber.contract_address, "PurgerUpdated", [old_purger, new_purger])

    purger = (await absorber.get_purger().execute()).result.purger
    assert purger == new_purger

    old_purger_allowance = from_uint(
        (await shrine.allowance(absorber.contract_address, old_purger).execute()).result.allowance
    )
    assert old_purger_allowance == 0

    new_purger_allowance = (await shrine.allowance(absorber.contract_address, new_purger).execute()).result.allowance
    assert new_purger_allowance == MAX_UINT256


@pytest.mark.asyncio
async def test_set_purger_unauthorized_fail(shrine, absorber):
    with pytest.raises(StarkException, match=f"AccessControl: Caller is missing role {AbsorberRoles.SET_PURGER}"):
        new_purger = NEW_MOCK_PURGER
        await absorber.set_purger(new_purger).execute(caller_address=BAD_GUY)


@pytest.mark.parametrize("limit", [MIN_REMOVAL_LIMIT_RAY, RAY_SCALE, RAY_SCALE + 1])
@pytest.mark.asyncio
async def test_set_removal_limit_pass(absorber, limit):
    tx = await absorber.set_removal_limit(limit).execute(caller_address=ABSORBER_OWNER)

    old_limit = REMOVAL_LIMIT_RAY
    assert_event_emitted(tx, absorber.contract_address, "RemovalLimitUpdated", [old_limit, limit])

    assert (await absorber.get_removal_limit().execute()).result.limit == limit


@pytest.mark.parametrize("invalid_limit", [0, MIN_REMOVAL_LIMIT_RAY - 1])
@pytest.mark.asyncio
async def test_set_removal_limit_too_low_fail(absorber, invalid_limit):
    with pytest.raises(StarkException, match="Absorber: Limit is too low"):
        await absorber.set_removal_limit(invalid_limit).execute(caller_address=ABSORBER_OWNER)


@pytest.mark.parametrize("amt", WAD_RAY_OOB_VALUES)
@pytest.mark.asyncio
async def test_set_removal_limit_oob_fail(absorber, amt):
    with pytest.raises(StarkException, match=r"Absorber: Value of `limit` \(-?\d+\) is out of bounds"):
        await absorber.set_removal_limit(amt).execute(caller_address=ABSORBER_OWNER)


@pytest.mark.asyncio
async def test_set_removal_limit_unauthorized_fail(shrine, absorber):
    with pytest.raises(
        StarkException, match=f"AccessControl: Caller is missing role {AbsorberRoles.SET_REMOVAL_LIMIT}"
    ):
        new_limit = to_ray(Decimal("0.7"))
        await absorber.set_removal_limit(new_limit).execute(caller_address=BAD_GUY)


@pytest.mark.asyncio
async def test_set_purger_zero_address_fail(absorber_deploy):
    absorber = absorber_deploy
    with pytest.raises(StarkException, match="Absorber: Purger address cannot be zero"):
        await absorber.set_purger(ZERO_ADDRESS).execute(caller_address=ABSORBER_OWNER)


@pytest.mark.asyncio
async def test_kill(absorber):
    tx = await absorber.kill().execute(caller_address=ABSORBER_OWNER)

    assert_event_emitted(tx, absorber.contract_address, "Killed")

    is_live = (await absorber.get_live().execute()).result.is_live
    assert is_live == FALSE

    provider = PROVIDER_1
    provide_amt = 1
    with pytest.raises(StarkException, match="Absorber: Absorber is not live"):
        await absorber.provide(provide_amt).execute(caller_address=provider)


@pytest.mark.asyncio
async def test_kill_unauthorized_fail(absorber):
    with pytest.raises(StarkException, match=f"AccessControl: Caller is missing role {AbsorberRoles.KILL}"):
        await absorber.kill().execute(caller_address=BAD_GUY)


@pytest.mark.asyncio
async def test_set_reward_pass(
    absorber, aura_token, vested_aura_token, aura_token_blesser, vested_aura_token_blesser, add_aura_reward
):
    assert_event_emitted(
        add_aura_reward,
        absorber.contract_address,
        "RewardSet",
        [aura_token.contract_address, aura_token_blesser.contract_address, TRUE],
    )

    rewards_count = (await absorber.get_rewards_count().execute()).result.count
    assert rewards_count == 1

    rewards = (await absorber.get_rewards().execute()).result.rewards
    assert rewards == [(aura_token.contract_address, aura_token_blesser.contract_address, TRUE)]

    # Add another reward
    tx = await absorber.set_reward(
        vested_aura_token.contract_address,
        vested_aura_token_blesser.contract_address,
        FALSE,
    ).execute(caller_address=ABSORBER_OWNER)

    assert_event_emitted(
        tx,
        absorber.contract_address,
        "RewardSet",
        [vested_aura_token.contract_address, vested_aura_token_blesser.contract_address, FALSE],
    )

    rewards_count = (await absorber.get_rewards_count().execute()).result.count
    assert rewards_count == 2

    rewards = (await absorber.get_rewards().execute()).result.rewards
    assert rewards == [
        (aura_token.contract_address, aura_token_blesser.contract_address, TRUE),
        (vested_aura_token.contract_address, vested_aura_token_blesser.contract_address, FALSE),
    ]

    # Update existing reward
    tx = await absorber.set_reward(
        aura_token.contract_address,
        aura_token_blesser.contract_address,
        FALSE,
    ).execute(caller_address=ABSORBER_OWNER)

    rewards = (await absorber.get_rewards().execute()).result.rewards
    assert rewards == [
        (aura_token.contract_address, aura_token_blesser.contract_address, FALSE),
        (vested_aura_token.contract_address, vested_aura_token_blesser.contract_address, FALSE),
    ]


@pytest.mark.asyncio
async def test_set_reward_fail(absorber, aura_token, aura_token_blesser):
    # zero address
    with pytest.raises(StarkException, match="Absorber: Address cannot be zero"):
        await absorber.set_reward(
            ZERO_ADDRESS,
            aura_token_blesser.contract_address,
            TRUE,
        ).execute(caller_address=ABSORBER_OWNER)

    with pytest.raises(StarkException, match="Absorber: Address cannot be zero"):
        await absorber.set_reward(
            aura_token.contract_address,
            ZERO_ADDRESS,
            TRUE,
        ).execute(caller_address=ABSORBER_OWNER)

    # unauthorized
    with pytest.raises(StarkException, match=f"AccessControl: Caller is missing role {AbsorberRoles.SET_REWARD}"):
        await absorber.set_reward(
            aura_token.contract_address,
            aura_token_blesser.contract_address,
            TRUE,
        ).execute(caller_address=BAD_GUY)


#
# Tests - Update, compensate
#


@pytest.mark.parametrize("absorber_both", ["absorber", "absorber_killed"], indirect=["absorber_both"])
@pytest.mark.usefixtures("add_aura_reward", "add_vested_aura_reward", "first_epoch_first_provider")
@pytest.mark.parametrize("update", [Decimal("0.2"), Decimal("1")], indirect=["update"])
@pytest.mark.asyncio
async def test_update(shrine, absorber_both, update, yangs, yang_tokens, blessing):
    absorber = absorber_both

    (
        tx,
        percentage_drained,
        _,
        before_epoch,
        before_total_shares_wad,
        absorbed_assets,
        absorbed_amts,
        absorbed_amts_dec,
    ) = update
    is_drained = True if percentage_drained >= Decimal("1") else False

    reward_assets, reward_assets_addresses, blessing_amts, blessing_amts_dec = blessing

    expected_gain_epoch = 0
    expected_absorption_id = 1

    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Gain",
        [
            len(absorbed_assets),
            *absorbed_assets,
            len(absorbed_assets),
            *absorbed_amts,
            before_total_shares_wad,
            expected_gain_epoch,
            expected_absorption_id,
        ],
    )

    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Bestow",
        [
            len(reward_assets_addresses),
            *reward_assets_addresses,
            len(blessing_amts),
            *blessing_amts,
            before_total_shares_wad,
            expected_gain_epoch,
        ],
    )

    actual_absorption_id = (await absorber.get_absorptions_count().execute()).result.count
    assert actual_absorption_id == expected_absorption_id

    for asset, amt in zip(yangs, absorbed_amts_dec):
        asset_address = asset.contract_address
        asset_absorption_info = (
            await absorber.get_asset_absorption_info(asset_address, expected_absorption_id).execute()
        ).result.info
        actual_asset_amt_per_share = from_fixed_point(asset_absorption_info.asset_amt_per_share, asset.decimals)

        expected_asset_amt_per_share = Decimal(amt) / from_wad(before_total_shares_wad)

        error_margin = custom_error_margin(asset.decimals)
        assert_equalish(actual_asset_amt_per_share, expected_asset_amt_per_share, error_margin)

    if is_drained:
        current_epoch = (await absorber.get_current_epoch().execute()).result.epoch
        assert current_epoch == before_epoch + 1

        after_total_shares_wad = (await absorber.get_total_shares_for_current_epoch().execute()).result.total
        assert after_total_shares_wad == 0

        assert_event_emitted(tx, absorber.contract_address, "EpochChanged", [before_epoch, current_epoch])

    await assert_reward_cumulative_updated(
        absorber, reward_assets_addresses, blessing_amts_dec, before_epoch, before_total_shares_wad
    )


@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.asyncio
async def test_unauthorized_update(absorber, first_update_assets):
    asset_addresses, asset_amts, _ = first_update_assets
    with pytest.raises(StarkException, match=r"AccessControl: Caller is missing role \d+"):
        await absorber.update(asset_addresses, asset_amts).execute(caller_address=BAD_GUY)


@pytest.mark.asyncio
async def test_unauthorized_compensate(absorber, first_update_assets):
    asset_addresses, asset_amts, _ = first_update_assets
    with pytest.raises(StarkException, match=r"AccessControl: Caller is missing role \d+"):
        await absorber.compensate(BAD_GUY, asset_addresses, asset_amts).execute(caller_address=BAD_GUY)


#
# Tests - Provider functions (provide, request, remove, reap)
#


@pytest.mark.usefixtures("add_aura_reward", "add_vested_aura_reward")
@pytest.mark.asyncio
async def test_provide_first_epoch(shrine, absorber, first_epoch_first_provider, blessing):
    provider = PROVIDER_1

    tx, initial_yin_amt_provided = first_epoch_first_provider
    reward_assets, reward_assets_addresses, _, blessing_amts_dec = blessing

    before_provider_info = (await absorber.get_provider_info(provider).execute()).result.provision
    before_provider_last_absorption = (
        await absorber.get_provider_last_absorption(provider).execute()
    ).result.absorption_id
    before_provider_reward_bals = (await get_token_balances(reward_assets, [provider]))[0]
    before_total_shares_wad = (await absorber.get_total_shares_for_current_epoch().execute()).result.total

    assert before_provider_info.shares + INITIAL_SHARES_WAD == before_total_shares_wad == initial_yin_amt_provided

    expected_epoch = 0
    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Provide",
        [provider, expected_epoch, initial_yin_amt_provided],
    )

    before_absorber_yin_bal_wad = from_uint(
        (await shrine.balanceOf(absorber.contract_address).execute()).result.balance
    )
    assert before_absorber_yin_bal_wad == initial_yin_amt_provided

    reap_info = (await absorber.preview_reap(provider).execute()).result

    # Test subsequent deposit
    subsequent_yin_amt_to_provide_uint = (await shrine.balanceOf(provider).execute()).result.balance
    subsequent_yin_amt_to_provide = from_uint(subsequent_yin_amt_to_provide_uint)

    tx = await absorber.provide(subsequent_yin_amt_to_provide).execute(caller_address=provider)

    expected_new_shares_wad = subsequent_yin_amt_to_provide
    after_provider_info = (await absorber.get_provider_info(provider).execute()).result.provision
    expected_provider_shares = from_wad(before_provider_info.shares + expected_new_shares_wad)
    assert_equalish(from_wad(after_provider_info.shares), expected_provider_shares)
    assert after_provider_info.epoch == before_provider_info.epoch

    after_provider_last_absorption = (
        await absorber.get_provider_last_absorption(provider).execute()
    ).result.absorption_id
    assert after_provider_last_absorption == before_provider_last_absorption

    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Provide",
        [provider, expected_epoch, subsequent_yin_amt_to_provide],
    )

    after_total_shares = from_wad((await absorber.get_total_shares_for_current_epoch().execute()).result.total)
    expected_new_total = from_wad(before_total_shares_wad + expected_new_shares_wad)
    assert_equalish(after_total_shares, expected_new_total)

    after_absorber_yin_bal_wad = from_uint((await shrine.balanceOf(absorber.contract_address).execute()).result.balance)
    assert after_absorber_yin_bal_wad == before_absorber_yin_bal_wad + subsequent_yin_amt_to_provide

    await assert_reward_cumulative_updated(
        absorber, reward_assets_addresses, blessing_amts_dec, expected_epoch, before_total_shares_wad
    )

    blessings_multiplier = 1
    await assert_provider_received_rewards(
        tx,
        absorber,
        provider,
        expected_epoch,
        reward_assets,
        before_provider_reward_bals,
        blessing_amts_dec,
        blessings_multiplier,
        reap_info.reward_asset_amts,
    )


@pytest.mark.parametrize("absorber_both", ["absorber", "absorber_killed"], indirect=["absorber_both"])
@pytest.mark.usefixtures("add_aura_reward", "add_vested_aura_reward", "first_epoch_first_provider")
@pytest.mark.parametrize("update", [Decimal("0.2"), Decimal("1")], indirect=["update"])
@pytest.mark.asyncio
async def test_reap_pass(shrine, absorber_both, update, yangs, yang_tokens, blessing):
    absorber = absorber_both

    provider = PROVIDER_1

    _, percentage_drained, _, before_epoch, _, absorbed_assets, _, absorbed_amts_dec = update
    is_drained = True if percentage_drained >= Decimal("1") else False

    reward_assets, reward_assets_addresses, blessing_amts, blessing_amts_dec = blessing

    reap_info = (await absorber.preview_reap(provider).execute()).result
    assert reap_info.absorbed_assets == absorbed_assets
    assert reap_info.reward_assets == reward_assets_addresses

    # Fetch user balances before `reap`
    before_provider_absorbed_bals = (await get_token_balances(yang_tokens, [provider]))[0]
    before_provider_reward_bals = (await get_token_balances(reward_assets, [provider]))[0]
    before_provider_last_absorption = (
        await absorber.get_provider_last_absorption(provider).execute()
    ).result.absorption_id
    before_total_shares_wad = (await absorber.get_total_shares_for_current_epoch().execute()).result.total

    tx = await absorber.reap().execute(caller_address=provider)

    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Reap",
        lambda d: d[:5] == [provider, len(absorbed_assets), *absorbed_assets]
        and d[9:12] == [len(reward_assets_addresses), *reward_assets_addresses],
    )

    await assert_provider_received_absorbed_assets(
        tx,
        absorber,
        provider,
        yang_tokens,
        yangs,
        before_provider_absorbed_bals,
        absorbed_amts_dec,
        reap_info.absorbed_asset_amts,
    )

    after_provider_last_absorption = (
        await absorber.get_provider_last_absorption(provider).execute()
    ).result.absorption_id
    assert after_provider_last_absorption == before_provider_last_absorption + 1

    blessings_multiplier = 1
    # Assert `Bestow` is emitted if absorber is not completely drained
    if is_drained:
        expected_epoch = 1
        after_provider_info = (await absorber.get_provider_info(provider).execute()).result.provision
        assert after_provider_info.epoch == expected_epoch
        assert after_provider_info.shares == 0

        assert_event_not_emitted(tx, absorber.contract_address, "Bestow")
    else:
        expected_epoch = 0
        assert_event_emitted(
            tx,
            absorber.contract_address,
            "Bestow",
            [
                len(reward_assets_addresses),
                *reward_assets_addresses,
                len(blessing_amts),
                *blessing_amts,
                before_total_shares_wad,
                expected_epoch,
            ],
        )

        blessings_multiplier += 1

    await assert_provider_received_rewards(
        tx,
        absorber,
        provider,
        expected_epoch,
        reward_assets,
        before_provider_reward_bals,
        blessing_amts_dec,
        blessings_multiplier,
        reap_info.reward_asset_amts,
    )

    # Provider should not receive rewards twice
    if is_drained:
        with pytest.raises(StarkException, match="Absorber: Caller is not a provider in the current epoch"):
            await absorber.reap().execute(caller_address=provider)

        await assert_reward_errors_propagated_to_next_epoch(absorber, reward_assets_addresses, before_epoch)

    else:
        reap_info = (await absorber.preview_reap(provider).execute()).result

        after_reward_bals = (await get_token_balances(reward_assets, [provider]))[0]

        await absorber.reap().execute(caller_address=provider)

        blessings_multiplier = 1
        await assert_provider_received_rewards(
            tx,
            absorber,
            provider,
            expected_epoch,
            reward_assets,
            after_reward_bals,
            blessing_amts_dec,
            blessings_multiplier,
            reap_info.reward_asset_amts,
        )


@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.asyncio
async def test_request_pass(starknet, absorber):
    provider = PROVIDER_1

    expected_timelock = REQUEST_BASE_TIMELOCK_SECONDS
    for i in range(6):
        current_timestamp = get_block_timestamp(starknet)
        tx = await absorber.request().execute(caller_address=provider)

        if expected_timelock > REQUEST_MAX_TIMELOCK_SECONDS:
            expected_timelock = REQUEST_MAX_TIMELOCK_SECONDS

        assert_event_emitted(
            tx, absorber.contract_address, "RequestSubmitted", [provider, current_timestamp, expected_timelock]
        )

        request = (await absorber.get_provider_request(provider).execute()).result.request
        assert request.timestamp == current_timestamp
        assert request.timelock == expected_timelock

        # Timelock has not elapsed
        with pytest.raises(StarkException, match="Absorber: Request is not valid yet"):
            await absorber.remove(1).execute(caller_address=provider)

        set_block_timestamp(starknet, current_timestamp + expected_timelock - 1)
        with pytest.raises(StarkException, match="Absorber: Request is not valid yet"):
            await absorber.remove(1).execute(caller_address=provider)

        # Request has expired
        removal_start_timestamp = current_timestamp + expected_timelock
        expiry_timestamp = removal_start_timestamp + REQUEST_VALIDITY_PERIOD_SECONDS + 1
        set_block_timestamp(starknet, expiry_timestamp)
        with pytest.raises(StarkException, match="Absorber: Request has expired"):
            await absorber.remove(1).execute(caller_address=provider)

        # Time-travel back so that request is now valid
        set_block_timestamp(starknet, removal_start_timestamp)
        await absorber.remove(1).execute(caller_address=provider)

        request = (await absorber.get_provider_request(provider).execute()).result.request
        assert request.has_removed == TRUE

        # Only one removal per request
        with pytest.raises(StarkException, match="Absorber: Only one removal per request"):
            await absorber.remove(1).execute(caller_address=provider)

        expected_timelock *= REQUEST_TIMELOCK_MULTIPLIER


@pytest.mark.parametrize("absorber_both", ["absorber", "absorber_killed"], indirect=["absorber_both"])
@pytest.mark.parametrize("update", [Decimal("0"), Decimal("0.2"), Decimal("1")], indirect=["update"])
@pytest.mark.parametrize("percentage_to_remove", [Decimal("0"), Decimal("0.25"), Decimal("0.667"), Decimal("1")])
@pytest.mark.parametrize("seconds_since_request", [REQUEST_BASE_TIMELOCK_SECONDS, REQUEST_VALIDITY_PERIOD_SECONDS])
@pytest.mark.usefixtures("add_aura_reward", "add_vested_aura_reward", "first_epoch_first_provider")
@pytest.mark.asyncio
async def test_remove(
    starknet,
    shrine,
    absorber_both,
    update,
    yangs,
    yang_tokens,
    percentage_to_remove,
    seconds_since_request,
    blessing,
):
    absorber = absorber_both

    provider = PROVIDER_1

    _, percentage_drained, _, _, total_shares_wad, absorbed_assets_addresses, _, absorbed_amts_dec = update
    is_drained = True if percentage_drained >= Decimal("1") else False

    reward_assets, reward_assets_addresses, blessing_amts, blessing_amts_dec = blessing

    await absorber.request().execute(caller_address=provider)

    request_timestamp = get_block_timestamp(starknet)
    new_timestamp = request_timestamp + seconds_since_request
    set_block_timestamp(starknet, new_timestamp)

    before_provider_yin_bal = from_wad(from_uint((await shrine.balanceOf(provider).execute()).result.balance))
    before_provider_info = (await absorber.get_provider_info(provider).execute()).result.provision
    before_provider_last_absorption = (
        await absorber.get_provider_last_absorption(provider).execute()
    ).result.absorption_id
    before_provider_absorbed_bals = (await get_token_balances(yang_tokens, [provider]))[0]
    before_provider_reward_bals = (await get_token_balances(reward_assets, [provider]))[0]
    before_absorber_yin_bal_wad = from_uint(
        (await shrine.balanceOf(absorber.contract_address).execute()).result.balance
    )

    if is_drained:
        yin_to_remove_wad = 0
        expected_shares = Decimal("0")
        expected_epoch = before_provider_info.epoch + 1
        blessings_multiplier = 1

    else:
        max_removable_yin = (await absorber.preview_remove(provider).execute()).result.amount
        yin_to_remove_wad = int(percentage_to_remove * max_removable_yin)
        expected_shares_removed = from_wad(
            (await absorber.convert_to_shares(yin_to_remove_wad, TRUE).execute()).result.provider_shares
        )
        expected_shares = from_wad(before_provider_info.shares) - expected_shares_removed
        expected_epoch = before_provider_info.epoch
        blessings_multiplier = 2

    reap_info = (await absorber.preview_reap(provider).execute()).result

    tx = await absorber.remove(yin_to_remove_wad).execute(caller_address=provider)

    after_provider_yin_bal = from_wad(from_uint((await shrine.balanceOf(provider).execute()).result.balance))
    expected_provider_yin_bal = before_provider_yin_bal + from_wad(yin_to_remove_wad)
    assert_equalish(after_provider_yin_bal, expected_provider_yin_bal)

    after_provider_info = (await absorber.get_provider_info(provider).execute()).result.provision
    assert_equalish(from_wad(after_provider_info.shares), expected_shares)
    assert after_provider_info.epoch == expected_epoch

    after_provider_last_absorption = (
        await absorber.get_provider_last_absorption(provider).execute()
    ).result.absorption_id
    assert after_provider_last_absorption == before_provider_last_absorption + 1

    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Remove",
        lambda d: d[:3] == [provider, expected_epoch, yin_to_remove_wad],
    )

    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Reap",
        lambda d: d[:5] == [provider, len(absorbed_assets_addresses), *absorbed_assets_addresses]
        and d[9:12] == [len(reward_assets_addresses), *reward_assets_addresses],
    )

    if is_drained:
        assert_event_not_emitted(tx, absorber.contract_address, "Bestow")
    else:
        expected_bestow_epoch = before_provider_info.epoch
        assert_event_emitted(
            tx,
            absorber.contract_address,
            "Bestow",
            [
                len(reward_assets_addresses),
                *reward_assets_addresses,
                len(blessing_amts),
                *blessing_amts,
                total_shares_wad,
                expected_bestow_epoch,
            ],
        )

    assert_provider_received_absorbed_assets(
        tx,
        absorber,
        provider,
        yang_tokens,
        yangs,
        before_provider_absorbed_bals,
        absorbed_amts_dec,
        reap_info.absorbed_asset_amts,
    )

    after_absorber_yin_bal_wad = from_uint((await shrine.balanceOf(absorber.contract_address).execute()).result.balance)
    assert after_absorber_yin_bal_wad == before_absorber_yin_bal_wad - yin_to_remove_wad

    await assert_provider_received_rewards(
        tx,
        absorber,
        provider,
        expected_epoch,
        reward_assets,
        before_provider_reward_bals,
        blessing_amts_dec,
        blessings_multiplier,
        reap_info.reward_asset_amts,
    )

    request = (await absorber.get_provider_request(provider).execute()).result.request
    assert request.has_removed == TRUE


@pytest.mark.parametrize("update", [Decimal("1")], indirect=["update"])
@pytest.mark.usefixtures("add_aura_reward", "add_vested_aura_reward", "first_epoch_first_provider")
@pytest.mark.asyncio
async def test_provide_second_epoch(shrine, absorber, update, yangs, yang_tokens, blessing):
    # Epoch and total shares are already checked in `test_update` so we do not repeat here
    provider = PROVIDER_1

    _, _, _, before_epoch, _, _, _, absorbed_amts_dec = update
    reward_assets, reward_assets_addresses, blessing_amts, blessing_amts_dec = blessing

    yin_amt_to_provide_uint = (await shrine.balanceOf(provider).execute()).result.balance
    yin_amt_to_provide_wad = from_uint(yin_amt_to_provide_uint)
    before_provider_absorbed_bals = (await get_token_balances(yang_tokens, [provider]))[0]
    before_provider_reward_bals = (await get_token_balances(reward_assets, [provider]))[0]

    reap_info = (await absorber.preview_reap(provider).execute()).result

    tx = await absorber.provide(yin_amt_to_provide_wad).execute(caller_address=provider)

    total_shares_wad = (await absorber.get_total_shares_for_current_epoch().execute()).result.total
    provider_info = (await absorber.get_provider_info(provider).execute()).result.provision
    assert provider_info.shares + INITIAL_SHARES_WAD == total_shares_wad == yin_amt_to_provide_wad

    expected_epoch = 1
    assert provider_info.epoch == expected_epoch

    provider_last_absorption = (await absorber.get_provider_last_absorption(provider).execute()).result.absorption_id
    expected_absorption_id = 1
    assert provider_last_absorption == expected_absorption_id

    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Provide",
        [provider, expected_epoch, yin_amt_to_provide_wad],
    )

    await assert_provider_received_absorbed_assets(
        tx,
        absorber,
        provider,
        yang_tokens,
        yangs,
        before_provider_absorbed_bals,
        absorbed_amts_dec,
        reap_info.absorbed_asset_amts,
    )

    blessings_multiplier = 1
    await assert_provider_received_rewards(
        tx,
        absorber,
        provider,
        expected_epoch,
        reward_assets,
        before_provider_reward_bals,
        blessing_amts_dec,
        blessings_multiplier,
        reap_info.reward_asset_amts,
    )

    await assert_reward_errors_propagated_to_next_epoch(absorber, reward_assets_addresses, before_epoch)
    assert_event_not_emitted(tx, absorber.contract_address, "Bestow")


@pytest.mark.parametrize(
    "update",
    [Decimal("0.999000000000000001"), Decimal("0.9999999991"), Decimal("0.99999999999999")],
    indirect=["update"],
)
@pytest.mark.usefixtures(
    "add_aura_reward", "add_vested_aura_reward", "first_epoch_first_provider", "first_provider_request"
)
@pytest.mark.asyncio
async def test_provide_after_threshold_absorption(shrine, absorber, update, yangs, yang_tokens, blessing):
    """
    Sequence of events:
    1. Provider 1 provides (`first_epoch_first_provider`)
    2. Absorption occurs; yin per share falls below threshold (`update`), provider 1 receives 1 round of rewards
    3. Provider 2 provides, provider 1 receives 1 round of rewards
    4. Provider 1 withdraws, both providers share 1 round of rewards
    """
    first_provider, second_provider = PROVIDER_1, PROVIDER_2

    tx, _, remaining_absorber_yin_wad, before_epoch, total_shares_wad, _, _, _ = update
    reward_assets, reward_assets_addresses, blessing_amts, blessing_amts_dec = blessing

    epoch = (await absorber.get_current_epoch().execute()).result.epoch
    expected_epoch = 1
    assert epoch == expected_epoch

    assert_event_emitted(tx, absorber.contract_address, "EpochChanged", [expected_epoch - 1, expected_epoch])

    total_shares_wad = (await absorber.get_total_shares_for_current_epoch().execute()).result.total
    absorber_yin_bal_wad = from_uint((await shrine.balanceOf(absorber.contract_address).execute()).result.balance)
    assert total_shares_wad == absorber_yin_bal_wad

    # Step 3: Provider 2 provides
    second_provider_yin_amt_wad = from_uint((await shrine.balanceOf(second_provider).execute()).result.balance)
    second_provider_yin_amt = from_wad(second_provider_yin_amt_wad)

    tx = await absorber.provide(second_provider_yin_amt_wad).execute(caller_address=second_provider)

    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Bestow",
        [
            len(reward_assets_addresses),
            *reward_assets_addresses,
            len(blessing_amts),
            *blessing_amts,
            total_shares_wad,
            expected_epoch,
        ],
    )

    # Provider 2 can withdraw up to amount provided
    max_withdrawable_yin_amt = from_wad((await absorber.preview_remove(second_provider).execute()).result.amount)
    assert_equalish(max_withdrawable_yin_amt, second_provider_yin_amt)

    # First provider can withdraw a non-zero amount of yin corresponding to what was left in the
    # absorber after absorption past the threshold
    before_first_provider_yin_amt_wad = from_uint((await shrine.balanceOf(first_provider).execute()).result.balance)
    before_first_provider_info = (await absorber.get_provider_info(first_provider).execute()).result.provision
    before_first_provider_reward_bals = (await get_token_balances(reward_assets, [first_provider]))[0]
    before_total_shares_wad = (await absorber.get_total_shares_for_current_epoch().execute()).result.total

    reap_info = (await absorber.preview_reap(first_provider).execute()).result

    # Step 4: Provider 1 withdraws
    tx = await absorber.remove(MAX_REMOVE_AMT).execute(caller_address=first_provider)

    after_first_provider_info = (await absorber.get_provider_info(first_provider).execute()).result.provision
    assert after_first_provider_info.shares == 0
    assert after_first_provider_info.epoch == expected_epoch

    after_first_provider_yin_amt_wad = from_uint((await shrine.balanceOf(first_provider).execute()).result.balance)
    expected_removed_yin = from_wad(remaining_absorber_yin_wad)
    removed_yin = from_wad(after_first_provider_yin_amt_wad - before_first_provider_yin_amt_wad)
    assert_equalish(removed_yin, expected_removed_yin)

    expected_converted_shares = from_wad(
        (
            await absorber.convert_epoch_shares(epoch - 1, epoch, before_first_provider_info.shares).execute()
        ).result.shares
    )
    assert_equalish(removed_yin, expected_converted_shares)

    first_provider_after_threshold_rewards_pct = expected_converted_shares / from_wad(before_total_shares_wad)

    # Provider 1 should receive 2 full rounds and 1 partial round of blessings
    blessings_multiplier = Decimal("2") + first_provider_after_threshold_rewards_pct

    # Relax error margin due to precision loss from shares conversion across epochs
    error_margin = Decimal("0.01")
    await assert_provider_received_rewards(
        tx,
        absorber,
        first_provider,
        expected_epoch,
        reward_assets,
        before_first_provider_reward_bals,
        blessing_amts_dec,
        blessings_multiplier,
        reap_info.reward_asset_amts,
        error_margin=error_margin,
    )

    request = (await absorber.get_provider_request(first_provider).execute()).result.request
    assert request.has_removed == TRUE

    # Provider 1 can no longer call reap
    with pytest.raises(StarkException, match="Absorber: Caller is not a provider in the current epoch"):
        await absorber.reap().execute(caller_address=first_provider)


@pytest.mark.parametrize("update", [Decimal("1")], indirect=["update"])
@pytest.mark.parametrize("skipped_asset_idx", [None, 0, 1, 2])  # Test asset not involved in absorption
@pytest.mark.usefixtures("add_aura_reward", "add_vested_aura_reward", "first_epoch_first_provider")
@pytest.mark.asyncio
async def test_reap_different_epochs(
    shrine,
    absorber,
    yangs,
    yang_tokens,
    update,
    second_update_assets,
    skipped_asset_idx,
    blessing,
):
    """
    Sequence of events:
    1. Provider 1 provides (`first_epoch_first_provider`)
    2. Entire absorber's balance is used for an absorption (`update`), provider 1 receives 1 round of rewards
    3. Provider 2 provides, no rewards are distributed.
    4. Entire absorber's balance is used for an absorption, provider 2 receives 1 round of rewards
    5. Provider 1 and 2 reaps, no rewards are distributed each call.
       Provider 1 should receive assets from first update.
       Provider 2 should receive assets from second update.
    """
    first_absorbed_amts_dec = update[-1]
    reward_assets, reward_assets_addresses, _, blessing_amts_dec = blessing

    first_provider, second_provider = PROVIDER_1, PROVIDER_2

    # Step 3: Provider 2 provides
    second_provider_yin_amt_wad = from_uint((await shrine.balanceOf(second_provider).execute()).result.balance)
    await absorber.provide(second_provider_yin_amt_wad).execute(caller_address=second_provider)

    second_provider_info = (await absorber.get_provider_info(second_provider).execute()).result.provision
    expected_epoch = 1
    assert second_provider_info.epoch == expected_epoch

    second_provider_last_absorption = (
        await absorber.get_provider_last_absorption(second_provider).execute()
    ).result.absorption_id
    expected_last_absorption = 1
    assert second_provider_last_absorption == expected_last_absorption

    # Step 4: Absorber is fully drained
    asset_addresses, absorbed_amts_orig, absorbed_amts_dec_orig = second_update_assets
    absorbed_amts = absorbed_amts_orig.copy()
    absorbed_amts_dec = absorbed_amts_dec_orig.copy()
    if skipped_asset_idx is not None:
        absorbed_amts[skipped_asset_idx] = 0
        absorbed_amts_dec[skipped_asset_idx] = Decimal("0")

    await simulate_update(
        shrine,
        absorber,
        yang_tokens,
        asset_addresses,
        absorbed_amts,
        second_provider_yin_amt_wad,
    )

    expected_epoch += 1
    epoch = (await absorber.get_current_epoch().execute()).result.epoch
    assert epoch == expected_epoch

    absorptions_count = (await absorber.get_absorptions_count().execute()).result.count
    expected_absorptions_count = 2
    assert absorptions_count == expected_absorptions_count

    total_shares = (await absorber.get_total_shares_for_current_epoch().execute()).result.total
    assert total_shares == 0

    providers = [first_provider, second_provider]
    before_providers_absorbed_bals = await get_token_balances(yang_tokens, providers)
    absorbed_amts_arrs = [first_absorbed_amts_dec, absorbed_amts_dec]
    before_providers_reward_bals = await get_token_balances(reward_assets, providers)

    for provider, before_provider_absorbed_bals, before_provider_reward_bals, absorbed_amts in zip(
        providers, before_providers_absorbed_bals, before_providers_reward_bals, absorbed_amts_arrs
    ):
        reap_info = (await absorber.preview_reap(provider).execute()).result
        assert reap_info.absorbed_assets == asset_addresses
        assert reap_info.reward_assets == reward_assets_addresses

        max_withdrawable_yin_amt = from_wad((await absorber.preview_remove(provider).execute()).result.amount)
        assert max_withdrawable_yin_amt == 0

        # Step 5: Provider 1 and 2 reaps
        # There should be no rewards for this action since Absorber is emptied and there are no shares
        tx = await absorber.reap().execute(caller_address=provider)
        assert_event_not_emitted(tx, absorber.contract_address, "Bestow")

        skip_idx = None
        if provider == second_provider:
            skip_idx = skipped_asset_idx

        await assert_provider_received_absorbed_assets(
            tx,
            absorber,
            provider,
            yang_tokens,
            yangs,
            before_provider_absorbed_bals,
            absorbed_amts,
            reap_info.absorbed_asset_amts,
            skip_idx=skip_idx,
        )

        blessings_multiplier = 1
        await assert_provider_received_rewards(
            tx,
            absorber,
            provider,
            expected_epoch,
            reward_assets,
            before_provider_reward_bals,
            blessing_amts_dec,
            blessings_multiplier,
            reap_info.reward_asset_amts,
        )

        after_provider_info = (await absorber.get_provider_info(provider).execute()).result.provision
        assert after_provider_info.epoch == expected_epoch


@pytest.mark.usefixtures(
    "add_aura_reward", "add_vested_aura_reward", "first_epoch_first_provider", "first_epoch_second_provider"
)
@pytest.mark.parametrize("update", [Decimal("0.2"), Decimal("1")], indirect=["update"])
@pytest.mark.parametrize("absorber_both", ["absorber", "absorber_killed"], indirect=["absorber_both"])
@pytest.mark.asyncio
async def test_multi_user_reap_same_epoch_single_absorption(
    shrine,
    absorber_both,
    first_epoch_first_provider,
    first_epoch_second_provider,
    yangs,
    yang_tokens,
    update,
    blessing,
):
    """
    Sequence of events:
    1. Provider 1 provides (`first_epoch_first_provider`)
    2. Provider 2 provides (`first_epoch_second_provider`), provider 1 receives 1 round of rewards
    3. Absorption happens (`update`), providers share 1 round of rewards
    4. Providers 1 and 2 reaps, providers share each round of rewards if absorber is not drained
    """
    absorber = absorber_both

    _, percentage_drained, _, before_epoch, _, absorbed_assets_addresses, _, absorbed_amts_dec = update
    is_drained = True if percentage_drained >= Decimal("1") else False

    reward_assets, reward_assets_addresses, blessing_amts, blessing_amts_dec = blessing

    _, first_provider_amt_wad = first_epoch_first_provider
    _, second_provider_amt_wad = first_epoch_second_provider

    first_provider_amt = from_wad(first_provider_amt_wad)
    second_provider_amt = from_wad(second_provider_amt_wad)
    total_provided_amt = first_provider_amt + second_provider_amt

    providers = [PROVIDER_1, PROVIDER_2]
    before_providers_absorbed_bals = await get_token_balances(yang_tokens, providers)
    before_providers_reward_bals = await get_token_balances(reward_assets, providers)

    expected_epoch = 0
    if is_drained:
        expected_epoch += 1

    expected_blessings_count = 2
    provided_pct = [first_provider_amt / total_provided_amt, second_provider_amt / total_provided_amt]
    for provider, percentage, before_provider_absorbed_bals, before_provider_reward_bals in zip(
        providers, provided_pct, before_providers_absorbed_bals, before_providers_reward_bals
    ):
        reap_info = (await absorber.preview_reap(provider).execute()).result

        # Step 4: Providers 1 and 2 reaps
        tx = await absorber.reap().execute(caller_address=provider)

        # Rewards are distributed only if there are shares in current epoch
        if is_drained:
            assert_event_not_emitted(tx, absorber.contract_address, "Bestow")
        else:
            expected_blessings_count += 1
            assert_event_emitted(
                tx,
                absorber.contract_address,
                "Bestow",
                lambda d: d[:6]
                == [
                    len(reward_assets_addresses),
                    *reward_assets_addresses,
                    len(blessing_amts),
                    *blessing_amts,
                ],
            )

        assert_event_emitted(
            tx,
            absorber.contract_address,
            "Reap",
            lambda d: d[:5] == [provider, len(absorbed_assets_addresses), *absorbed_assets_addresses]
            and d[9:12] == [len(reward_assets_addresses), *reward_assets_addresses],
        )

        provider_absorbed_amts_dec = [amt * percentage for amt in absorbed_amts_dec]
        await assert_provider_received_absorbed_assets(
            tx,
            absorber,
            provider,
            yang_tokens,
            yangs,
            before_provider_absorbed_bals,
            provider_absorbed_amts_dec,
            reap_info.absorbed_asset_amts,
        )

        blessings_multiplier = (expected_blessings_count - 1) * percentage

        # First provider gets a full round of rewards when second provider first provides
        if provider == PROVIDER_1:
            blessings_multiplier += Decimal("1")

        await assert_provider_received_rewards(
            tx,
            absorber,
            provider,
            expected_epoch,
            reward_assets,
            before_provider_reward_bals,
            blessing_amts_dec,
            blessings_multiplier,
            reap_info.reward_asset_amts,
        )

        after_provider_info = (await absorber.get_provider_info(provider).execute()).result.provision
        assert after_provider_info.epoch == expected_epoch

        # Provider cannot reap earlier rewards again if it was drained
        if is_drained:
            with pytest.raises(StarkException, match="Absorber: Caller is not a provider in the current epoch"):
                await absorber.reap().execute(caller_address=provider)

    if is_drained:
        await assert_reward_errors_propagated_to_next_epoch(absorber, reward_assets_addresses, before_epoch)


@pytest.mark.parametrize("update", [Decimal("0.2"), Decimal("0.5")], indirect=["update"])
@pytest.mark.parametrize("second_absorption_percentage", [Decimal("0.2"), Decimal("0.5")])
@pytest.mark.usefixtures(
    "add_aura_reward", "add_vested_aura_reward", "first_epoch_first_provider", "funded_absorber_providers"
)
@pytest.mark.asyncio
async def test_multi_user_reap_same_epoch_multi_absorptions(
    shrine,
    absorber,
    yangs,
    yang_tokens,
    update,
    second_update_assets,
    second_absorption_percentage,
    blessing,
):
    """
    Sequence of events:
    1. Provider 1 provides (`first_epoch_first_provider`).
    2. Partial absorption happens (`update`), provider 1 receives 1 round of rewards.
    3. Provider 2 provides, provider 1 receives 1 round of rewards.
    4. Partial absorption happens, providers share 1 round of rewards.
    5. Provider 1 reaps, providers share 1 round of rewards
    6. Provider 2 reaps, providers share 1 round of rewards
    """
    first_provider, second_provider = PROVIDER_1, PROVIDER_2

    _, _, remaining_yin_wad, expected_epoch, _, absorbed_assets_addresses, _, first_absorbed_amts_dec = update

    reward_assets, reward_assets_addresses, _, blessing_amts_dec = blessing

    # Step 3: Provider 2 pprovides
    second_provider_yin_amt_wad = from_uint((await shrine.balanceOf(second_provider).execute()).result.balance)
    await absorber.provide(second_provider_yin_amt_wad).execute(caller_address=second_provider)

    # Step 4: Partial absorption
    first_provider_amt = from_wad(remaining_yin_wad)
    second_provider_amt = from_wad(second_provider_yin_amt_wad)
    total_provided_amt = first_provider_amt + second_provider_amt

    second_update_burn_amt_wad = to_wad(second_absorption_percentage * total_provided_amt)
    _, second_absorbed_amts, second_absorbed_amts_dec = second_update_assets

    await simulate_update(
        shrine,
        absorber,
        yang_tokens,
        absorbed_assets_addresses,
        second_absorbed_amts,
        second_update_burn_amt_wad,
    )

    providers = [first_provider, second_provider]
    providers_remaining_yin = [first_provider_amt, second_provider_amt]
    before_providers_absorbed_bals = await get_token_balances(yang_tokens, providers)
    before_providers_reward_bals = await get_token_balances(reward_assets, providers)

    expected_blessings_count = 3
    provided_pct = [amt / total_provided_amt for amt in providers_remaining_yin]
    for provider, percentage, remaining_yin, before_provider_absorbed_bals, before_provider_reward_bals in zip(
        providers, provided_pct, providers_remaining_yin, before_providers_absorbed_bals, before_providers_reward_bals
    ):
        reap_info = (await absorber.preview_reap(provider).execute()).result

        # Steps 5 and 6: Providers 1 and 2 reaps
        tx = await absorber.reap().execute(caller_address=provider)

        assert_event_emitted(
            tx,
            absorber.contract_address,
            "Reap",
            lambda d: d[:5] == [provider, len(absorbed_assets_addresses), *absorbed_assets_addresses]
            and d[9:12] == [len(reward_assets_addresses), *reward_assets_addresses],
        )
        assert_event_emitted(tx, absorber.contract_address, "Bestow")

        expected_blessings_count += 1

        if provider == first_provider:
            absorbed_amts_dec = [
                i + (percentage * j) for i, j in zip(first_absorbed_amts_dec, second_absorbed_amts_dec)
            ]
        elif provider == second_provider:
            absorbed_amts_dec = [percentage * i for i in second_absorbed_amts_dec]

        await assert_provider_received_absorbed_assets(
            tx,
            absorber,
            provider,
            yang_tokens,
            yangs,
            before_provider_absorbed_bals,
            absorbed_amts_dec,
            reap_info.absorbed_asset_amts,
        )

        max_withdrawable_yin_amt = from_wad((await absorber.preview_remove(provider).execute()).result.amount)
        expected_remaining_yin = remaining_yin - (percentage * from_wad(second_update_burn_amt_wad))
        assert_equalish(max_withdrawable_yin_amt, expected_remaining_yin)

        # First provider gets 2 full rounds of rewards
        blessings_multiplier = (expected_blessings_count - 2) * percentage
        if provider == PROVIDER_1:
            blessings_multiplier += Decimal("2")

        await assert_provider_received_rewards(
            tx,
            absorber,
            provider,
            expected_epoch,
            reward_assets,
            before_provider_reward_bals,
            blessing_amts_dec,
            blessings_multiplier,
            reap_info.reward_asset_amts,
        )

        after_provider_info = (await absorber.get_provider_info(provider).execute()).result.provision
        assert after_provider_info.epoch == expected_epoch


@pytest.mark.parametrize("price_decrease", [Decimal("0.5"), Decimal("0.8")])
@pytest.mark.usefixtures("first_epoch_first_provider", "first_epoch_second_provider")
@pytest.mark.asyncio
async def test_remove_exceeds_limit_fail(shrine, absorber, steth_yang, price_decrease):

    steth_yang_price = (await shrine.get_current_yang_price(steth_yang.contract_address).execute()).result.price
    new_steth_yang_price = int((Decimal("1") - price_decrease) * steth_yang_price)
    await shrine.advance(steth_yang.contract_address, new_steth_yang_price).execute(caller_address=SHRINE_OWNER)

    ltv_to_threshold = (await absorber.get_shrine_ltv_to_threshold().execute()).result.ratio

    assert ltv_to_threshold > REMOVAL_LIMIT_RAY

    for provider in [PROVIDER_1, PROVIDER_2]:
        with pytest.raises(StarkException, match="Absorber: Relative LTV is above limit"):
            await absorber.remove(MAX_REMOVE_AMT).execute(caller_address=provider)


@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.asyncio
async def test_remove_no_request_fail(starknet, absorber):
    provider = PROVIDER_1

    # Provider has not requested removal
    with pytest.raises(StarkException, match="Absorber: No request found"):
        await absorber.remove(MAX_REMOVE_AMT).execute(caller_address=provider)


@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.asyncio
async def test_non_provider_fail(shrine, absorber):
    provider = NON_PROVIDER

    with pytest.raises(StarkException, match="Absorber: Caller is not a provider in the current epoch"):
        await absorber.request().execute(caller_address=provider)

    with pytest.raises(StarkException, match="Absorber: Caller is not a provider in the current epoch"):
        await absorber.remove(0).execute(caller_address=provider)

    with pytest.raises(StarkException, match="Absorber: Caller is not a provider in the current epoch"):
        await absorber.remove(MAX_REMOVE_AMT).execute(caller_address=provider)

    with pytest.raises(StarkException, match="Absorber: Caller is not a provider in the current epoch"):
        await absorber.reap().execute(caller_address=provider)

    removable_yin = (await absorber.preview_remove(provider).execute()).result.amount
    assert removable_yin == 0

    reap_info = (await absorber.preview_reap(provider).execute()).result
    assert reap_info.absorbed_assets == reap_info.absorbed_asset_amts == []
    assert reap_info.reward_assets == reap_info.reward_asset_amts == []


@pytest.mark.usefixtures("funded_absorber_providers")
@pytest.mark.asyncio
async def test_provide_fail(shrine, absorber):
    provider = PROVIDER_1

    # Out of bounds
    for amt in WAD_RAY_OOB_VALUES:
        with pytest.raises(StarkException, match=r"Absorber: Value of `amount` \(-?\d+\) is out of bounds"):
            await absorber.provide(amt).execute(caller_address=provider)

    # Less than initial shares
    with pytest.raises(StarkException, match="Absorber: Amount provided is less than minimum initial shares"):
        await absorber.provide(0).execute(caller_address=provider)

    # Less than initial shares
    with pytest.raises(StarkException, match="Absorber: Amount provided is less than minimum initial shares"):
        await absorber.provide(999).execute(caller_address=provider)

    # Insufficient balance
    yin_bal_uint = (await shrine.balanceOf(provider).execute()).result.balance
    yin_bal_wad = from_uint(yin_bal_uint)
    provide_amt = yin_bal_wad + 1
    with pytest.raises(StarkException, match="Absorber: Transfer of yin failed"):
        await absorber.provide(provide_amt).execute(caller_address=provider)

    # Insufficient allowance
    allowance_amt = yin_bal_wad - 1
    allowance_amt_uint = to_uint(allowance_amt)

    await shrine.approve(absorber.contract_address, allowance_amt_uint).execute(caller_address=provider)
    with pytest.raises(StarkException, match="Absorber: Transfer of yin failed"):
        await absorber.provide(yin_bal_wad).execute(caller_address=provider)


@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.parametrize("amt", WAD_RAY_OOB_VALUES)
@pytest.mark.asyncio
async def test_remove_out_of_bounds_fail(absorber, amt):
    provider = PROVIDER_1
    with pytest.raises(StarkException, match=r"Absorber: Value of `amount` \(-?\d+\) is out of bounds"):
        await absorber.remove(amt).execute(caller_address=provider)


#
# Tests - Bestow
#


@pytest.mark.usefixtures("add_aura_reward", "add_vested_aura_reward", "first_epoch_first_provider")
@pytest.mark.asyncio
async def test_bestow_inactive_reward(
    absorber, aura_token, vested_aura_token, aura_token_blesser, vested_aura_token_blesser
):
    """
    Inactive rewards should be skipped when `bestow` is called.
    """
    provider = PROVIDER_1

    # Set vested AURA to inactive
    await absorber.set_reward(
        vested_aura_token.contract_address,
        vested_aura_token_blesser.contract_address,
        FALSE,
    ).execute(caller_address=ABSORBER_OWNER)

    expected_epoch = 0
    before_aura_cumulative = (
        await absorber.get_asset_reward_info(aura_token.contract_address, expected_epoch).execute()
    ).result.info.asset_amt_per_share
    before_vested_aura_cumulative = (
        await absorber.get_asset_reward_info(vested_aura_token.contract_address, expected_epoch).execute()
    ).result.info.asset_amt_per_share

    # Trigger rewards
    tx = await absorber.provide(0).execute(caller_address=provider)

    expected_rewards_count = 1
    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Bestow",
        lambda d: d[:4]
        == [
            expected_rewards_count,
            *[aura_token.contract_address],
            expected_rewards_count,
            *[AURA_BLESS_AMT_WAD],
        ],
    )

    after_aura_cumulative = (
        await absorber.get_asset_reward_info(aura_token.contract_address, expected_epoch).execute()
    ).result.info.asset_amt_per_share
    after_vested_aura_cumulative = (
        await absorber.get_asset_reward_info(vested_aura_token.contract_address, expected_epoch).execute()
    ).result.info.asset_amt_per_share

    assert after_aura_cumulative > before_aura_cumulative
    assert after_vested_aura_cumulative == before_vested_aura_cumulative

    # Set all rewards to inactive
    await absorber.set_reward(
        aura_token.contract_address,
        aura_token_blesser.contract_address,
        FALSE,
    ).execute(caller_address=ABSORBER_OWNER)

    final_aura_cumulative = (
        await absorber.get_asset_reward_info(aura_token.contract_address, expected_epoch).execute()
    ).result.info.asset_amt_per_share
    final_vested_aura_cumulative = (
        await absorber.get_asset_reward_info(vested_aura_token.contract_address, expected_epoch).execute()
    ).result.info.asset_amt_per_share

    assert final_aura_cumulative == after_aura_cumulative
    assert final_vested_aura_cumulative == after_vested_aura_cumulative


@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.asyncio
async def test_bestow_zero_distribution_from_active_rewards(
    absorber, aura_token_blesser, vested_aura_token_blesser, blessing
):
    """
    Check for early return when no rewards are distributed because the vesting contracts
    of active rewards did not distribute any
    """
    provider = PROVIDER_1

    _, reward_assets_addresses, _, _ = blessing
    blessers = [aura_token_blesser, vested_aura_token_blesser]
    for asset_address, blesser in zip(reward_assets_addresses, blessers):
        await absorber.set_reward(
            asset_address,
            blesser.contract_address,
            TRUE,
        ).execute(caller_address=ABSORBER_OWNER)

    expected_epoch = 0
    before_rewards_cumulative = []
    for asset_address in reward_assets_addresses:
        cumulative = (
            await absorber.get_asset_reward_info(asset_address, expected_epoch).execute()
        ).result.info.asset_amt_per_share
        before_rewards_cumulative.append(cumulative)

    # Trigger rewards
    await absorber.provide(0).execute(caller_address=provider)

    after_rewards_cumulative = []
    for asset_address in reward_assets_addresses:
        cumulative = (
            await absorber.get_asset_reward_info(asset_address, expected_epoch).execute()
        ).result.info.asset_amt_per_share
        after_rewards_cumulative.append(cumulative)

    assert before_rewards_cumulative == after_rewards_cumulative


@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.asyncio
async def test_bestow_pass_with_depleted_active_reward(
    absorber, aura_token, aura_token_blesser, vested_aura_token, vested_aura_token_blesser
):
    """
    Check that `bestow` works as intended when one of more than one active rewards does not have any distribution
    """
    provider = PROVIDER_1

    rewards = [aura_token, vested_aura_token]
    blessers = [aura_token_blesser, vested_aura_token_blesser]
    for asset, blesser in zip(rewards, blessers):
        await absorber.set_reward(
            asset.contract_address,
            blesser.contract_address,
            TRUE,
        ).execute(caller_address=ABSORBER_OWNER)

    expected_epoch = 0
    before_aura_cumulative = (
        await absorber.get_asset_reward_info(aura_token.contract_address, expected_epoch).execute()
    ).result.info.asset_amt_per_share
    before_vested_aura_cumulative = (
        await absorber.get_asset_reward_info(vested_aura_token.contract_address, expected_epoch).execute()
    ).result.info.asset_amt_per_share

    # Mint tokens to AURA's blesser contract
    vesting_amt = to_uint(to_wad(AURA_BLESSER_STARTING_BAL))
    await aura_token.mint(aura_token_blesser.contract_address, vesting_amt).execute(caller_address=BLESSER_OWNER)

    # Trigger rewards
    tx = await absorber.provide(0).execute(caller_address=provider)
    expected_rewards_count = len(rewards)
    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Bestow",
        lambda d: d[:6]
        == [
            expected_rewards_count,
            *[aura_token.contract_address, vested_aura_token.contract_address],
            expected_rewards_count,
            *[AURA_BLESS_AMT_WAD, 0],
        ],
    )

    after_aura_cumulative = (
        await absorber.get_asset_reward_info(aura_token.contract_address, expected_epoch).execute()
    ).result.info.asset_amt_per_share
    after_vested_aura_cumulative = (
        await absorber.get_asset_reward_info(vested_aura_token.contract_address, expected_epoch).execute()
    ).result.info.asset_amt_per_share

    assert after_aura_cumulative > before_aura_cumulative
    assert after_vested_aura_cumulative == before_vested_aura_cumulative