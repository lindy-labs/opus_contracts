from decimal import Decimal

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
    FALSE,
    MAX_UINT256,
    SHRINE_OWNER,
    TIME_INTERVAL,
    TRUE,
    WAD_RAY_OOB_VALUES,
    ZERO_ADDRESS,
    YangConfig,
    assert_equalish,
    assert_event_emitted,
    calculate_max_forge,
    compile_code,
    compile_contract,
    create_feed,
    custom_error_margin,
    estimate_gas,
    from_fixed_point,
    from_ray,
    from_uint,
    from_wad,
    get_contract_code_with_addition,
    get_contract_code_with_replacement,
    get_token_balances,
    max_approve,
    set_block_timestamp,
    to_fixed_point,
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


async def assert_provider_rewards_last_cumulative_updated(
    absorber: StarknetContract, provider: int, reward_tokens_addresses: list[int], epoch: int
):
    """
    Helper function to assert that a provider's last cumulative asset amount per share wad value is
    updated for all reward tokens.
    """
    for asset_address in reward_tokens_addresses:
        provider_cumulative = (
            await absorber.get_provider_reward_last_cumulative(provider, asset_address).execute()
        ).result.cumulative
        current_cumulative = (
            await absorber.get_asset_reward_info(asset_address, expected_epoch).execute()
        ).result.info.asset_amt_per_share

        assert provider_cumulative == current_cumulative


async def assert_reward_errors_propagated_to_next_epoch(
    absorber: StarknetContract,
    reward_tokens_addresses: list[int],
    epoch: int,
):
    """
    Helper function to assert that the errors of reward tokens in the current epoch are
    propagated to the next epoch, and the cumulative asset amount per share wad is 0.
    """
    for asset_address in reward_tokens_addresses:
        before_epoch_error = (await absorber.get_asset_reward_info(asset_address, epoch).execute()).result.info.error
        after_epoch_info = (await absorber.get_asset_reward_info(asset_address, epoch + 1).execute()).result.info

        assert after_epoch_info.error == before_epoch_error
        assert after_epoch_info.asset_amt_per_share == 0


#
# Fixtures
#


@pytest.fixture
async def first_update_assets(yangs) -> tuple[list[int]]:
    """
    Helper fixture to return a tuple of:
    1. a list of asset addresses
    2. a list of asset amounts in the asset's decimals
    3. a list of asset amounts in Decimal.
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
async def second_update_assets(yangs) -> tuple[list[int]]:
    """
    Helper fixture to return a tuple of:
    1. a list of asset addresses
    2. a list of asset amounts in the asset's decimals
    3. a list of asset amounts in Decimal.
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
        ],
    )

    return absorber


@pytest.fixture
async def absorber(absorber_deploy):
    absorber = absorber_deploy
    # Set purger in absorber
    await absorber.set_purger(MOCK_PURGER).execute(caller_address=ABSORBER_OWNER)
    await absorber.grant_role(AbsorberRoles.COMPENSATE | AbsorberRoles.UPDATE, MOCK_PURGER).execute(
        caller_address=ABSORBER_OWNER
    )
    return absorber


@pytest.fixture
async def absorber_killed(absorber):
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
    # Skipping over the first element in `feeds` since the start price is set in `add_yang`
    for i in range(1, FEED_LEN):
        timestamp = i * TIME_INTERVAL
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
async def first_epoch_first_provider(shrine, absorber, funded_absorber_providers):
    provider = PROVIDER_1
    provider_yin_amt_uint = (await shrine.balanceOf(provider).execute()).result.balance
    provider_yin_amt = int(from_uint(provider_yin_amt_uint) / Decimal("3.5"))

    tx = await absorber.provide(provider_yin_amt).execute(caller_address=provider)
    return tx, provider_yin_amt


@pytest.fixture
async def first_epoch_second_provider(shrine, absorber, funded_absorber_providers):
    provider = PROVIDER_2
    provider_yin_amt_uint = (await shrine.balanceOf(provider).execute()).result.balance
    provider_yin_amt = from_uint(provider_yin_amt_uint)

    tx = await absorber.provide(provider_yin_amt).execute(caller_address=provider)
    return tx, provider_yin_amt


@pytest.fixture
async def update(request, shrine, absorber, yang_tokens, first_update_assets):
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
async def add_aura_reward(absorber, aura_token, aura_token_blesser):
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
async def add_vested_aura_reward(absorber, vested_aura_token, vested_aura_token_blesser):
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
async def blessing(aura_token, vested_aura_token):
    """
    Returns a tuple of
    1. an ordered list of the reward tokens
    2. an ordered list of the amount distributed by the Blesser to the Absorber per distribution

    The order is the reverse of that in which the rewards were added to match the return values of
    `get_rewards`.
    """
    # When reward tokens are fetched, order is reversed.
    reward_tokens = [vested_aura_token, aura_token]
    expected_asset_amts = [VESTED_AURA_BLESS_AMT_WAD, AURA_BLESS_AMT_WAD]
    return reward_tokens, expected_asset_amts


#
# Tests - Fixtures setup
#


@pytest.mark.usefixtures("add_aura_reward", "add_vested_aura_reward")
@pytest.mark.asyncio
async def test_blessers_setup(absorber, aura_token, aura_token_blesser, vested_aura_token, vested_aura_token_blesser):
    aura_bal = from_wad(
        from_uint((await aura_token.balanceOf(aura_token_blesser.contract_address).execute()).result.balance)
    )
    assert aura_bal == AURA_BLESSER_STARTING_BAL

    vested_aura_bal = from_wad(
        from_uint(
            (await vested_aura_token.balanceOf(vested_aura_token_blesser.contract_address).execute()).result.balance
        )
    )
    assert vested_aura_bal == VESTED_AURA_BLESSER_STARTING_BAL


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

    rewards = (await absorber.get_rewards().execute()).result
    rewards.assets == rewards.blessers == rewards.is_active == []

    is_live = (await absorber.get_live().execute()).result.is_live
    assert is_live == TRUE

    admin_role = (await absorber.get_roles(ABSORBER_OWNER).execute()).result.roles
    assert admin_role == AbsorberRoles.KILL + AbsorberRoles.SET_PURGER + AbsorberRoles.SET_REWARD


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

    rewards = (await absorber.get_rewards().execute()).result
    assert rewards.assets == [aura_token.contract_address]
    assert rewards.blessers == [aura_token_blesser.contract_address]
    assert rewards.is_active == [TRUE]

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

    rewards = (await absorber.get_rewards().execute()).result

    # Order is reversed because iteration starts at current count and ends at 0
    assert rewards.assets == [vested_aura_token.contract_address, aura_token.contract_address]
    assert rewards.blessers == [vested_aura_token_blesser.contract_address, aura_token_blesser.contract_address]
    assert rewards.is_active == [FALSE, TRUE]

    # Update existing reward
    tx = await absorber.set_reward(
        aura_token.contract_address,
        aura_token_blesser.contract_address,
        FALSE,
    ).execute(caller_address=ABSORBER_OWNER)

    rewards = (await absorber.get_rewards().execute()).result

    # Order is reversed because iteration starts at current count and ends at 0
    assert rewards.assets == [vested_aura_token.contract_address, aura_token.contract_address]
    assert rewards.blessers == [vested_aura_token_blesser.contract_address, aura_token_blesser.contract_address]
    assert rewards.is_active == [FALSE, FALSE]


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
        assets,
        absorbed_asset_amts,
        absorbed_asset_amts_dec,
    ) = update
    asset_count = len(assets)
    is_drained = True if percentage_drained >= Decimal("1") else False

    reward_tokens, expected_rewards_amts = blessing
    reward_tokens_addresses = [asset.contract_address for asset in reward_tokens]

    before_total_shares = from_wad(before_total_shares_wad)

    expected_gain_epoch = 0
    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Gain",
        [asset_count, *assets, asset_count, *absorbed_asset_amts, before_total_shares_wad, expected_gain_epoch],
    )

    expected_rewards_count = 2
    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Invoke",
        [
            expected_rewards_count,
            *reward_tokens_addresses,
            expected_rewards_count,
            *expected_rewards_amts,
            before_total_shares_wad,
            expected_gain_epoch,
        ],
    )

    expected_absorption_id = 1
    actual_absorption_id = (await absorber.get_absorptions_count().execute()).result.count
    assert actual_absorption_id == expected_absorption_id

    for asset, amt in zip(yangs, absorbed_asset_amts_dec):
        asset_address = asset.contract_address
        asset_absorption_info = (
            await absorber.get_asset_absorption_info(asset_address, expected_absorption_id).execute()
        ).result.info
        actual_asset_amt_per_share = from_fixed_point(asset_absorption_info.asset_amt_per_share, asset.decimals)

        expected_asset_amt_per_share = Decimal(amt) / before_total_shares

        error_margin = custom_error_margin(asset.decimals)
        assert_equalish(actual_asset_amt_per_share, expected_asset_amt_per_share, error_margin)

    # If absorber is fully drained of its yin balance, check that epoch has increased
    # and total shares is set to 0.
    if is_drained is True:
        current_epoch = (await absorber.get_current_epoch().execute()).result.epoch
        assert current_epoch == before_epoch + 1

        after_total_shares_wad = (await absorber.get_total_shares_for_current_epoch().execute()).result.total
        assert after_total_shares_wad == 0

        assert_event_emitted(tx, absorber.contract_address, "EpochChanged", [before_epoch, current_epoch])

    for asset_address, blessed_amt_wad in zip(reward_tokens_addresses, expected_rewards_amts):
        asset_blessing_info = (await absorber.get_asset_reward_info(asset_address, before_epoch).execute()).result.info
        actual_asset_amt_per_share = from_wad(asset_blessing_info.asset_amt_per_share)
        expected_asset_amt_per_share = from_wad(blessed_amt_wad) / before_total_shares
        assert_equalish(actual_asset_amt_per_share, expected_asset_amt_per_share)


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
# Tests - Provider functions (provide, remove, reap)
#


@pytest.mark.usefixtures("add_aura_reward", "add_vested_aura_reward")
@pytest.mark.asyncio
async def test_provide_first_epoch(shrine, absorber, first_epoch_first_provider, blessing):
    provider = PROVIDER_1

    tx, initial_yin_amt_provided = first_epoch_first_provider
    reward_tokens, expected_rewards_amts = blessing
    reward_tokens_addresses = [asset.contract_address for asset in reward_tokens]

    before_provider_info = (await absorber.get_provider_info(provider).execute()).result.provision
    before_provider_last_absorption = (
        await absorber.get_provider_last_absorption(provider).execute()
    ).result.absorption_id
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

    for asset, blessed_amt_wad in zip(reward_tokens, expected_rewards_amts):
        asset_address = asset.contract_address
        asset_blessing_info = (
            await absorber.get_asset_reward_info(asset_address, expected_epoch).execute()
        ).result.info
        actual_asset_amt_per_share = from_wad(asset_blessing_info.asset_amt_per_share)
        expected_asset_amt_per_share = from_wad(blessed_amt_wad) / from_wad(before_total_shares_wad)
        assert_equalish(actual_asset_amt_per_share, expected_asset_amt_per_share)

    assert_provider_rewards_last_cumulative_updated(absorber, provider, reward_tokens_addresses, expected_epoch)


@pytest.mark.parametrize("absorber_both", ["absorber", "absorber_killed"], indirect=["absorber_both"])
@pytest.mark.usefixtures("add_aura_reward", "add_vested_aura_reward", "first_epoch_first_provider")
@pytest.mark.parametrize("update", [Decimal("0.2"), Decimal("1")], indirect=["update"])
@pytest.mark.asyncio
async def test_reap_pass(shrine, absorber_both, update, yangs, yang_tokens, blessing):
    absorber = absorber_both

    provider = PROVIDER_1

    _, percentage_drained, _, before_epoch, _, assets, absorbed_asset_amts, absorbed_asset_amts_dec = update
    asset_count = len(assets)
    is_drained = True if percentage_drained >= Decimal("1") else False

    reward_tokens, expected_rewards_amts = blessing
    reward_tokens_addresses = [asset.contract_address for asset in reward_tokens]

    absorbed = (await absorber.preview_reap(provider).execute()).result
    assert absorbed.absorbed_assets == assets
    for asset_info, expected, actual in zip(yangs, absorbed_asset_amts, absorbed.absorbed_asset_amts):
        error_margin = custom_error_margin(asset_info.decimals // 2 - 1)
        adjusted_expected = from_fixed_point(expected, asset_info.decimals)
        adjusted_actual = from_fixed_point(actual, asset_info.decimals)
        assert_equalish(adjusted_expected, adjusted_actual, error_margin)

    # Fetch user balances before `reap`
    before_provider_absorbed_asset_bals = (await get_token_balances(yang_tokens, [provider]))[0]
    before_provider_reward_asset_bals = (await get_token_balances(reward_tokens, [provider]))[0]

    before_provider_last_absorption = (
        await absorber.get_provider_last_absorption(provider).execute()
    ).result.absorption_id
    before_total_shares_wad = (await absorber.get_total_shares_for_current_epoch().execute()).result.total

    tx = await absorber.reap().execute(caller_address=provider)

    assert_event_emitted(tx, absorber.contract_address, "Reap", lambda d: d[:5] == [provider, asset_count, *assets])

    # Check that provider 1 receives all assets from first provision
    for asset_contract, asset_info, before_bal, absorbed_amt in zip(
        yang_tokens, yangs, before_provider_absorbed_asset_bals, absorbed_asset_amts_dec
    ):
        assert_event_emitted(
            tx, asset_contract.contract_address, "Transfer", lambda d: d[:2] == [absorber.contract_address, provider]
        )

        after_provider_asset_bal = from_fixed_point(
            from_uint((await asset_contract.balanceOf(provider).execute()).result.balance), asset_info.decimals
        )

        # Relax error margin by half due to loss of precision from fixed point arithmetic
        error_margin = custom_error_margin(asset_info.decimals // 2 - 1)
        assert_equalish(after_provider_asset_bal, before_bal + absorbed_amt, error_margin)

    after_provider_last_absorption = (
        await absorber.get_provider_last_absorption(provider).execute()
    ).result.absorption_id
    assert after_provider_last_absorption == before_provider_last_absorption + 1

    expected_blessings_count = 1
    # Assert `Invoke` is emitted if absorber is not completely drained
    if is_drained is True:
        expected_epoch = 1
        after_provider_info = (await absorber.get_provider_info(provider).execute()).result.provision
        assert after_provider_info.epoch == expected_epoch
        assert after_provider_info.shares == 0
    else:
        expected_rewards_count = 2
        expected_epoch = 0
        assert_event_emitted(
            tx,
            absorber.contract_address,
            "Invoke",
            [
                expected_rewards_count,
                *[asset.contract_address for asset in reward_tokens],
                expected_rewards_count,
                *expected_rewards_amts,
                before_total_shares_wad,
                expected_epoch,
            ],
        )

        expected_blessings_count += 1

    after_provider_reward_bals = []
    # Check provider 1 receives all rewards
    for asset, before_bal, blessed_amt_wad in zip(
        reward_tokens, before_provider_reward_asset_bals, expected_rewards_amts
    ):
        asset_address = asset.contract_address

        assert_event_emitted(tx, asset_address, "Transfer", lambda d: d[:2] == [absorber.contract_address, provider])

        blessed_amt = from_wad(expected_blessings_count * blessed_amt_wad)
        after_provider_asset_bal = from_wad(from_uint((await asset.balanceOf(provider).execute()).result.balance))
        assert_equalish(after_provider_asset_bal, before_bal + blessed_amt)

        after_provider_reward_bals.append(after_provider_asset_bal)

    assert_provider_rewards_last_cumulative_updated(absorber, provider, reward_tokens_addresses, expected_epoch)

    # Assert that provider does not receive rewards twice
    if is_drained is True:
        with pytest.raises(StarkException, match="Absorber: Caller is not a provider in the current epoch"):
            await absorber.reap().execute(caller_address=provider)

        assert_reward_errors_propagated_to_next_epoch(absorber, reward_tokens_addresses, before_epoch)

    else:
        await absorber.reap().execute(caller_address=provider)

        for asset, after_bal, blessed_amt_wad in zip(reward_tokens, after_provider_reward_bals, expected_rewards_amts):
            blessed_amt = from_wad(blessed_amt_wad)
            assert_equalish(
                from_wad(from_uint((await asset.balanceOf(provider).execute()).result.balance)), after_bal + blessed_amt
            )

        assert_provider_rewards_last_cumulative_updated(absorber, provider, reward_tokens_addresses, expected_epoch)


@pytest.mark.parametrize("absorber_both", ["absorber", "absorber_killed"], indirect=["absorber_both"])
@pytest.mark.parametrize("update", [Decimal("0"), Decimal("0.2"), Decimal("1")], indirect=["update"])
@pytest.mark.parametrize("percentage_to_remove", [Decimal("0"), Decimal("0.25"), Decimal("0.667"), Decimal("1")])
@pytest.mark.usefixtures("add_aura_reward", "add_vested_aura_reward", "first_epoch_first_provider")
@pytest.mark.asyncio
async def test_remove(
    shrine,
    absorber_both,
    update,
    yangs,
    yang_tokens,
    percentage_to_remove,
    blessing,
):
    absorber = absorber_both

    provider = PROVIDER_1

    _, percentage_drained, _, _, total_shares_wad, assets, absorbed_asset_amts, absorbed_asset_amts_dec = update
    is_drained = True if percentage_drained >= Decimal("1") else False

    reward_tokens, expected_rewards_amts = blessing
    reward_tokens_addresses = [asset.contract_address for asset in reward_tokens]

    before_provider_yin_bal = from_wad(from_uint((await shrine.balanceOf(provider).execute()).result.balance))
    before_provider_info = (await absorber.get_provider_info(provider).execute()).result.provision
    before_provider_last_absorption = (
        await absorber.get_provider_last_absorption(provider).execute()
    ).result.absorption_id
    before_provider_reward_bals = (await get_token_balances(reward_tokens, [provider]))[0]

    before_absorber_yin_bal_wad = from_uint(
        (await shrine.balanceOf(absorber.contract_address).execute()).result.balance
    )

    if is_drained is True:
        yin_to_remove_wad = 0
        expected_shares = Decimal("0")
        expected_epoch = before_provider_info.epoch + 1
        expected_blessings_count = 1

    else:
        max_removable_yin = (await absorber.preview_remove(provider).execute()).result.amount
        yin_to_remove_wad = int(percentage_to_remove * max_removable_yin)
        expected_shares_removed = from_wad(
            (await absorber.convert_to_shares(yin_to_remove_wad, TRUE).execute()).result.provider_shares
        )
        expected_shares = from_wad(before_provider_info.shares) - expected_shares_removed
        expected_epoch = before_provider_info.epoch
        expected_blessings_count = 2

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

    # Assert `Invoke` is emitted if absorber is not completely drained
    # Otherwise, check that user provision is updated
    if is_drained is False:
        expected_rewards_count = 2
        expected_invoke_epoch = before_provider_info.epoch
        assert_event_emitted(
            tx,
            absorber.contract_address,
            "Invoke",
            [
                expected_rewards_count,
                *[asset.contract_address for asset in reward_tokens],
                expected_rewards_count,
                *expected_rewards_amts,
                total_shares_wad,
                expected_invoke_epoch,
            ],
        )

    for asset_contract in yang_tokens:
        assert_event_emitted(
            tx, asset_contract.contract_address, "Transfer", lambda d: d[:2] == [absorber.contract_address, provider]
        )

    after_absorber_yin_bal_wad = from_uint((await shrine.balanceOf(absorber.contract_address).execute()).result.balance)
    assert after_absorber_yin_bal_wad == before_absorber_yin_bal_wad - yin_to_remove_wad

    # Check rewards
    for asset, before_bal, blessed_amt_wad in zip(reward_tokens, before_provider_reward_bals, expected_rewards_amts):
        asset_address = asset.contract_address

        assert_event_emitted(tx, asset_address, "Transfer", lambda d: d[:2] == [absorber.contract_address, provider])

        blessed_amt = from_wad(expected_blessings_count * blessed_amt_wad)
        after_provider_asset_bal = from_wad(from_uint((await asset.balanceOf(provider).execute()).result.balance))
        assert_equalish(after_provider_asset_bal, before_bal + blessed_amt)

    assert_provider_rewards_last_cumulative_updated(absorber, provider, reward_tokens_addresses, expected_epoch)


@pytest.mark.parametrize("update", [Decimal("1")], indirect=["update"])
@pytest.mark.usefixtures("add_aura_reward", "add_vested_aura_reward", "first_epoch_first_provider")
@pytest.mark.asyncio
async def test_provide_second_epoch(shrine, absorber, update, yangs, yang_tokens, blessing):
    # Epoch and total shares are already checked in `test_update` so we do not repeat here
    provider = PROVIDER_1

    _, _, _, before_epoch, _, _, _, _ = update
    reward_tokens, expected_rewards_amts = blessing
    reward_tokens_addresses = [asset.contract_address for asset in reward_tokens]

    yin_amt_to_provide_uint = (await shrine.balanceOf(provider).execute()).result.balance
    yin_amt_to_provide_wad = from_uint(yin_amt_to_provide_uint)
    before_provider_reward_bals = (await get_token_balances(reward_tokens, [provider]))[0]

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

    # Assets from first epoch's deposit should be transferred
    for asset_contract in yang_tokens:
        assert_event_emitted(
            tx, asset_contract.contract_address, "Transfer", lambda d: d[:2] == [absorber.contract_address, provider]
        )

    expected_blessings_count = 1
    # Rewards from first epoch's deposit should be transferred
    for asset, before_bal, blessed_amt_wad in zip(reward_tokens, before_provider_reward_bals, expected_rewards_amts):
        asset_address = asset.contract_address

        assert_event_emitted(tx, asset_address, "Transfer", lambda d: d[:2] == [absorber.contract_address, provider])

        blessed_amt = from_wad(expected_blessings_count * blessed_amt_wad)
        after_provider_asset_bal = from_wad(from_uint((await asset.balanceOf(provider).execute()).result.balance))
        assert_equalish(after_provider_asset_bal, before_bal + blessed_amt)

    assert_provider_rewards_last_cumulative_updated(absorber, provider, reward_tokens_addresses, expected_epoch)

    # Check that error has been transferred to new epoch, and no rewards were distributed
    # when provider 2 provided
    assert_reward_errors_propagated_to_next_epoch(absorber, reward_tokens_addresses, before_epoch)


@pytest.mark.parametrize(
    "update",
    [Decimal("0.999000000000000001"), Decimal("0.9999999991"), Decimal("0.99999999999999")],
    indirect=["update"],
)
@pytest.mark.usefixtures("add_aura_reward", "add_vested_aura_reward", "first_epoch_first_provider")
@pytest.mark.asyncio
async def test_provide_after_threshold_absorption(shrine, absorber, update, yangs, yang_tokens, blessing):
    """
    Sequence of events:
    1. Provider 1 provides (`first_epoch_first_provider`)
    2. Absorption occurs; yin per share falls below threshold (`update`), provider 1 receives 1 round of rewards
    3. Provider 2 provides, provider 1 receives 1 round of rewards
    4. Provider 1 withdraws, both providers share 1 round of rewards
    """
    first_provider = PROVIDER_1
    second_provider = PROVIDER_2

    tx, _, remaining_absorber_yin_wad, before_epoch, total_shares_wad, _, _, _ = update
    reward_tokens, expected_rewards_amts = blessing
    reward_tokens_addresses = [asset.contract_address for asset in reward_tokens]

    # Assert epoch is updated
    epoch = (await absorber.get_current_epoch().execute()).result.epoch
    expected_epoch = 1
    assert epoch == expected_epoch

    assert_event_emitted(tx, absorber.contract_address, "EpochChanged", [expected_epoch - 1, expected_epoch])

    # Assert share
    total_shares_wad = (await absorber.get_total_shares_for_current_epoch().execute()).result.total
    absorber_yin_bal_wad = from_uint((await shrine.balanceOf(absorber.contract_address).execute()).result.balance)
    assert total_shares_wad == absorber_yin_bal_wad

    # Step 3: Provider 2 provides
    second_provider_yin_amt_uint = (await shrine.balanceOf(second_provider).execute()).result.balance
    second_provider_yin_amt_wad = from_uint(second_provider_yin_amt_uint)
    second_provider_yin_amt = from_wad(second_provider_yin_amt_wad)

    tx = await absorber.provide(second_provider_yin_amt_wad).execute(caller_address=second_provider)

    # Assert `Invoke` is emitted
    expected_rewards_count = 2
    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Invoke",
        [
            expected_rewards_count,
            *[asset.contract_address for asset in reward_tokens],
            expected_rewards_count,
            *expected_rewards_amts,
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
    before_first_provider_bals = (await get_token_balances(reward_tokens, [first_provider]))[0]
    before_total_shares_wad = (await absorber.get_total_shares_for_current_epoch().execute()).result.total

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

    first_provider_after_threshold_rewards_perc = expected_converted_shares / from_wad(before_total_shares_wad)
    for asset, before_bal, blessed_amt_wad in zip(reward_tokens, before_first_provider_bals, expected_rewards_amts):
        asset_address = asset.contract_address

        assert_event_emitted(
            tx, asset_address, "Transfer", lambda d: d[:2] == [absorber.contract_address, first_provider]
        )

        # Provider 1 should receive 1 full round of blessings in the old epoch, and
        # 2 partial rounds of blessings in the new epoch
        expected_bless_amt = (Decimal("2") + first_provider_after_threshold_rewards_perc) * from_wad(blessed_amt_wad)
        after_provider_asset_bal = from_wad(from_uint((await asset.balanceOf(first_provider).execute()).result.balance))

        # Relax error margin due to precision loss from shares conversion across epochs
        error_margin = Decimal("0.01")
        assert_equalish(after_provider_asset_bal, before_bal + expected_bless_amt, error_margin)

    assert_provider_rewards_last_cumulative_updated(absorber, first_provider, reward_tokens_addresses, expected_epoch)

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
    reward_tokens, expected_rewards_amts = blessing
    reward_tokens_addresses = [asset.contract_address for asset in reward_tokens]

    first_provider = PROVIDER_1
    second_provider = PROVIDER_2

    # Step 3: Provider 2 provides
    second_provider_yin_amt_uint = (await shrine.balanceOf(second_provider).execute()).result.balance
    second_provider_yin_amt_wad = from_uint(second_provider_yin_amt_uint)

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
    asset_addresses, absorbed_asset_amts_orig, absorbed_asset_amts_dec_orig = second_update_assets
    absorbed_asset_amts = absorbed_asset_amts_orig.copy()
    absorbed_asset_amts_dec = absorbed_asset_amts_dec_orig.copy()
    if skipped_asset_idx is not None:
        absorbed_asset_amts[skipped_asset_idx] = 0
        absorbed_asset_amts_dec[skipped_asset_idx] = Decimal("0")

    await simulate_update(
        shrine,
        absorber,
        yang_tokens,
        asset_addresses,
        absorbed_asset_amts,
        second_provider_yin_amt_wad,
    )

    epoch = (await absorber.get_current_epoch().execute()).result.epoch
    expected_epoch = 2
    assert epoch == expected_epoch

    absorptions_count = (await absorber.get_absorptions_count().execute()).result.count
    expected_absorptions_count = 2
    assert absorptions_count == expected_absorptions_count

    total_shares = (await absorber.get_total_shares_for_current_epoch().execute()).result.total
    assert total_shares == 0

    providers = [first_provider, second_provider]
    before_providers_absorbed_bals = await get_token_balances(yang_tokens, providers)
    absorbed_amts_arrs = [first_absorbed_amts_dec, absorbed_asset_amts_dec]

    before_providers_reward_bals = await get_token_balances(reward_tokens, providers)

    for provider, before_absorbed_bals, before_reward_bals, absorbed_amts in zip(
        providers, before_providers_absorbed_bals, before_providers_reward_bals, absorbed_amts_arrs
    ):
        absorbed = (await absorber.preview_reap(provider).execute()).result
        assert absorbed.absorbed_assets == asset_addresses
        for asset_info, adjusted_expected, actual in zip(yangs, absorbed_amts, absorbed.absorbed_asset_amts):
            error_margin = custom_error_margin(asset_info.decimals // 2 - 1)
            adjusted_actual = from_fixed_point(actual, asset_info.decimals)
            assert_equalish(adjusted_expected, adjusted_actual, error_margin)

        max_withdrawable_yin_amt = from_wad((await absorber.preview_remove(provider).execute()).result.amount)
        assert max_withdrawable_yin_amt == 0

        # Step 5: Provider 1 and 2 reaps
        # There should be no rewards for this action since Absorber is emptied and there are no shares
        tx = await absorber.reap().execute(caller_address=provider)

        for idx, (asset, asset_info, before_absorbed_bal, absorbed_amt) in enumerate(
            zip(yang_tokens, yangs, before_absorbed_bals, absorbed_amts)
        ):
            if provider == second_provider and skipped_asset_idx is not None and idx == skipped_asset_idx:
                continue

            after_absorbed_bal = from_fixed_point(
                from_uint((await asset.balanceOf(provider).execute()).result.balance),
                asset_info.decimals,
            )

            # Relax error margin by half due to loss of precision from fixed point arithmetic
            error_margin = custom_error_margin(asset_info.decimals // 2 - 1)
            assert_equalish(after_absorbed_bal, before_absorbed_bal + absorbed_amt, error_margin)

            assert_event_emitted(
                tx, asset.contract_address, "Transfer", lambda d: d[:2] == [absorber.contract_address, provider]
            )

        for asset, before_reward_bal, blessed_amt_wad in zip(reward_tokens, before_reward_bals, expected_rewards_amts):
            asset_address = asset.contract_address

            assert_event_emitted(
                tx, asset_address, "Transfer", lambda d: d[:2] == [absorber.contract_address, provider]
            )

            # Each provider should receive 1 round of rewards
            blessed_amt = from_wad(blessed_amt_wad)

            after_reward_bal = from_wad(from_uint((await asset.balanceOf(provider).execute()).result.balance))
            assert_equalish(after_reward_bal, before_reward_bal + blessed_amt)

        assert_provider_rewards_last_cumulative_updated(absorber, provider, reward_tokens_addresses, expected_epoch)

        after_provider_info = (await absorber.get_provider_info(provider).execute()).result.provision
        assert after_provider_info.epoch == expected_epoch


@pytest.mark.usefixtures(
    "add_aura_reward", "add_vested_aura_reward", "first_epoch_first_provider", "first_epoch_second_provider"
)
@pytest.mark.parametrize("update", [Decimal("0.2")], indirect=["update"])
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

    _, percentage_drained, _, before_epoch, _, asset_addresses, _, absorbed_amts_dec = update
    asset_count = len(asset_addresses)
    is_drained = True if percentage_drained >= Decimal("1") else False

    reward_tokens, expected_rewards_amts = blessing
    reward_tokens_addresses = [asset.contract_address for asset in reward_tokens]

    _, first_provider_amt_wad = first_epoch_first_provider
    _, second_provider_amt_wad = first_epoch_second_provider

    first_provider_amt = from_wad(first_provider_amt_wad)
    second_provider_amt = from_wad(second_provider_amt_wad)
    total_provided_amt = first_provider_amt + second_provider_amt

    providers = [PROVIDER_1, PROVIDER_2]
    before_providers_absorbed_bals = await get_token_balances(yang_tokens, providers)
    before_providers_reward_bals = await get_token_balances(reward_tokens, providers)

    expected_epoch = 0
    expected_blessings_count = 2
    provided_perc = [first_provider_amt / total_provided_amt, second_provider_amt / total_provided_amt]
    for provider, percentage, before_absorbed_bals, before_reward_bals in zip(
        providers, provided_perc, before_providers_absorbed_bals, before_providers_reward_bals
    ):
        # Step 4: Providers 1 and 2 reaps
        tx = await absorber.reap().execute(caller_address=provider)

        # Rewards are distributed only if there are shares in current epoch
        # Otherwise, absorber is drained and epoch is incremented
        if is_drained is True:
            expected_epoch += 1
        else:
            expected_blessings_count += 1
            assert_event_emitted(tx, absorber.contract_address, "Invoke")

        assert_event_emitted(
            tx, absorber.contract_address, "Reap", lambda d: d[:5] == [provider, asset_count, *asset_addresses]
        )

        for asset, asset_info, before_absorbed_bal, absorbed_amt in zip(
            yang_tokens, yangs, before_absorbed_bals, absorbed_amts_dec
        ):
            assert_event_emitted(
                tx,
                asset.contract_address,
                "Transfer",
                lambda d: d[:2] == [absorber.contract_address, provider],
            )

            after_absorbed_bal = from_fixed_point(
                from_uint((await asset.balanceOf(provider).execute()).result.balance),
                asset_info.decimals,
            )

            # Relax error margin by half due to loss of precision from fixed point arithmetic
            error_margin = custom_error_margin(asset_info.decimals // 2 - 1)
            expected_reaped_amt = percentage * absorbed_amt
            assert_equalish(after_absorbed_bal, before_absorbed_bal + expected_reaped_amt, error_margin)

        expected_reward_multiplier = (expected_blessings_count - 1) * percentage

        # First provider gets a full round of rewards when second provider first provides
        if provider == PROVIDER_1:
            expected_reward_multiplier += Decimal("1")

        for asset, before_reward_bal, blessed_amt_wad in zip(reward_tokens, before_reward_bals, expected_rewards_amts):
            asset_address = asset.contract_address

            assert_event_emitted(
                tx, asset_address, "Transfer", lambda d: d[:2] == [absorber.contract_address, provider]
            )

            blessed_amt = expected_reward_multiplier * from_wad(blessed_amt_wad)
            after_reward_bal = from_wad(from_uint((await asset.balanceOf(provider).execute()).result.balance))
            assert_equalish(after_reward_bal, before_reward_bal + blessed_amt)

        assert_provider_rewards_last_cumulative_updated(absorber, provider, reward_tokens_addresses, expected_epoch)

        after_provider_info = (await absorber.get_provider_info(provider).execute()).result.provision
        assert after_provider_info.epoch == expected_epoch

        # Assert that provider cannot reap earlier rewards twice if it was drained
        if is_drained is True:
            with pytest.raises(StarkException, match="Absorber: Caller is not a provider in the current epoch"):
                await absorber.reap().execute(caller_address=provider)

    if is_drained is True:
        assert_reward_errors_propagated_to_next_epoch(absorber, reward_tokens_addresses, before_epoch)


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
    first_provider = PROVIDER_1
    second_provider = PROVIDER_2

    _, _, remaining_yin_wad, expected_epoch, _, asset_addresses, _, first_absorbed_amts_dec = update
    asset_count = len(asset_addresses)

    reward_tokens, expected_rewards_amts = blessing
    reward_tokens_addresses = [asset.contract_address for asset in reward_tokens]

    # Step 3: Provider 2 pprovides
    second_provider_yin_amt_uint = (await shrine.balanceOf(second_provider).execute()).result.balance
    second_provider_yin_amt_wad = from_uint(second_provider_yin_amt_uint)
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
        asset_addresses,
        second_absorbed_amts,
        second_update_burn_amt_wad,
    )

    providers = [first_provider, second_provider]
    providers_remaining_yin = [first_provider_amt, second_provider_amt]
    before_providers_absorbed_bals = await get_token_balances(yang_tokens, providers)
    before_providers_reward_bals = await get_token_balances(reward_tokens, providers)

    expected_blessings_count = 3
    provided_perc = [amt / total_provided_amt for amt in providers_remaining_yin]
    for provider, percentage, remaining_yin, before_absorbed_bals, before_reward_bals in zip(
        providers, provided_perc, providers_remaining_yin, before_providers_absorbed_bals, before_providers_reward_bals
    ):
        # Steps 5 and 6: Providers 1 and 2 reaps
        tx = await absorber.reap().execute(caller_address=provider)

        assert_event_emitted(
            tx, absorber.contract_address, "Reap", lambda d: d[:5] == [provider, asset_count, *asset_addresses]
        )
        assert_event_emitted(tx, absorber.contract_address, "Invoke")

        expected_blessings_count += 1

        for asset, asset_info, before_absorbed_bal, first_absorbed_amt, second_absorbed_amt in zip(
            yang_tokens, yangs, before_absorbed_bals, first_absorbed_amts_dec, second_absorbed_amts_dec
        ):
            assert_event_emitted(
                tx,
                asset.contract_address,
                "Transfer",
                lambda d: d[:2] == [absorber.contract_address, provider],
            )

            after_bal = from_fixed_point(
                from_uint((await asset.balanceOf(provider).execute()).result.balance),
                asset_info.decimals,
            )

            # Relax error margin by half due to loss of precision from fixed point arithmetic
            error_margin = custom_error_margin(asset_info.decimals // 2 - 1)
            expected_reaped_amt = percentage * second_absorbed_amt

            if provider == first_provider:
                expected_reaped_amt += first_absorbed_amt

            assert_equalish(after_bal, before_absorbed_bal + expected_reaped_amt, error_margin)

        max_withdrawable_yin_amt = from_wad((await absorber.preview_remove(provider).execute()).result.amount)
        expected_remaining_yin = remaining_yin - (percentage * from_wad(second_update_burn_amt_wad))
        assert_equalish(max_withdrawable_yin_amt, expected_remaining_yin)

        expected_reward_multiplier = (expected_blessings_count - 2) * percentage
        # First provider gets 2 rounds of rewards
        if provider == PROVIDER_1:
            expected_reward_multiplier += Decimal("2")

        for asset, before_reward_bal, blessed_amt_wad in zip(reward_tokens, before_reward_bals, expected_rewards_amts):
            asset_address = asset.contract_address

            assert_event_emitted(
                tx, asset_address, "Transfer", lambda d: d[:2] == [absorber.contract_address, provider]
            )

            blessed_amt = expected_reward_multiplier * from_wad(blessed_amt_wad)
            after_reward_bal = from_wad(from_uint((await asset.balanceOf(provider).execute()).result.balance))
            assert_equalish(after_reward_bal, before_reward_bal + blessed_amt)

        assert_provider_rewards_last_cumulative_updated(absorber, provider, reward_tokens_addresses, expected_epoch)

        after_provider_info = (await absorber.get_provider_info(provider).execute()).result.provision
        assert after_provider_info.epoch == expected_epoch


@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.asyncio
async def test_non_provider_fail(shrine, absorber):
    provider = NON_PROVIDER
    with pytest.raises(StarkException, match="Absorber: Caller is not a provider in the current epoch"):
        await absorber.remove(0).execute(caller_address=provider)

    with pytest.raises(StarkException, match="Absorber: Caller is not a provider in the current epoch"):
        await absorber.remove(MAX_REMOVE_AMT).execute(caller_address=provider)

    with pytest.raises(StarkException, match="Absorber: Caller is not a provider in the current epoch"):
        await absorber.reap().execute(caller_address=provider)

    removable_yin = (await absorber.preview_remove(provider).execute()).result.amount
    assert removable_yin == 0

    absorbed = (await absorber.preview_reap(provider).execute()).result
    assert absorbed.absorbed_assets == []
    assert absorbed.absorbed_asset_amts == []


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
# Tests - Invoke
#


@pytest.mark.usefixtures("add_aura_reward", "add_vested_aura_reward", "first_epoch_first_provider")
@pytest.mark.asyncio
async def test_invoke_inactive_reward(
    absorber, aura_token, vested_aura_token, aura_token_blesser, vested_aura_token_blesser
):
    """
    Inactive rewards should be skipped when `invoke` is called.
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

    # Trigger an invoke
    tx = await absorber.provide(0).execute(caller_address=provider)

    expected_rewards_count = 1
    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Invoke",
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
async def test_invoke_zero_distribution_from_active_rewards(
    absorber, aura_token_blesser, vested_aura_token_blesser, blessing
):
    """
    Check for early return when no rewards are distributed because the vesting contracts
    of active rewards did not distribute any
    """
    provider = PROVIDER_1

    reward_tokens, _ = blessing
    blessers = [aura_token_blesser, vested_aura_token_blesser]
    for asset, blesser in zip(reward_tokens, blessers):
        await absorber.set_reward(
            asset.contract_address,
            blesser.contract_address,
            TRUE,
        ).execute(caller_address=ABSORBER_OWNER)

    expected_epoch = 0
    before_rewards_cumulative = []
    for asset in reward_tokens:
        cumulative = (
            await absorber.get_asset_reward_info(asset.contract_address, expected_epoch).execute()
        ).result.info.asset_amt_per_share
        before_rewards_cumulative.append(cumulative)

    # Trigger an invoke
    await absorber.provide(0).execute(caller_address=provider)

    after_rewards_cumulative = []
    for asset in reward_tokens:
        cumulative = (
            await absorber.get_asset_reward_info(asset.contract_address, expected_epoch).execute()
        ).result.info.asset_amt_per_share
        after_rewards_cumulative.append(cumulative)

    assert before_rewards_cumulative == after_rewards_cumulative


@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.asyncio
async def test_invoke_pass_with_depleted_active_reward(
    absorber, aura_token, aura_token_blesser, vested_aura_token, vested_aura_token_blesser
):
    """
    Check that `invoke` works as intended when one of more than one active rewards does not have any distribution
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

    # Trigger an invoke
    tx = await absorber.provide(0).execute(caller_address=provider)
    expected_rewards_count = 2
    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Invoke",
        lambda d: d[:6]
        == [
            expected_rewards_count,
            *[vested_aura_token.contract_address, aura_token.contract_address],
            expected_rewards_count,
            *[0, AURA_BLESS_AMT_WAD],
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


# TODO: enchmarking; delete before merge
@pytest.mark.usefixtures("add_aura_reward", "add_vested_aura_reward", "first_epoch_first_provider")
@pytest.mark.parametrize("blessings_count", [0, 1, 2, 5, 10, 35, 100, 200, 500])
@pytest.mark.asyncio
async def test_provide_varying_blessings_count(
    shrine, absorber, yang_tokens, first_update_assets, blessings_count, aura_token, blessing
):
    provider = PROVIDER_1

    _, expected_rewards_amts = blessing
    before_aura_token_bal = from_uint((await aura_token.balanceOf(provider).execute()).result.balance)

    other_provider = PROVIDER_2
    for i in range(blessings_count):
        await absorber.provide(1).execute(caller_address=other_provider)

    tx = await absorber.reap().execute(caller_address=provider)
    blessings_count += 1

    after_aura_token_bal = from_uint((await aura_token.balanceOf(provider).execute()).result.balance)
    assert_equalish(
        from_wad(after_aura_token_bal),
        from_wad(before_aura_token_bal + blessings_count * expected_rewards_amts[1]),
    )

    print("Reap for {} blessings: {}".format(blessings_count, estimate_gas(tx)))
    print("Resources: ", tx.call_info.execution_resources)
