mod AbsorberUtils {
    use array::{ArrayTrait, SpanTrait};
    use cmp::min;
    use integer::BoundedU256;
    use option::OptionTrait;
    use starknet::{
        contract_address_const, deploy_syscall, ClassHash, class_hash_try_from_felt252,
        ContractAddress, contract_address_to_felt252, contract_address_try_from_felt252,
        SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;
    use traits::{Default, Into, TryInto};
    use zeroable::Zeroable;

    use aura::core::absorber::Absorber;
    use aura::core::roles::AbsorberRoles;

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IAbsorber::{
        IAbsorberDispatcher, IAbsorberDispatcherTrait, IBlesserDispatcher, IBlesserDispatcherTrait
    };
    use aura::interfaces::IERC20::{
        IERC20Dispatcher, IERC20DispatcherTrait, IMintableDispatcher, IMintableDispatcherTrait
    };
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::types::{AssetBalance, DistributionInfo, Reward};
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, Wad, WadZeroable, WAD_ONE, WAD_SCALE};

    use aura::tests::abbot::utils::AbbotUtils;
    use aura::tests::absorber::mock_blesser::MockBlesser;
    use aura::tests::common;
    use aura::tests::erc20::ERC20;
    use aura::tests::shrine::utils::ShrineUtils;

    use debug::PrintTrait;

    //
    // Constants
    //

    const BLESSER_REWARD_TOKEN_BALANCE: u128 = 100000000000000000000000; // 100_000 (Wad)

    const AURA_BLESS_AMT: u128 = 1000000000000000000000; // 1_000 (Wad)
    const VEAURA_BLESS_AMT: u128 = 990000000000000000000; // 990 (Wad)

    const REMOVAL_LIMIT: u128 = 900000000000000000000000000; // 90% (Ray)

    #[inline(always)]
    fn provider_asset_amts() -> Span<u128> {
        let mut asset_amts: Array<u128> = Default::default();
        asset_amts.append(20 * WAD_ONE); // 10 (Wad) - ETH
        asset_amts.append(100000000); // 1 (10 ** 8) - BTC
        asset_amts.span()
    }

    #[inline(always)]
    fn first_update_assets() -> Span<u128> {
        let mut asset_amts: Array<u128> = Default::default();
        asset_amts.append(1230000000000000000); // 1.23 (Wad) - ETH
        asset_amts.append(23700000); // 0.237 (10 ** 8) - BTC
        asset_amts.span()
    }

    #[inline(always)]
    fn second_update_assets() -> Span<u128> {
        let mut asset_amts: Array<u128> = Default::default();
        asset_amts.append(572000000000000000); // 0.572 (Wad) - ETH
        asset_amts.append(65400000); // 0.654 (10 ** 8) - BTC
        asset_amts.span()
    }

    //
    // Address constants
    //

    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('absorber owner').unwrap()
    }

    fn provider_1() -> ContractAddress {
        contract_address_try_from_felt252('provider 1').unwrap()
    }

    fn provider_2() -> ContractAddress {
        contract_address_try_from_felt252('provider 2').unwrap()
    }

    fn mock_purger() -> ContractAddress {
        contract_address_try_from_felt252('mock purger').unwrap()
    }

    //
    // Test setup helpers
    // 

    fn absorber_deploy() -> (
        IShrineDispatcher,
        ISentinelDispatcher,
        IAbbotDispatcher,
        IAbsorberDispatcher,
        Span<ContractAddress>,
        Span<IGateDispatcher>
    ) {
        let (shrine, sentinel, abbot, yangs, gates) = AbbotUtils::abbot_deploy();

        let admin: ContractAddress = admin();

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(admin));
        calldata.append(contract_address_to_felt252(shrine.contract_address));
        calldata.append(contract_address_to_felt252(sentinel.contract_address));
        calldata.append(REMOVAL_LIMIT.into());

        let absorber_class_hash: ClassHash = class_hash_try_from_felt252(Absorber::TEST_CLASS_HASH)
            .unwrap();
        let (absorber_addr, _) = deploy_syscall(absorber_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        set_contract_address(admin);
        let absorber_ac = IAccessControlDispatcher { contract_address: absorber_addr };
        absorber_ac.grant_role(AbsorberRoles::UPDATE, mock_purger());
        set_contract_address(ContractAddressZeroable::zero());

        let absorber = IAbsorberDispatcher { contract_address: absorber_addr };
        (shrine, sentinel, abbot, absorber, yangs, gates)
    }

    fn aura_token_deploy() -> ContractAddress {
        common::deploy_token('Aura', 'AURA', 18, 0_u256, admin())
    }

    fn veaura_token_deploy() -> ContractAddress {
        common::deploy_token('veAura', 'veAURA', 18, 0_u256, admin())
    }

    // Convenience fixture for reward token addresses constants
    fn reward_tokens_deploy() -> Span<ContractAddress> {
        let mut reward_tokens: Array<ContractAddress> = Default::default();
        reward_tokens.append(aura_token_deploy());
        reward_tokens.append(veaura_token_deploy());
        reward_tokens.span()
    }

    // Convenience fixture for reward amounts
    fn reward_amts_per_blessing() -> Span<u128> {
        let mut bless_amts: Array<u128> = Default::default();
        bless_amts.append(AURA_BLESS_AMT);
        bless_amts.append(VEAURA_BLESS_AMT);
        bless_amts.span()
    }

    // Helper function to deploy a blesser for a token.
    // Mints tokens to the deployed blesser if `mint_to_blesser` is `true`.
    fn deploy_blesser_for_reward(
        absorber: IAbsorberDispatcher,
        asset: ContractAddress,
        bless_amt: u128,
        mint_to_blesser: bool
    ) -> ContractAddress {
        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(admin()));
        calldata.append(contract_address_to_felt252(asset));
        calldata.append(contract_address_to_felt252(absorber.contract_address));
        calldata.append(bless_amt.into());

        let mock_blesser_class_hash: ClassHash = class_hash_try_from_felt252(
            MockBlesser::TEST_CLASS_HASH
        )
            .unwrap();
        let (mock_blesser_addr, _) = deploy_syscall(
            mock_blesser_class_hash, 0, calldata.span(), false
        )
            .unwrap_syscall();

        if mint_to_blesser {
            let token_minter = IMintableDispatcher { contract_address: asset };
            token_minter.mint(mock_blesser_addr, BLESSER_REWARD_TOKEN_BALANCE.into());
        }

        mock_blesser_addr
    }

    // Wrapper function to deploy blessers for an array of reward tokens and return an array
    // of the blesser contract addresses.
    fn deploy_blesser_for_rewards(
        absorber: IAbsorberDispatcher, mut assets: Span<ContractAddress>, mut bless_amts: Span<u128>
    ) -> Span<ContractAddress> {
        let mut blessers: Array<ContractAddress> = Default::default();

        loop {
            match assets.pop_front() {
                Option::Some(asset) => {
                    let blesser: ContractAddress = deploy_blesser_for_reward(
                        absorber, *asset, *bless_amts.pop_front().unwrap(), true
                    );
                    blessers.append(blesser);
                },
                Option::None(_) => {
                    break;
                },
            };
        };

        blessers.span()
    }

    fn add_rewards_to_absorber(
        absorber: IAbsorberDispatcher,
        mut tokens: Span<ContractAddress>,
        mut blessers: Span<ContractAddress>
    ) {
        set_contract_address(admin());

        loop {
            match tokens.pop_front() {
                Option::Some(token) => {
                    absorber.set_reward(*token, *blessers.pop_front().unwrap(), true);
                },
                Option::None(_) => {
                    break;
                },
            };
        };

        set_contract_address(ContractAddressZeroable::zero());
    }

    fn absorber_with_first_provider() -> (
        IShrineDispatcher,
        ISentinelDispatcher,
        IAbbotDispatcher,
        IAbsorberDispatcher,
        Span<ContractAddress>, // yangs
        Span<IGateDispatcher>,
        ContractAddress, // provider
        Wad, // provided amount
    ) {
        let (shrine, sentinel, abbot, absorber, yangs, gates) = absorber_deploy();

        let provider = provider_1();
        let provided_amt: Wad = 10000000000000000000000_u128.into(); // 10_000 (Wad)
        provide_to_absorber(
            shrine, abbot, absorber, provider, yangs, provider_asset_amts(), gates, provided_amt
        );

        (shrine, sentinel, abbot, absorber, yangs, gates, provider, provided_amt)
    }

    // Helper function to deploy Absorber, add rewards and create a trove.
    fn absorber_with_rewards_and_first_provider() -> (
        IShrineDispatcher,
        IAbbotDispatcher,
        IAbsorberDispatcher,
        Span<ContractAddress>, // yangs
        Span<IGateDispatcher>,
        Span<ContractAddress>, // reward tokens
        Span<ContractAddress>, // blessers
        Span<u128>, // reward amts per blessing
        ContractAddress, // provider
        Wad, // provided amount
    ) {
        let (shrine, _, abbot, absorber, yangs, gates, provider, provided_amt) =
            absorber_with_first_provider();

        let reward_tokens: Span<ContractAddress> = reward_tokens_deploy();
        let reward_amts_per_blessing: Span<u128> = reward_amts_per_blessing();
        let blessers: Span<ContractAddress> = deploy_blesser_for_rewards(
            absorber, reward_tokens, reward_amts_per_blessing
        );
        add_rewards_to_absorber(absorber, reward_tokens, blessers);

        (
            shrine,
            abbot,
            absorber,
            yangs,
            gates,
            reward_tokens,
            blessers,
            reward_amts_per_blessing,
            provider,
            provided_amt
        )
    }

    // Helper function to open a trove and provide to the Absorber
    // Returns the trove ID.
    fn provide_to_absorber(
        shrine: IShrineDispatcher,
        abbot: IAbbotDispatcher,
        absorber: IAbsorberDispatcher,
        provider: ContractAddress,
        yangs: Span<ContractAddress>,
        yang_asset_amts: Span<u128>,
        gates: Span<IGateDispatcher>,
        amt: Wad
    ) -> u64 {
        common::fund_user(provider, yangs, yang_asset_amts);
        // Additional amount for testing subsequent provision
        let trove: u64 = common::open_trove_helper(
            abbot, provider, yangs, yang_asset_amts, gates, amt + WAD_SCALE.into()
        );

        set_contract_address(provider);
        let yin = IERC20Dispatcher { contract_address: shrine.contract_address };
        yin.approve(absorber.contract_address, BoundedU256::max());
        absorber.provide(amt);

        set_contract_address(ContractAddressZeroable::zero());

        trove
    }

    // Helper function to simulate an update by:
    // 1. Burning yin from the absorber
    // 2. Transferring yang assets to the Absorber 
    //
    // Arguments
    //
    // - `shrine` - Deployed Shrine instance
    //
    // - `absorber` - Deployed Absorber instance
    //
    // - `yangs` - Ordered list of the addresses of the yangs to be transferred
    //
    // - `yang_asset_amts` - Ordered list of the asset amount to be transferred for each yang
    //
    // - `percentage_to_drain` - Percentage of the Absorber's yin balance to be burnt
    //
    fn simulate_update_with_pct_to_drain(
        shrine: IShrineDispatcher,
        absorber: IAbsorberDispatcher,
        mut yangs: Span<ContractAddress>,
        mut yang_asset_amts: Span<u128>,
        percentage_to_drain: Ray,
    ) {
        let absorber_yin_bal: Wad = shrine.get_yin(absorber.contract_address);
        let burn_amt: Wad = wadray::rmul_wr(absorber_yin_bal, percentage_to_drain);
        simulate_update_with_amt_to_drain(shrine, absorber, yangs, yang_asset_amts, burn_amt);
    }

    // Helper function to simulate an update by:
    // 1. Burning yin from the absorber
    // 2. Transferring yang assets to the Absorber 
    //
    // Arguments
    //
    // - `shrine` - Deployed Shrine instance
    //
    // - `absorber` - Deployed Absorber instance
    //
    // - `yangs` - Ordered list of the addresses of the yangs to be transferred
    //
    // - `yang_asset_amts` - Ordered list of the asset amount to be transferred for each yang
    //
    // - `percentage_to_drain` - Percentage of the Absorber's yin balance to be burnt
    //
    fn simulate_update_with_amt_to_drain(
        shrine: IShrineDispatcher,
        absorber: IAbsorberDispatcher,
        mut yangs: Span<ContractAddress>,
        mut yang_asset_amts: Span<u128>,
        burn_amt: Wad,
    ) {
        // Simulate burning a percentage of absorber's yin
        set_contract_address(ShrineUtils::admin());
        shrine.eject(absorber.contract_address, burn_amt);

        // Simulate transfer of "freed" assets to absorber
        set_contract_address(mock_purger());
        let absorbed_assets: Span<AssetBalance> = common::combine_assets_and_amts(
            yangs, yang_asset_amts
        );
        absorber.update(absorbed_assets);

        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let yang_asset_amt: u256 = (*yang_asset_amts.pop_front().unwrap()).into();
                    let yang_asset_minter = IMintableDispatcher { contract_address: *yang };
                    yang_asset_minter.mint(absorber.contract_address, yang_asset_amt);
                },
                Option::None(_) => {
                    break;
                },
            };
        };

        set_contract_address(ContractAddressZeroable::zero());
    }

    //
    // Test assertion helpers
    //

    // Helper function to assert that:
    // 1. a provider has received the correct amount of absorbed assets; and
    // 2. the previewed amount returned by `preview_reap` is correct.
    // 
    // Arguments
    // 
    // - `absorber` - Deployed Absorber instance.
    //
    // - `provider` - Address of the provider.
    //
    // - `absorbed_amts` - Ordered list of the amount of assets absorbed.
    // 
    // - `before_balances` - Ordered list of the provider's absorbed asset token balances before 
    //    in the format returned by `get_token_balances` [[token1_balance], [token2_balance], ...]
    // 
    // - `preview_absorbed_assets` - Ordered list of `AssetBalance` struct representing the expected 
    //    amount of absorbed assets the provider is entitled to withdraw based on `preview_reap`, 
    //    in the token's decimal precision.
    //
    // - `error_margin` - Acceptable error margin
    // 
    fn assert_provider_received_absorbed_assets(
        absorber: IAbsorberDispatcher,
        provider: ContractAddress,
        mut absorbed_amts: Span<u128>,
        mut before_balances: Span<Span<u128>>,
        mut preview_absorbed_assets: Span<AssetBalance>,
        error_margin: u128,
    ) {
        loop {
            match preview_absorbed_assets.pop_front() {
                Option::Some(asset) => {
                    // Check provider has received correct amount of reward tokens
                    // Convert to Wad for fixed point operations
                    let absorbed_amt: u128 = *absorbed_amts.pop_front().unwrap();
                    let after_provider_bal: u128 = IERC20Dispatcher {
                        contract_address: *asset.asset
                    }.balance_of(provider).try_into().unwrap();
                    let mut before_bal_arr: Span<u128> = *before_balances.pop_front().unwrap();
                    let before_bal: u128 = *before_bal_arr.pop_front().unwrap();
                    let expected_bal: u128 = before_bal + absorbed_amt;

                    common::assert_equalish(
                        after_provider_bal, expected_bal, error_margin, 'wrong absorbed balance'
                    );

                    // Check preview amounts are equal
                    common::assert_equalish(
                        absorbed_amt, *asset.amount, error_margin, 'wrong preview absorbed amount'
                    );
                },
                Option::None(_) => {
                    break;
                },
            };
        };
    }

    // Helper function to assert that:
    // 1. a provider has received the correct amount of reward tokens; and
    // 2. the previewed amount returned by `preview_reap` is correct.
    // 
    // Arguments
    // 
    // - `absorber` - Deployed Absorber instance.
    //
    // - `provider` - Address of the provider.
    // 
    // - `reward_amts_per_blessing` - Ordered list of the reward token amount transferred to the absorber per blessing
    // 
    // - `before_balances` - Ordered list of the provider's reward token balances before receiving the rewards
    //    in the format returned by `get_token_balances` [[token1_balance], [token2_balance], ...]
    // 
    // - `preview_rewarded_assets` - Ordered list of `AssetBalance` struct representing the expected amount of reward 
    //    tokens the provider is entitled to withdraw based on `preview_reap`, in the token's decimal precision.
    //
    // - `blessings_multiplier` - The multiplier to apply to `reward_amts_per_blessing` when calculating the total 
    //    amount the provider should receive.
    // 
    // - `error_margin` - Acceptable error margin
    //
    fn assert_provider_received_rewards(
        absorber: IAbsorberDispatcher,
        provider: ContractAddress,
        mut reward_amts_per_blessing: Span<u128>,
        mut before_balances: Span<Span<u128>>,
        mut preview_rewarded_assets: Span<AssetBalance>,
        blessings_multiplier: Ray,
        error_margin: u128,
    ) {
        loop {
            match preview_rewarded_assets.pop_front() {
                Option::Some(asset) => {
                    // Check provider has received correct amount of reward tokens
                    // Convert to Wad for fixed point operations
                    let reward_amt: Wad = (*reward_amts_per_blessing.pop_front().unwrap()).into();
                    let blessed_amt: Wad = wadray::rmul_wr(reward_amt, blessings_multiplier);
                    let after_provider_bal: u128 = IERC20Dispatcher {
                        contract_address: *asset.asset
                    }.balance_of(provider).try_into().unwrap();
                    let mut before_bal_arr: Span<u128> = *before_balances.pop_front().unwrap();
                    let expected_bal: u128 = (*before_bal_arr.pop_front().unwrap()).into()
                        + blessed_amt.val;

                    common::assert_equalish(
                        after_provider_bal, expected_bal, error_margin, 'wrong reward balance'
                    );

                    // Check preview amounts are equal
                    common::assert_equalish(
                        blessed_amt.val,
                        *asset.amount,
                        error_margin,
                        'wrong preview rewarded amount'
                    );
                },
                Option::None(_) => {
                    break;
                },
            };
        };
    }

    // Helper function to assert that a provider's last cumulative asset amount per share wad value 
    // is updated for all reward tokens.
    // 
    // Arguments
    // 
    // - `absorber` - Deployed Absorber instance.
    //
    // - `provider` - Address of the provider.
    // 
    // - `asset_addresses` = Ordered list of the reward tokens contracts.
    //
    fn assert_provider_reward_cumulatives_updated(
        absorber: IAbsorberDispatcher,
        provider: ContractAddress,
        mut asset_addresses: Span<ContractAddress>,
    ) {
        loop {
            match asset_addresses.pop_front() {
                Option::Some(asset) => {
                    // Check provider's last cumulative is updated to the latest epoch's
                    let current_epoch: u32 = absorber.get_current_epoch();
                    let reward_info: DistributionInfo = absorber
                        .get_cumulative_reward_amt_by_epoch(*asset, current_epoch);
                    let provider_cumulative: u128 = absorber
                        .get_provider_last_reward_cumulative(provider, *asset);

                    assert(
                        provider_cumulative == reward_info.asset_amt_per_share,
                        'wrong provider cumulative'
                    );
                },
                Option::None(_) => {
                    break;
                },
            };
        };
    }

    // Helper function to assert that the cumulative reward token amount per share is updated
    // after a blessing
    // 
    // Arguments
    // 
    // - `absorber` - Deployed Absorber instance.
    // 
    // - `total_shares` - Total amount of shares in the given epoch
    //
    // - `epoch` - The epoch to check for
    // 
    // - `asset_addresses` = Ordered list of the reward tokens contracts.
    //
    // - `reward_amts_per_blessing` - Ordered list of the reward token amount transferred to the absorber per blessing
    // 
    // - `blessings_multiplier` - The multiplier to apply to `reward_amts_per_blessing` when calculating the total 
    //    amount the provider should receive.
    // 
    fn assert_reward_cumulative_updated(
        absorber: IAbsorberDispatcher,
        total_shares: Wad,
        epoch: u32,
        mut asset_addresses: Span<ContractAddress>,
        mut reward_amts_per_blessing: Span<u128>,
        blessings_multiplier: Ray
    ) {
        loop {
            match asset_addresses.pop_front() {
                Option::Some(asset) => {
                    let reward_distribution_info: DistributionInfo = absorber
                        .get_cumulative_reward_amt_by_epoch(*asset, epoch);
                    // Convert to Wad for fixed point operations
                    let reward_amt: Wad = (*reward_amts_per_blessing.pop_front().unwrap()).into();
                    let expected_blessed_amt: Wad = wadray::rmul_wr(
                        reward_amt, blessings_multiplier
                    );
                    let expected_amt_per_share: Wad = expected_blessed_amt / total_shares;

                    assert(
                        reward_distribution_info.asset_amt_per_share == expected_amt_per_share.val,
                        'wrong reward cumulative'
                    );
                },
                Option::None(_) => {
                    break;
                },
            };
        };
    }

    // Helper function to assert that the errors of reward tokens in the given epoch has been
    // propagated to the next epoch, and the cumulative asset amount per share wad is 0.
    // 
    // Arguments
    // 
    // - `absorber` - Deployed Absorber instance.
    // 
    // - `before_epoch` - The epoch to check for
    // 
    // - `asset_addresses` = Ordered list of the reward tokens contracts.
    //
    fn assert_reward_errors_propagated_to_next_epoch(
        absorber: IAbsorberDispatcher,
        before_epoch: u32,
        mut asset_addresses: Span<ContractAddress>,
    ) {
        loop {
            match asset_addresses.pop_front() {
                Option::Some(asset) => {
                    let before_epoch_distribution: DistributionInfo = absorber
                        .get_cumulative_reward_amt_by_epoch(*asset, before_epoch);
                    let after_epoch_distribution: DistributionInfo = absorber
                        .get_cumulative_reward_amt_by_epoch(*asset, before_epoch + 1);

                    assert(
                        before_epoch_distribution.error == after_epoch_distribution.error,
                        'error not propagated'
                    );
                    assert(
                        after_epoch_distribution.asset_amt_per_share.is_zero(),
                        'wrong start reward cumulative'
                    );
                },
                Option::None(_) => {
                    break;
                }
            };
        };
    }

    fn assert_update_is_correct(
        absorber: IAbsorberDispatcher,
        absorption_id: u32,
        total_shares: Wad,
        mut yangs: Span<ContractAddress>,
        mut yang_asset_amts: Span<u128>,
    ) {
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let prev_error: Wad = if absorption_id.is_zero() {
                        WadZeroable::zero()
                    } else {
                        absorber.get_asset_absorption(*yang, absorption_id - 1).error.into()
                    };
                    let actual_distribution: DistributionInfo = absorber
                        .get_asset_absorption(*yang, absorption_id);
                    // Convert to Wad for fixed point operations
                    let asset_amt: Wad = (*yang_asset_amts.pop_front().unwrap()).into();
                    let expected_asset_amt_per_share: u128 = ((asset_amt + prev_error)
                        / total_shares)
                        .val;

                    // Check asset amt per share is correct
                    assert(
                        actual_distribution.asset_amt_per_share == expected_asset_amt_per_share,
                        'wrong absorbed amount per share'
                    );

                    // Check update amount = (total_shares * asset_amt per share) - prev_error + error
                    // Convert to Wad for fixed point operations
                    let distributed_amt: Wad = (total_shares
                        * actual_distribution.asset_amt_per_share.into())
                        + actual_distribution.error.into();
                    assert(asset_amt == distributed_amt, 'update amount mismatch');
                },
                Option::None(_) => {
                    break;
                }
            };
        };
    }
}
