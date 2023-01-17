from decimal import Decimal

import pytest
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.objects import StarknetCallInfo
from starkware.starkware_utils.error_handling import StarkException

from tests.absorber.constants import *  # noqa: F403
from tests.shrine.constants import FEED_LEN, MAX_PRICE_CHANGE, MULTIPLIER_FEED
from tests.utils import (
    ABSORBER_OWNER,
    BAD_GUY,
    SHRINE_OWNER,
    TIME_INTERVAL,
    TROVE1_OWNER,
    TROVE2_OWNER,
    TROVE3_OWNER,
    TROVE_1,
    TROVE_2,
    TROVE_3,
    TRUE,
    WAD_RAY_OOB_VALUES,
    YangConfig,
    assert_equalish,
    assert_event_emitted,
    calculate_max_forge,
    compile_code,
    create_feed,
    custom_error_margin,
    from_fixed_point,
    from_ray,
    from_uint,
    from_wad,
    get_contract_code_with_addition,
    get_contract_code_with_replacement,
    get_token_balances,
    max_approve,
    set_block_timestamp,
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
    asset_addresses: List[int]
        Ordered list of token contract addresses for the freed assets
    asset_amts: list[int]
        Ordered list of amount of each asset to transfer to the absorber
        in wad.
    yin_amt_to_burn_wad:
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


#
# Fixtures
#


@pytest.fixture
async def first_update_assets(yangs) -> tuple[list[int]]:
    """
    Helper fixture to return a tuple of a list of asset addresses
    and a list of asset amounts.
    """
    asset_addresses = [asset_info.contract_address for asset_info in yangs]
    asset_amts = [
        to_fixed_point(i, asset_info.decimals)
        for i, asset_info in zip(
            FIRST_UPDATE_ASSETS_AMT,
            yangs,
        )
    ]
    return asset_addresses, asset_amts


@pytest.fixture
async def second_update_assets(yangs) -> tuple[list[int]]:
    """
    Helper fixture to return a tuple of a list of asset addresses
    and a list of asset amounts.
    """
    asset_addresses = [asset_info.contract_address for asset_info in yangs]
    asset_amts = [
        to_fixed_point(i, asset_info.decimals)
        for i, asset_info in zip(
            SECOND_UPDATE_ASSETS_AMT,
            yangs,
        )
    ]
    return asset_addresses, asset_amts


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
    return absorber


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
async def forged_troves(shrine, shrine_feeds, abbot, sentinel_with_yangs, yangs, funded_trove_owners) -> list[int]:
    forged_amts = []

    troves = [TROVE_1, TROVE_2, TROVE_3]
    trove_owners = [TROVE1_OWNER, TROVE2_OWNER, TROVE3_OWNER]
    for trove, owner in zip(troves, trove_owners):
        prices = []

        for yang in yangs:
            price = from_wad((await shrine.get_current_yang_price(yang.contract_address).execute()).result.price)
            prices.append(price)

        # Get maximum forge amount
        deposit_amts = [USER_STETH_DEPOSIT_WAD, USER_DOGE_DEPOSIT_WAD, USER_WBTC_DEPOSIT_AMT]
        amounts = [from_fixed_point(amt, yang.decimals) for amt, yang in zip(deposit_amts, yangs)]

        thresholds = [from_ray(yang.threshold) for yang in yangs]
        max_forge_amt = calculate_max_forge(prices, amounts, thresholds)

        forge_amt = to_wad(max_forge_amt - 1)

        await abbot.open_trove(
            forge_amt,
            [yang.contract_address for yang in yangs],
            deposit_amts,
        ).execute(caller_address=owner)

        forged_amts.append(forge_amt)

    return forged_amts


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
async def first_epoch_first_provider(shrine, absorber, forged_troves, funded_absorber_providers):
    provider = PROVIDER_1
    provider_yin_amt_uint = (await shrine.balanceOf(provider).execute()).result.balance
    provide_yin_amt = from_uint(provider_yin_amt_uint) // 2

    tx = await absorber.provide(provide_yin_amt).execute(caller_address=provider)
    return tx, provide_yin_amt


@pytest.fixture
async def first_epoch_second_provider(shrine, absorber, forged_troves, funded_absorber_providers):
    provider = PROVIDER_2
    provider_yin_amt_uint = (await shrine.balanceOf(provider).execute()).result.balance
    provide_yin_amt = from_uint(provider_yin_amt_uint)

    tx = await absorber.provide(provide_yin_amt).execute(caller_address=provider)
    return tx, provide_yin_amt


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
    asset_addresses, asset_amts = first_update_assets
    tx, asset_addresses, asset_amts = await simulate_update(
        shrine,
        absorber,
        yang_tokens,
        asset_addresses,
        asset_amts,
        burn_amt_wad,
    )

    remaining_amt_wad = absorber_yin_bal_wad - burn_amt_wad
    return tx, percentage_to_drain, remaining_amt_wad, epoch, total_shares_wad, asset_addresses, asset_amts


#
# Tests
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


@pytest.mark.asyncio
async def test_provide_first_epoch(shrine, absorber, first_epoch_first_provider):
    provider = PROVIDER_1

    tx, initial_yin_amt_provided = first_epoch_first_provider
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


@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.parametrize("update", [Decimal("0.2"), Decimal("1")], indirect=["update"])
@pytest.mark.asyncio
async def test_update(shrine, absorber, update, yangs, yang_tokens):
    tx, percentage_to_drain, _, before_epoch, before_total_shares_wad, assets, asset_amts = update
    asset_count = len(assets)

    before_total_shares = from_wad(before_total_shares_wad)

    expected_gain_epoch = 0
    assert_event_emitted(
        tx,
        absorber.contract_address,
        "Gain",
        [asset_count, *assets, asset_count, *asset_amts, before_total_shares_wad, expected_gain_epoch],
    )

    expected_absorption_id = 1
    actual_absorption_id = (await absorber.get_absorptions_count().execute()).result.count
    assert actual_absorption_id == expected_absorption_id

    for asset, amt in zip(yangs, FIRST_UPDATE_ASSETS_AMT):
        asset_address = asset.contract_address
        asset_absorption_info = (
            await absorber.get_asset_absorption_info(expected_absorption_id, asset_address).execute()
        ).result.info
        actual_asset_amt_per_share = from_fixed_point(asset_absorption_info.asset_amt_per_share, asset.decimals)

        expected_asset_amt_per_share = Decimal(amt) / before_total_shares

        error_margin = custom_error_margin(asset.decimals)
        assert_equalish(actual_asset_amt_per_share, expected_asset_amt_per_share, error_margin)

    # If absorber is fully drained of its yin balance, check that epoch has increased
    # and total shares is set to 0.
    if percentage_to_drain == Decimal("1"):
        current_epoch = (await absorber.get_current_epoch().execute()).result.epoch
        assert current_epoch == before_epoch + 1

        after_total_shares_wad = (await absorber.get_total_shares_for_current_epoch().execute()).result.total
        assert after_total_shares_wad == 0


@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.parametrize("update", [Decimal("0.2"), Decimal("1")], indirect=["update"])
@pytest.mark.asyncio
async def test_reap(shrine, absorber, update, yangs, yang_tokens):
    provider = PROVIDER_1

    _, _, _, _, _, assets, asset_amts = update
    asset_count = len(assets)

    # Fetch user balances before `reap`
    before_provider_asset_bals = (await get_token_balances(yangs, yang_tokens, [provider]))[0]
    before_provider_last_absorption = (
        await absorber.get_provider_last_absorption(provider).execute()
    ).result.absorption_id

    tx = await absorber.reap().execute(caller_address=provider)

    assert_event_emitted(tx, absorber.contract_address, "Reap", lambda d: d[:5] == [provider, asset_count, *assets])

    # Check that provider 1 receives all assets from first provision
    for asset_contract, asset_info, before_bal, absorbed_amt in zip(
        yang_tokens, yangs, before_provider_asset_bals, FIRST_UPDATE_ASSETS_AMT
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


@pytest.mark.parametrize("update", [Decimal("0"), Decimal("0.2"), Decimal("1")], indirect=["update"])
@pytest.mark.parametrize("percentage_to_remove", [Decimal("0"), Decimal("0.25"), Decimal("0.667"), Decimal("1")])
@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.asyncio
async def test_remove(shrine, absorber, update, yangs, yang_tokens, percentage_to_remove):
    provider = PROVIDER_1

    _, percentage_drained, _, _, total_shares_wad, assets, asset_amts = update

    before_provider_yin_bal = from_wad(from_uint((await shrine.balanceOf(provider).execute()).result.balance))
    before_provider_info = (await absorber.get_provider_info(provider).execute()).result.provision
    before_provider_last_absorption = (
        await absorber.get_provider_last_absorption(provider).execute()
    ).result.absorption_id

    before_absorber_yin_bal_wad = from_uint(
        (await shrine.balanceOf(absorber.contract_address).execute()).result.balance
    )

    if percentage_drained == Decimal("1"):
        yin_to_remove_wad = 0
        expected_shares = Decimal("0")
        expected_epoch = before_provider_info.epoch + 1

    else:
        max_removable_yin = (await absorber.get_provider_yin(provider).execute()).result.amount
        yin_to_remove_wad = int(percentage_to_remove * max_removable_yin)
        expected_shares_removed = from_wad(
            (await absorber.convert_to_shares(yin_to_remove_wad, TRUE).execute()).result.provider_shares
        )
        expected_shares = from_wad(before_provider_info.shares) - expected_shares_removed
        expected_epoch = before_provider_info.epoch

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

    for asset_contract in yang_tokens:
        assert_event_emitted(
            tx, asset_contract.contract_address, "Transfer", lambda d: d[:2] == [absorber.contract_address, provider]
        )

    after_absorber_yin_bal_wad = from_uint((await shrine.balanceOf(absorber.contract_address).execute()).result.balance)
    assert after_absorber_yin_bal_wad == before_absorber_yin_bal_wad - yin_to_remove_wad


@pytest.mark.parametrize("update", [Decimal("1")], indirect=["update"])
@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.asyncio
async def test_provide_second_epoch(shrine, absorber, update, yangs, yang_tokens):
    # Epoch and total shares are already checked in `test_update` so we do not repeat here
    provider = PROVIDER_1

    yin_amt_to_provide_uint = (await shrine.balanceOf(provider).execute()).result.balance
    yin_amt_to_provide_wad = from_uint(yin_amt_to_provide_uint)

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


@pytest.mark.parametrize("update", [Decimal("0.9999999991"), Decimal("0.99999999999999")], indirect=["update"])
@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.asyncio
async def test_provide_after_threshold_absorption(shrine, absorber, update, yangs, yang_tokens):
    """
    Sequence of events:
    1. Provider 1 provides (`first_epoch_first_provider`)
    2. Absorption occurs; yin per share falls below threshold (`update`)
    3. Provider 2 provides
    4. Provider 1 withdraws
    """
    first_provider = PROVIDER_1
    second_provider = PROVIDER_2

    _, _, remaining_absorber_yin_wad, _, total_shares_wad, _, _ = update

    # Assert epoch is updated
    epoch = (await absorber.get_current_epoch().execute()).result.epoch
    expected_epoch = 1
    assert epoch == expected_epoch

    # Assert share
    total_shares_wad = (await absorber.get_total_shares_for_current_epoch().execute()).result.total
    absorber_yin_bal_wad = from_uint((await shrine.balanceOf(absorber.contract_address).execute()).result.balance)
    assert total_shares_wad == absorber_yin_bal_wad

    # Provider 2 provides
    second_provider_yin_amt_uint = (await shrine.balanceOf(second_provider).execute()).result.balance
    second_provider_yin_amt_wad = from_uint(second_provider_yin_amt_uint)
    second_provider_yin_amt = from_wad(second_provider_yin_amt_wad)

    await absorber.provide(second_provider_yin_amt_wad).execute(caller_address=second_provider)

    # Provider 2 can withdraw up to amount provided
    max_withdrawable_yin_amt = from_wad((await absorber.get_provider_yin(second_provider).execute()).result.amount)
    assert_equalish(max_withdrawable_yin_amt, second_provider_yin_amt)

    # First provider can withdraw a non-zero amount of yin corresponding to what was left in the
    # absorber after absorption past the threshold
    before_first_provider_yin_amt_wad = from_uint((await shrine.balanceOf(first_provider).execute()).result.balance)
    before_first_provider_info = (await absorber.get_provider_info(first_provider).execute()).result.provision

    await absorber.remove(MAX_REMOVE_AMT).execute(caller_address=first_provider)

    after_first_provider_info = (await absorber.get_provider_info(first_provider).execute()).result.provision
    assert after_first_provider_info.shares == 0
    assert after_first_provider_info.epoch == expected_epoch

    after_first_provider_yin_amt_wad = from_uint((await shrine.balanceOf(first_provider).execute()).result.balance)
    expected_removed_yin = from_wad(remaining_absorber_yin_wad)
    removed_yin = from_wad(after_first_provider_yin_amt_wad - before_first_provider_yin_amt_wad)

    absorber_yin_bal_wad = from_uint(
        (await shrine.balanceOf(absorber.contract_address).execute()).result.balance
    )  # Debug
    assert_equalish(removed_yin, expected_removed_yin)

    expected_converted_shares = from_wad(
        (
            await absorber.convert_epoch_shares(epoch - 1, epoch, before_first_provider_info.shares).execute()
        ).result.shares
    )
    assert_equalish(removed_yin, expected_converted_shares)


@pytest.mark.parametrize("update", [Decimal("1")], indirect=["update"])
@pytest.mark.usefixtures("first_epoch_first_provider", "update")
@pytest.mark.asyncio
async def test_reap_different_epochs(shrine, absorber, yangs, yang_tokens, second_update_assets):
    """
    Sequence of events:
    1. Provider 1 provides
    2. Entire absorber's balance is used for an absorption
    3. Provider 2 provides
    4. Entire absorber's balance is used for an absorption
    5. Provider 1 and 2 reaps.
       Provider 1 should receive assets from first update.
       Provider 2 should receive assets from second update.
    """
    first_provider = PROVIDER_1
    second_provider = PROVIDER_2

    # Provider 2 provides
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

    # Drain again
    asset_addresses, asset_amts = second_update_assets
    await simulate_update(
        shrine,
        absorber,
        yang_tokens,
        asset_addresses,
        asset_amts,
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
    before_provider_bals = await get_token_balances(yangs, yang_tokens, providers)
    absorbed_amts_arrs = [FIRST_UPDATE_ASSETS_AMT, SECOND_UPDATE_ASSETS_AMT]

    for provider, before_bals, absorbed_amts in zip(providers, before_provider_bals, absorbed_amts_arrs):

        # Second provider reaps
        tx = await absorber.reap().execute(caller_address=provider)

        for asset, asset_info, before_bal, absorbed_amt in zip(yang_tokens, yangs, before_bals, absorbed_amts):
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
            assert_equalish(after_bal, before_bal + absorbed_amt, error_margin)


@pytest.mark.parametrize("update", [Decimal("0.2"), Decimal("1")], indirect=["update"])
@pytest.mark.usefixtures("first_epoch_first_provider", "first_epoch_second_provider")
@pytest.mark.asyncio
async def test_multi_user_reap_same_epoch(
    shrine, absorber, first_epoch_first_provider, first_epoch_second_provider, yangs, yang_tokens, update
):
    """
    Sequence of events:
    1. Providers 1 and 2 provide
    2. Absorption happens
    3. Providers 1 and 2 reaps
    """
    _, _, _, _, _, asset_addresses, _ = update
    absorbed_amts = FIRST_UPDATE_ASSETS_AMT
    asset_count = len(asset_addresses)

    _, first_provider_amt_wad = first_epoch_first_provider
    _, second_provider_amt_wad = first_epoch_second_provider

    first_provider_amt = from_wad(first_provider_amt_wad)
    second_provider_amt = from_wad(second_provider_amt_wad)
    total_provided_amt = first_provider_amt + second_provider_amt

    providers = [PROVIDER_1, PROVIDER_2]
    before_provider_bals = await get_token_balances(yangs, yang_tokens, providers)

    provided_perc = [first_provider_amt / total_provided_amt, second_provider_amt / total_provided_amt]
    for provider, percentage, before_bals in zip(providers, provided_perc, before_provider_bals):
        tx = await absorber.reap().execute(caller_address=provider)

        assert_event_emitted(
            tx, absorber.contract_address, "Reap", lambda d: d[:5] == [provider, asset_count, *asset_addresses]
        )

        for asset, asset_info, before_bal, absorbed_amt in zip(yang_tokens, yangs, before_bals, absorbed_amts):
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
            expected_reaped_amt = percentage * absorbed_amt
            assert_equalish(after_bal, before_bal + expected_reaped_amt, error_margin)


@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.asyncio
async def test_non_provider_fail(shrine, absorber):
    with pytest.raises(StarkException, match="Absorber: Caller is not a provider"):
        await absorber.remove(0).execute(caller_address=NON_PROVIDER)

    with pytest.raises(StarkException, match="Absorber: Caller is not a provider"):
        await absorber.remove(MAX_REMOVE_AMT).execute(caller_address=NON_PROVIDER)

    with pytest.raises(StarkException, match="Absorber: Caller is not a provider"):
        await absorber.reap().execute(caller_address=NON_PROVIDER)

    removable_yin = (await absorber.get_provider_yin(NON_PROVIDER).execute()).result.amount
    assert removable_yin == 0


@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.asyncio
async def test_unauthorized_update(shrine, absorber, first_update_assets):
    asset_addresses, asset_amts = first_update_assets
    with pytest.raises(StarkException, match="Absorber: Only Purger can call `update`"):
        await absorber.update(asset_addresses, asset_amts).execute(caller_address=BAD_GUY)


@pytest.mark.usefixtures("funded_absorber_providers")
@pytest.mark.asyncio
async def test_provide_fail(shrine, absorber):
    provider = PROVIDER_1

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


@pytest.mark.parametrize("amt", WAD_RAY_OOB_VALUES)
@pytest.mark.asyncio
async def test_provide_out_of_bounds_fail(absorber, amt):
    provider = PROVIDER_1
    # Negative amount
    with pytest.raises(StarkException, match=r"Absorber: Value of `amount` \(-?\d+\) is out of bounds"):
        await absorber.provide(amt).execute(caller_address=provider)


@pytest.mark.usefixtures("first_epoch_first_provider")
@pytest.mark.parametrize("amt", WAD_RAY_OOB_VALUES)
@pytest.mark.asyncio
async def test_remove_out_of_bounds_fail(absorber, amt):
    provider = PROVIDER_1
    # Negative amount
    with pytest.raises(StarkException, match=r"Absorber: Value of `amount` \(-?\d+\) is out of bounds"):
        await absorber.remove(amt).execute(caller_address=provider)


@pytest.mark.asyncio
async def test_purger_zero_address(absorber_deploy, yangs, first_update_assets):
    absorber = absorber_deploy
    zero_address = 0
    with pytest.raises(StarkException, match="Absorber: Purger address cannot be zero"):
        await absorber.set_purger(zero_address).execute(caller_address=ABSORBER_OWNER)

    asset_addresses, asset_amts = first_update_assets
    with pytest.raises(StarkException, match="Absorber: Purger address cannot be zero"):
        await absorber.update(asset_addresses, asset_amts).execute(caller_address=MOCK_PURGER)
