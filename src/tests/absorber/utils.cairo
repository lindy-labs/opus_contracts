pub mod absorber_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::cmp::min;
    use core::num::traits::{Bounded, Zero};
    use opus::core::absorber::absorber as absorber_contract;
    use opus::core::roles::absorber_roles;
    use opus::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::interfaces::IAbsorber::{
        IAbsorberDispatcher, IAbsorberDispatcherTrait, IBlesserDispatcher, IBlesserDispatcherTrait,
    };
    use opus::interfaces::IERC20::{
        IERC20Dispatcher, IERC20DispatcherTrait, IMintableDispatcher, IMintableDispatcherTrait,
    };
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::mock::erc20_mintable::erc20_mintable;
    use opus::tests::abbot::utils::abbot_utils;
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::{AssetBalance, DistributionInfo, Reward};
    use snforge_std::{CheatTarget, ContractClass, ContractClassTrait, declare, start_prank, stop_prank};
    use starknet::ContractAddress;
    use wadray::{Ray, WAD_ONE, WAD_SCALE, Wad};

    // Struct to group together all contract classes
    // needed for absorber tests
    #[derive(Copy, Drop)]
    pub struct AbsorberTestClasses {
        pub abbot: Option<ContractClass>,
        pub sentinel: Option<ContractClass>,
        pub token: Option<ContractClass>,
        pub gate: Option<ContractClass>,
        pub shrine: Option<ContractClass>,
        pub absorber: Option<ContractClass>,
        pub blesser: Option<ContractClass>,
    }

    #[derive(Copy, Drop)]
    pub struct AbsorberTestConfig {
        pub abbot: IAbbotDispatcher,
        pub absorber: IAbsorberDispatcher,
        pub sentinel: ISentinelDispatcher,
        pub shrine: IShrineDispatcher,
        pub yangs: Span<ContractAddress>,
        pub gates: Span<IGateDispatcher>,
    }

    #[derive(Copy, Drop)]
    pub struct AbsorberRewardsTestConfig {
        pub reward_tokens: Span<ContractAddress>,
        pub blessers: Span<ContractAddress>,
        pub reward_amts_per_blessing: Span<u128>,
        pub provider: ContractAddress,
        pub provided_amt: Wad,
    }

    //
    // Constants
    //

    pub const BLESSER_REWARD_TOKEN_BALANCE: u128 = 100000000000000000000000; // 100_000 (Wad)

    pub const OPUS_BLESS_AMT: u128 = 1000000000000000000000; // 1_000 (Wad)
    pub const veOPUS_BLESS_AMT: u128 = 990000000000000000000; // 990 (Wad)

    #[inline(always)]
    pub fn provider_asset_amts() -> Span<u128> {
        let mut asset_amts: Array<u128> = array![20 * WAD_ONE, // 20 (Wad) - ETH
        100000000 // 1 (10 ** 8) - BTC
        ];
        asset_amts.span()
    }

    #[inline(always)]
    pub fn first_update_assets() -> Span<u128> {
        let mut asset_amts: Array<u128> = array![
            1230000000000000000, // 1.23 (Wad) - ETH
            23700000 // 0.237 (10 ** 8) - BTC
        ];
        asset_amts.span()
    }

    #[inline(always)]
    pub fn second_update_assets() -> Span<u128> {
        let mut asset_amts: Array<u128> = array![
            572000000000000000, // 0.572 (Wad) - ETH
            65400000 // 0.654 (10 ** 8) - BTC
        ];
        asset_amts.span()
    }

    //
    // Address constants
    //

    pub fn admin() -> ContractAddress {
        'absorber owner'.try_into().unwrap()
    }

    pub fn provider_1() -> ContractAddress {
        'provider 1'.try_into().unwrap()
    }

    pub fn provider_2() -> ContractAddress {
        'provider 2'.try_into().unwrap()
    }

    pub fn mock_purger() -> ContractAddress {
        'mock purger'.try_into().unwrap()
    }

    //
    // Test setup helpers
    //

    pub fn declare_contracts() -> AbsorberTestClasses {
        AbsorberTestClasses {
            abbot: Option::Some(declare("abbot").unwrap().contract_class()),
            sentinel: Option::Some(declare("sentinel").unwrap().contract_class()),
            token: Option::Some(declare("erc20_mintable").unwrap().contract_class()),
            gate: Option::Some(declare("gate").unwrap().contract_class()),
            shrine: Option::Some(declare("shrine").unwrap().contract_class()),
            absorber: Option::Some(declare("absorber").unwrap().contract_class()),
            blesser: Option::Some(declare("blesser").unwrap().contract_class()),
        }
    }

    pub fn absorber_deploy(classes: Option<AbsorberTestClasses>) -> AbsorberTestConfig {
        let classes = match classes {
            Option::Some(classes) => classes,
            Option::None => declare_contracts(),
        };

        let abbot_utils::AbbotTestConfig {
            shrine, sentinel, abbot, yangs, gates,
        } =
            abbot_utils::abbot_deploy(
                Option::Some(
                    abbot_utils::AbbotTestClasses {
                        abbot: classes.abbot,
                        sentinel: classes.sentinel,
                        token: classes.token,
                        gate: classes.gate,
                        shrine: classes.shrine,
                    },
                ),
            );

        let admin: ContractAddress = admin();

        let calldata: Array<felt252> = array![
            admin.into(), shrine.contract_address.into(), sentinel.contract_address.into(),
        ];

        let absorber_class = classes.absorber.unwrap();
        let (absorber_addr, _) = absorber_class.deploy(@calldata).expect('absorber deploy failed');

        start_prank(CheatTarget::One(absorber_addr), admin);
        let absorber_ac = IAccessControlDispatcher { contract_address: absorber_addr };
        absorber_ac.grant_role(absorber_roles::purger(), mock_purger());
        stop_prank(CheatTarget::One(absorber_addr));

        let absorber = IAbsorberDispatcher { contract_address: absorber_addr };
        AbsorberTestConfig { shrine, sentinel, abbot, absorber, yangs, gates }
    }

    pub fn opus_token_deploy(token_class: Option<ContractClass>) -> ContractAddress {
        common::deploy_token('Opus', 'OPUS', 18, 0_u256, admin(), token_class)
    }

    pub fn veopus_token_deploy(token_class: Option<ContractClass>) -> ContractAddress {
        common::deploy_token('veOpus', 'veOPUS', 18, 0_u256, admin(), token_class)
    }

    // Convenience fixture for reward token addresses constants
    pub fn reward_tokens_deploy(token_class: Option<ContractClass>) -> Span<ContractAddress> {
        let mut reward_tokens: Array<ContractAddress> = array![
            opus_token_deploy(token_class), veopus_token_deploy(token_class),
        ];
        reward_tokens.span()
    }

    // Convenience fixture for reward amounts
    pub fn reward_amts_per_blessing() -> Span<u128> {
        let mut bless_amts: Array<u128> = array![OPUS_BLESS_AMT, veOPUS_BLESS_AMT];
        bless_amts.span()
    }

    // Helper function to deploy a blesser for a token.
    // Mints tokens to the deployed blesser if `mint_to_blesser` is `true`.
    pub fn deploy_blesser_for_reward(
        absorber: IAbsorberDispatcher,
        asset: ContractAddress,
        bless_amt: u128,
        mint_to_blesser: bool,
        blesser_class: Option<ContractClass>,
    ) -> ContractAddress {
        let mut calldata: Array<felt252> = array![
            admin().into(), asset.into(), absorber.contract_address.into(), bless_amt.into(),
        ];

        let blesser_class = match blesser_class {
            Option::Some(class) => class,
            Option::None => declare("mock_blesser").unwrap(),
        };

        let (mock_blesser_addr, _) = blesser_class.deploy(@calldata).expect('blesser deploy failed');

        if mint_to_blesser {
            let token_minter = IMintableDispatcher { contract_address: asset };
            token_minter.mint(mock_blesser_addr, BLESSER_REWARD_TOKEN_BALANCE.into());
        }

        mock_blesser_addr
    }

    // Wrapper function to deploy blessers for an array of reward tokens and return an array
    // of the blesser contract addresses.
    pub fn deploy_blesser_for_rewards(
        absorber: IAbsorberDispatcher,
        mut assets: Span<ContractAddress>,
        mut bless_amts: Span<u128>,
        blesser_class: Option<ContractClass>,
    ) -> Span<ContractAddress> {
        let mut blessers: Array<ContractAddress> = ArrayTrait::new();

        loop {
            match assets.pop_front() {
                Option::Some(asset) => {
                    let blesser: ContractAddress = deploy_blesser_for_reward(
                        absorber, *asset, *bless_amts.pop_front().unwrap(), true, blesser_class,
                    );
                    blessers.append(blesser);
                },
                Option::None => { break; },
            };
        };

        blessers.span()
    }

    pub fn add_rewards_to_absorber(
        absorber: IAbsorberDispatcher, mut tokens: Span<ContractAddress>, mut blessers: Span<ContractAddress>,
    ) {
        start_prank(CheatTarget::One(absorber.contract_address), admin());

        loop {
            match tokens.pop_front() {
                Option::Some(token) => { absorber.set_reward(*token, *blessers.pop_front().unwrap(), true); },
                Option::None => { break; },
            };
        };

        stop_prank(CheatTarget::One(absorber.contract_address));
    }

    pub fn absorber_with_first_provider(
        classes: Option<AbsorberTestClasses>,
    ) -> (AbsorberTestConfig, ContractAddress, // provider
    Wad // provided amount
    ) {
        let AbsorberTestConfig { shrine, sentinel, abbot, absorber, yangs, gates } = absorber_deploy(classes);

        let provider = provider_1();
        let provided_amt: Wad = 10000000000000000000000_u128.into(); // 10_000 (Wad)
        provide_to_absorber(shrine, abbot, absorber, provider, yangs, provider_asset_amts(), gates, provided_amt);

        (AbsorberTestConfig { shrine, sentinel, abbot, absorber, yangs, gates }, provider, provided_amt)
    }

    // Helper function to deploy Absorber, add rewards and create a trove.
    pub fn absorber_with_rewards_and_first_provider(
        classes: Option<AbsorberTestClasses>,
    ) -> (AbsorberTestConfig, AbsorberRewardsTestConfig) {
        let classes = match classes {
            Option::Some(classes) => classes,
            Option::None => declare_contracts(),
        };
        let (absorber_test_config, provider, provided_amt) = absorber_with_first_provider(Option::Some(classes));

        let reward_tokens: Span<ContractAddress> = reward_tokens_deploy(classes.token);
        let reward_amts_per_blessing: Span<u128> = reward_amts_per_blessing();
        let blessers: Span<ContractAddress> = deploy_blesser_for_rewards(
            absorber_test_config.absorber, reward_tokens, reward_amts_per_blessing, classes.blesser,
        );
        add_rewards_to_absorber(absorber_test_config.absorber, reward_tokens, blessers);

        (
            absorber_test_config,
            AbsorberRewardsTestConfig { reward_tokens, blessers, reward_amts_per_blessing, provider, provided_amt },
        )
    }

    // Helper function to open a trove and provide to the Absorber
    // Returns the trove ID.
    pub fn provide_to_absorber(
        shrine: IShrineDispatcher,
        abbot: IAbbotDispatcher,
        absorber: IAbsorberDispatcher,
        provider: ContractAddress,
        yangs: Span<ContractAddress>,
        yang_asset_amts: Span<u128>,
        gates: Span<IGateDispatcher>,
        amt: Wad,
    ) -> u64 {
        common::fund_user(provider, yangs, yang_asset_amts);
        // Additional amount for testing subsequent provision
        let trove: u64 = common::open_trove_helper(
            abbot, provider, yangs, yang_asset_amts, gates, amt + WAD_SCALE.into(),
        );

        start_prank(CheatTarget::Multiple(array![shrine.contract_address, absorber.contract_address]), provider);
        let yin = shrine_utils::yin(shrine.contract_address);
        yin.approve(absorber.contract_address, Bounded::MAX);
        stop_prank(CheatTarget::One(shrine.contract_address));
        absorber.provide(amt);
        stop_prank(CheatTarget::One(absorber.contract_address));

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
    pub fn simulate_update_with_pct_to_drain(
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
    pub fn simulate_update_with_amt_to_drain(
        shrine: IShrineDispatcher,
        absorber: IAbsorberDispatcher,
        mut yangs: Span<ContractAddress>,
        mut yang_asset_amts: Span<u128>,
        burn_amt: Wad,
    ) {
        // Simulate burning a percentage of absorber's yin
        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        shrine.eject(absorber.contract_address, burn_amt);
        stop_prank(CheatTarget::One(shrine.contract_address));

        // Simulate transfer of "freed" assets to absorber
        let mut yang_asset_amts_copy = yang_asset_amts;
        let mut yangs_copy = yangs;
        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => {
                    let yang_asset_amt: u256 = (*yang_asset_amts_copy.pop_front().unwrap()).into();
                    let yang_asset_minter = IMintableDispatcher { contract_address: *yang };
                    yang_asset_minter.mint(absorber.contract_address, yang_asset_amt);
                },
                Option::None => { break; },
            };
        };

        let absorbed_assets: Span<AssetBalance> = common::combine_assets_and_amts(yangs, yang_asset_amts);

        start_prank(CheatTarget::One(absorber.contract_address), mock_purger());
        absorber.update(absorbed_assets);
        stop_prank(CheatTarget::One(absorber.contract_address));
    }

    pub fn kill_absorber(absorber: IAbsorberDispatcher) {
        start_prank(CheatTarget::One(absorber.contract_address), admin());
        absorber.kill();
        stop_prank(CheatTarget::One(absorber.contract_address));
    }

    pub fn get_gate_balances(sentinel: ISentinelDispatcher, mut yangs: Span<ContractAddress>) -> Span<u128> {
        let mut balances: Array<u128> = ArrayTrait::new();

        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let yang_erc20 = IERC20Dispatcher { contract_address: *yang };
                    let balance: u128 = yang_erc20.balance_of(sentinel.get_gate_address(*yang)).try_into().unwrap();
                    balances.append(balance);
                },
                Option::None => { break balances.span(); },
            };
        }
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
    pub fn assert_provider_received_absorbed_assets(
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
                    let after_provider_bal: u128 = IERC20Dispatcher { contract_address: *asset.address }
                        .balance_of(provider)
                        .try_into()
                        .unwrap();
                    let mut before_bal_arr: Span<u128> = *before_balances.pop_front().unwrap();
                    let before_bal: u128 = *before_bal_arr.pop_front().unwrap();
                    let expected_bal: u128 = before_bal + absorbed_amt;

                    common::assert_equalish(after_provider_bal, expected_bal, error_margin, 'wrong absorbed balance');

                    // Check preview amounts are equal
                    common::assert_equalish(absorbed_amt, *asset.amount, error_margin, 'wrong preview absorbed amount');
                },
                Option::None => { break; },
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
    pub fn assert_provider_received_rewards(
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
                    let after_provider_bal: u128 = IERC20Dispatcher { contract_address: *asset.address }
                        .balance_of(provider)
                        .try_into()
                        .unwrap();
                    let mut before_bal_arr: Span<u128> = *before_balances.pop_front().unwrap();
                    let expected_bal: u128 = (*before_bal_arr.pop_front().unwrap()).into() + blessed_amt.val;

                    common::assert_equalish(after_provider_bal, expected_bal, error_margin, 'wrong reward balance');

                    // Check preview amounts are equal
                    common::assert_equalish(
                        blessed_amt.val, *asset.amount, error_margin, 'wrong preview rewarded amount',
                    );
                },
                Option::None => { break; },
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
    pub fn assert_provider_reward_cumulatives_updated(
        absorber: IAbsorberDispatcher, provider: ContractAddress, mut asset_addresses: Span<ContractAddress>,
    ) {
        loop {
            match asset_addresses.pop_front() {
                Option::Some(asset) => {
                    // Check provider's last cumulative is updated to the latest epoch's
                    let current_epoch: u32 = absorber.get_current_epoch();
                    let reward_info: DistributionInfo = absorber
                        .get_cumulative_reward_amt_by_epoch(*asset, current_epoch);
                    let provider_cumulative: u128 = absorber.get_provider_last_reward_cumulative(provider, *asset);

                    assert(provider_cumulative == reward_info.asset_amt_per_share, 'wrong provider cumulative');
                },
                Option::None => { break; },
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
    pub fn assert_reward_cumulative_updated(
        absorber: IAbsorberDispatcher,
        recipient_shares: Wad,
        epoch: u32,
        mut asset_addresses: Span<ContractAddress>,
        mut reward_amts_per_blessing: Span<u128>,
        blessings_multiplier: Ray,
    ) {
        loop {
            match asset_addresses.pop_front() {
                Option::Some(asset) => {
                    let reward_distribution_info: DistributionInfo = absorber
                        .get_cumulative_reward_amt_by_epoch(*asset, epoch);
                    // Convert to Wad for fixed point operations
                    let reward_amt: Wad = (*reward_amts_per_blessing.pop_front().unwrap()).into();
                    let expected_blessed_amt: Wad = wadray::rmul_wr(reward_amt, blessings_multiplier);
                    let expected_amt_per_share: Wad = expected_blessed_amt / recipient_shares;

                    assert(
                        reward_distribution_info.asset_amt_per_share == expected_amt_per_share.val,
                        'wrong reward cumulative',
                    );
                },
                Option::None => { break; },
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
    pub fn assert_reward_errors_propagated_to_next_epoch(
        absorber: IAbsorberDispatcher, before_epoch: u32, mut asset_addresses: Span<ContractAddress>,
    ) {
        loop {
            match asset_addresses.pop_front() {
                Option::Some(asset) => {
                    let before_epoch_distribution: DistributionInfo = absorber
                        .get_cumulative_reward_amt_by_epoch(*asset, before_epoch);
                    let after_epoch_distribution: DistributionInfo = absorber
                        .get_cumulative_reward_amt_by_epoch(*asset, before_epoch + 1);

                    assert(before_epoch_distribution.error == after_epoch_distribution.error, 'error not propagated');
                    assert(after_epoch_distribution.asset_amt_per_share.is_zero(), 'wrong start reward cumulative');
                },
                Option::None => { break; },
            };
        };
    }

    pub fn assert_update_is_correct(
        sentinel: ISentinelDispatcher,
        absorber: IAbsorberDispatcher,
        absorption_id: u32,
        recipient_shares: Wad,
        mut yangs: Span<ContractAddress>,
        mut yang_asset_amts: Span<u128>,
        mut gate_balances: Span<u128>,
    ) {
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let actual_asset_amt_per_share: u128 = absorber.get_asset_absorption(*yang, absorption_id);
                    // Convert to Wad for fixed point operations
                    let asset_amt: Wad = (*yang_asset_amts.pop_front().unwrap()).into();
                    let expected_asset_amt_per_share: u128 = (asset_amt / recipient_shares).val;

                    // Check asset amt per share is correct
                    assert(
                        actual_asset_amt_per_share == expected_asset_amt_per_share, 'wrong absorbed amount per share',
                    );

                    let yang_erc20 = IERC20Dispatcher { contract_address: *yang };
                    let gate: ContractAddress = sentinel.get_gate_address(*yang);
                    let updated_gate_balance: u128 = yang_erc20.balance_of(gate).try_into().unwrap();
                    let actual_distribution_error: u128 = updated_gate_balance - *gate_balances.pop_front().unwrap();

                    // Check update amount = (total_shares * asset_amt per share) + error
                    // Convert to Wad for fixed point operations
                    let distributed_amt: Wad = (recipient_shares * actual_asset_amt_per_share.into())
                        + actual_distribution_error.into();
                    assert(asset_amt == distributed_amt, 'update amount mismatch');
                },
                Option::None => { break; },
            };
        };
    }
}
