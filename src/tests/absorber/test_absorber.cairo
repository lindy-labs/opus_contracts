#[cfg(test)]
mod TestAbsorber {
    use array::{ArrayTrait, SpanTrait};
    use cmp::min;
    use integer::{BoundedU128, BoundedU256};
    use option::OptionTrait;
    use starknet::{
        contract_address_const, deploy_syscall, ClassHash, class_hash_try_from_felt252,
        ContractAddress, contract_address_to_felt252, contract_address_try_from_felt252,
        get_block_timestamp, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};
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
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::types::{DistributionInfo, Provision, Request, Reward};
    use aura::utils::wadray;
    use aura::utils::wadray::{Wad, WadZeroable, WAD_SCALE, Ray, RAY_SCALE};

    use aura::tests::abbot::utils::AbbotUtils;
    use aura::tests::absorber::mock_blesser::MockBlesser;
    use aura::tests::erc20::ERC20;
    use aura::tests::shrine::utils::ShrineUtils;
    use aura::tests::test_utils;

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
        asset_amts.append(10000000000000000000); // 10 (Wad) - ETH
        asset_amts.append(100000000); // 1 (19 ** 8) - BTC
        asset_amts.span()
    }

    #[inline(always)]
    fn first_update_assets() -> Span<u128> {
        let mut asset_amts: Array<u128> = Default::default();
        asset_amts.append(1230000000000000000); // 1.23 (Wad) - ETH
        asset_amts.append(23700000); // 0.237 (19 ** 8) - BTC
        asset_amts.span()
    }

    #[inline(always)]
    fn second_update_assets() -> Span<u128> {
        let mut asset_amts: Array<u128> = Default::default();
        asset_amts.append(572000000000000000); // 0.572 (Wad) - ETH
        asset_amts.append(65400000); // 0.654 (19 ** 8) - BTC
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

    // Helper function to open a trove and provide to the Absorber
    fn provide_to_absorber(
        shrine: IShrineDispatcher,
        abbot: IAbbotDispatcher,
        absorber: IAbsorberDispatcher,
        provider: ContractAddress,
        yangs: Span<ContractAddress>,
        yang_asset_amts: Span<u128>,
        gates: Span<IGateDispatcher>,
        amt: Wad
    ) {
        AbbotUtils::fund_user(provider, yangs, yang_asset_amts);
        AbbotUtils::open_trove_helper(abbot, provider, yangs, yang_asset_amts, gates, amt);

        set_contract_address(provider);
        let yin = IERC20Dispatcher { contract_address: shrine.contract_address };
        yin.approve(absorber.contract_address, BoundedU256::max());
        absorber.provide(amt);

        set_contract_address(ContractAddressZeroable::zero());
    }

    fn absorber_deploy() -> (
        IShrineDispatcher,
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
        (shrine, abbot, absorber, yangs, gates)
    }

    // TODO: create a helper that deploys an ERC20 based on input args
    fn aura_token_deploy() -> ContractAddress {
        let mut calldata = Default::default();
        calldata.append('Aura');
        calldata.append('AURA');
        calldata.append(18);
        calldata.append(0); // u256.low
        calldata.append(0); // u256.high
        calldata.append(contract_address_to_felt252(admin()));

        let token: ClassHash = class_hash_try_from_felt252(ERC20::TEST_CLASS_HASH).unwrap();
        let (token, _) = deploy_syscall(token, 0, calldata.span(), false).unwrap_syscall();

        token
    }

    // TODO: create a helper that deploys an ERC20 based on input args
    fn veaura_token_deploy() -> ContractAddress {
        let mut calldata = Default::default();
        calldata.append('veAura');
        calldata.append('veAURA');
        calldata.append(18);
        calldata.append(0); // u256.low
        calldata.append(0); // u256.high
        calldata.append(contract_address_to_felt252(admin()));

        let token: ClassHash = class_hash_try_from_felt252(ERC20::TEST_CLASS_HASH).unwrap();
        let (token, _) = deploy_syscall(token, 0, calldata.span(), false).unwrap_syscall();

        token
    }

    fn reward_tokens_deploy() -> Span<ContractAddress> {
        let mut reward_tokens: Array<ContractAddress> = Default::default();
        reward_tokens.append(aura_token_deploy());
        reward_tokens.append(veaura_token_deploy());
        reward_tokens.span()
    }

    fn reward_amts_per_blessing() -> Span<u128> {
        let mut bless_amts: Array<u128> = Default::default();
        bless_amts.append(AURA_BLESS_AMT);
        bless_amts.append(VEAURA_BLESS_AMT);
        bless_amts.span()
    }

    // Helper function to deploy a blesser for a token, and mint tokens to the deployed blesser.
    fn deploy_blesser_for_reward(
        absorber: IAbsorberDispatcher, asset: ContractAddress, bless_amt: u128
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

        let token_minter = IMintableDispatcher { contract_address: asset };
        token_minter.mint(mock_blesser_addr, BLESSER_REWARD_TOKEN_BALANCE.into());

        mock_blesser_addr
    }

    fn deploy_blesser_for_rewards(
        absorber: IAbsorberDispatcher, mut assets: Span<ContractAddress>, mut bless_amts: Span<u128>
    ) -> Span<ContractAddress> {
        let mut blessers: Array<ContractAddress> = Default::default();

        loop {
            match assets.pop_front() {
                Option::Some(asset) => {
                    let blesser: ContractAddress = deploy_blesser_for_reward(
                        absorber, *asset, *bless_amts.pop_front().unwrap()
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
        absorber.update(yangs, yang_asset_amts);

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
    // 1. a provider has received the correct amount of absorbed assets;
    // 2. the previewed amount returned by `preview_reap` is correct; and
    // 
    // Arguments
    // 
    // - `absorber` - Deployed Absorber instance.
    //
    // - `provider` - Address of the provider.
    //  
    // - `asset_addresses` = Ordered list of the absorbed asset token addresses.
    //
    // - `absorbed_amts` - Ordered list of the amount of assets absorbed.
    // 
    // - `before_balances` - Ordered list of the provider's absorbed asset token balances before 
    //    in the format returned by `get_token_balances` [[token1_balance], [token2_balance], ...]
    // 
    // - `preview_amts` - Ordered list of the expected amount of absorbed assets the provider is entitled to 
    //    withdraw based on `preview_reap`, in the token's decimal precision.
    //
    // - `error_margin` - Acceptable error margin
    // 
    fn assert_provider_received_absorbed_assets(
        absorber: IAbsorberDispatcher,
        provider: ContractAddress,
        mut asset_addresses: Span<ContractAddress>,
        mut absorbed_amts: Span<u128>,
        mut before_balances: Span<Span<u128>>,
        mut preview_amts: Span<u128>,
        error_margin: Wad,
    ) {
        loop {
            match asset_addresses.pop_front() {
                Option::Some(asset) => {
                    // Check provider has received correct amount of reward tokens
                    // Convert to Wad for fixed point operations
                    let absorbed_amt: Wad = (*absorbed_amts.pop_front().unwrap()).into();
                    let after_provider_bal: Wad = IERC20Dispatcher {
                        contract_address: *asset
                    }.balance_of(provider).try_into().unwrap();
                    let mut before_bal_arr: Span<u128> = *before_balances.pop_front().unwrap();
                    let before_bal: Wad = (*before_bal_arr.pop_front().unwrap()).into();
                    let expected_bal: Wad = before_bal + absorbed_amt;

                    test_utils::assert_equalish(
                        after_provider_bal, expected_bal, error_margin, 'wrong absorbed balance'
                    );

                    // Check preview amounts are equal
                    let preview_amt = *preview_amts.pop_front().unwrap();
                    test_utils::assert_equalish(
                        absorbed_amt, preview_amt.into(), error_margin, 'wrong preview amount'
                    );
                },
                Option::None(_) => {
                    break;
                },
            };
        };
    }

    // Helper function to assert that:
    // 1. a provider has received the correct amount of reward tokens;
    // 2. the previewed amount returned by `preview_reap` is correct; and
    // 
    // Arguments
    // 
    // - `absorber` - Deployed Absorber instance.
    //
    // - `provider` - Address of the provider.
    // 
    // - `asset_addresses` = Ordered list of the reward tokens contracts.
    //
    // - `reward_amts_per_blessing` - Ordered list of the reward token amount transferred to the absorber per blessing
    // 
    // - `before_balances` - Ordered list of the provider's reward token balances before receiving the rewards
    //    in the format returned by `get_token_balances` [[token1_balance], [token2_balance], ...]
    // 
    // - `preview_amts` - Ordered list of the expected amount of reward tokens the provider is entitled to 
    //    withdraw based on `preview_reap`, in the token's decimal precision.
    //
    // - `blessings_multiplier` - The multiplier to apply to `reward_amts_per_blessing` when calculating the total 
    //    amount the provider should receive.
    // 
    // - `error_margin` - Acceptable error margin
    //
    fn assert_provider_received_rewards(
        absorber: IAbsorberDispatcher,
        provider: ContractAddress,
        mut asset_addresses: Span<ContractAddress>,
        mut reward_amts_per_blessing: Span<u128>,
        mut before_balances: Span<Span<u128>>,
        mut preview_amts: Span<u128>,
        blessings_multiplier: Ray,
        error_margin: Wad,
    ) {
        loop {
            match asset_addresses.pop_front() {
                Option::Some(asset) => {
                    // Check provider has received correct amount of reward tokens
                    // Convert to Wad for fixed point operations
                    let reward_amt: Wad = (*reward_amts_per_blessing.pop_front().unwrap()).into();
                    let blessed_amt: Wad = wadray::rmul_wr(reward_amt, blessings_multiplier);
                    let after_provider_bal: Wad = IERC20Dispatcher {
                        contract_address: *asset
                    }.balance_of(provider).try_into().unwrap();
                    let mut before_bal_arr: Span<u128> = *before_balances.pop_front().unwrap();
                    let expected_bal: Wad = (*before_bal_arr.pop_front().unwrap()).into()
                        + blessed_amt.into();

                    test_utils::assert_equalish(
                        after_provider_bal, expected_bal, error_margin, 'wrong reward balance'
                    );

                    // Check preview amounts are equal
                    let preview_amt = *preview_amts.pop_front().unwrap();
                    test_utils::assert_equalish(
                        blessed_amt, preview_amt.into(), error_margin, 'wrong preview amount'
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
                        after_epoch_distribution.asset_amt_per_share == 0,
                        'wrong start reward cumulative'
                    );
                },
                Option::None(_) => {
                    break;
                }
            };
        };
    }

    fn get_asset_amts_by_pct(mut asset_amts: Span<u128>, pct: Ray) -> Span<u128> {
        let mut split_asset_amts: Array<u128> = Default::default();
        loop {
            match asset_amts.pop_front() {
                Option::Some(asset_amt) => {
                    // Convert to Wad for fixed point operations
                    let asset_amt: Wad = (*asset_amt).into();
                    split_asset_amts.append(wadray::rmul_wr(asset_amt, pct).val);
                },
                Option::None(_) => {
                    break;
                },
            };
        };

        split_asset_amts.span()
    }

    fn combine_asset_amts(mut lhs: Span<u128>, mut rhs: Span<u128>) -> Span<u128> {
        let mut combined_asset_amts: Array<u128> = Default::default();

        loop {
            match lhs.pop_front() {
                Option::Some(asset_amt) => {
                    // Convert to Wad for fixed point operations
                    combined_asset_amts.append(*asset_amt + *rhs.pop_front().unwrap());
                },
                Option::None(_) => {
                    break;
                },
            };
        };

        combined_asset_amts.span()
    }

    //
    // Tests - Setup
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_absorber_setup() {
        let (_, _, absorber, _, _) = absorber_deploy();

        assert(
            absorber.get_total_shares_for_current_epoch() == WadZeroable::zero(),
            'total shares should be 0'
        );
        assert(absorber.get_current_epoch() == 0, 'epoch should be 0');
        assert(absorber.get_absorptions_count() == 0, 'absorptions count should be 0');
        assert(absorber.get_rewards_count() == 0, 'rewards should be 0');
        assert(absorber.get_removal_limit() == REMOVAL_LIMIT.into(), 'wrong limit');
        assert(absorber.get_live(), 'should be live');

        let absorber_ac = IAccessControlDispatcher { contract_address: absorber.contract_address };
        assert(
            absorber_ac.get_roles(admin()) == AbsorberRoles::default_admin_role(),
            'wrong role for admin'
        );
    }

    //
    // Tests - Setters
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_set_removal_limit_pass() {
        let (_, _, absorber, _, _) = absorber_deploy();

        set_contract_address(admin());

        let new_limit: Ray = 750000000000000000000000000_u128.into(); // 75% (Ray)
        absorber.set_removal_limit(new_limit);

        assert(absorber.get_removal_limit() == new_limit, 'limit not updated');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Limit is too low', 'ENTRYPOINT_FAILED'))]
    fn test_set_removal_limit_too_low_fail() {
        let (_, _, absorber, _, _) = absorber_deploy();

        set_contract_address(admin());

        let invalid_limit: Ray = (Absorber::MIN_LIMIT - 1).into();
        absorber.set_removal_limit(invalid_limit);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_removal_limit_unauthorized_fail() {
        let (_, _, absorber, _, _) = absorber_deploy();

        set_contract_address(test_utils::badguy());

        let new_limit: Ray = 750000000000000000000000000_u128.into(); // 75% (Ray)
        absorber.set_removal_limit(new_limit);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_reward_pass() {
        let (_, _, absorber, _, _) = absorber_deploy();

        let aura_token: ContractAddress = aura_token_deploy();
        let aura_blesser: ContractAddress = deploy_blesser_for_reward(
            absorber, aura_token, AURA_BLESS_AMT
        );

        let veaura_token: ContractAddress = veaura_token_deploy();
        let veaura_blesser: ContractAddress = deploy_blesser_for_reward(
            absorber, veaura_token, VEAURA_BLESS_AMT
        );

        set_contract_address(admin());
        absorber.set_reward(aura_token, aura_blesser, true);

        assert(absorber.get_rewards_count() == 1, 'rewards count not updated');

        let mut aura_reward = Reward {
            asset: aura_token, blesser: IBlesserDispatcher {
                contract_address: aura_blesser
            }, is_active: true
        };
        let mut expected_rewards: Array<Reward> = Default::default();
        expected_rewards.append(aura_reward);

        assert(absorber.get_rewards() == expected_rewards.span(), 'rewards not equal');

        // Add another reward

        absorber.set_reward(veaura_token, veaura_blesser, true);

        assert(absorber.get_rewards_count() == 2, 'rewards count not updated');

        let veaura_reward = Reward {
            asset: veaura_token, blesser: IBlesserDispatcher {
                contract_address: veaura_blesser
            }, is_active: true
        };
        let mut expected_rewards: Array<Reward> = Default::default();
        expected_rewards.append(aura_reward);
        expected_rewards.append(veaura_reward);

        assert(absorber.get_rewards() == expected_rewards.span(), 'rewards not equal');

        // Update existing reward
        aura_reward.is_active = false;
        absorber.set_reward(aura_token, aura_blesser, false);

        let mut expected_rewards: Array<Reward> = Default::default();
        aura_reward.is_active = false;
        expected_rewards.append(aura_reward);
        expected_rewards.append(veaura_reward);

        assert(absorber.get_rewards() == expected_rewards.span(), 'rewards not equal');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Address cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_set_reward_token_zero_address_fail() {
        let (_, _, absorber, _, _) = absorber_deploy();

        let valid_address = contract_address_const::<0xffff>();
        let invalid_address = ContractAddressZeroable::zero();

        set_contract_address(admin());
        absorber.set_reward(valid_address, invalid_address, true);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Address cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_set_reward_blesser_zero_address_fail() {
        let (_, _, absorber, _, _) = absorber_deploy();

        let valid_address = contract_address_const::<0xffff>();
        let invalid_address = ContractAddressZeroable::zero();

        set_contract_address(admin());
        absorber.set_reward(invalid_address, valid_address, true);
    }

    //
    // Tests - Kill
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_kill_pass() {
        let (_, _, absorber, _, _) = absorber_deploy();

        set_contract_address(admin());
        absorber.kill();

        assert(!absorber.get_live(), 'should be killed');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_kill_unauthorized_fail() {
        let (_, _, absorber, _, _) = absorber_deploy();

        set_contract_address(test_utils::badguy());
        absorber.kill();
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Not live', 'ENTRYPOINT_FAILED'))]
    fn test_provide_after_kill_fail() {
        let (shrine, _, absorber, _, _) = absorber_deploy();

        set_contract_address(admin());
        absorber.kill();
        absorber.provide(1_u128.into());
    }

    //
    // Tests - Update
    //

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

    #[test]
    #[available_gas(20000000000)]
    fn test_update_and_subsequent_provider_action() {
        // Parametrization
        let mut percentages_to_drain: Array<Ray> = Default::default();
        percentages_to_drain.append(200000000000000000000000000_u128.into()); // 20% (Ray)
        percentages_to_drain.append(439210000000000000000000000_u128.into()); // 43.291% (Ray)
        percentages_to_drain.append(1000000000000000000000000000_u128.into()); // 100% (Ray)
        let mut percentages_to_drain = percentages_to_drain.span();

        loop {
            match percentages_to_drain.pop_front() {
                Option::Some(percentage_to_drain) => {
                    // Setup
                    let (shrine, abbot, absorber, yangs, gates) = absorber_deploy();
                    let reward_tokens: Span<ContractAddress> = reward_tokens_deploy();
                    let reward_amts_per_blessing: Span<u128> = reward_amts_per_blessing();
                    let blessers: Span<ContractAddress> = deploy_blesser_for_rewards(
                        absorber, reward_tokens, reward_amts_per_blessing
                    );
                    add_rewards_to_absorber(absorber, reward_tokens, blessers);

                    let provider = provider_1();
                    let first_provided_amt: Wad = 10000000000000000000000_u128
                        .into(); // 10_000 (Wad)
                    provide_to_absorber(
                        shrine,
                        abbot,
                        absorber,
                        provider,
                        yangs,
                        provider_asset_amts(),
                        gates,
                        first_provided_amt
                    );

                    // Simulate absorption
                    let first_update_assets: Span<u128> = first_update_assets();
                    simulate_update_with_pct_to_drain(
                        shrine, absorber, yangs, first_update_assets, *percentage_to_drain
                    );

                    let is_fully_absorbed: bool = if *percentage_to_drain == RAY_SCALE.into() {
                        true
                    } else {
                        false
                    };

                    let expected_epoch = if is_fully_absorbed {
                        1
                    } else {
                        0
                    };
                    let expected_total_shares: Wad = if is_fully_absorbed {
                        WadZeroable::zero()
                    } else {
                        first_provided_amt // total shares is equal to amount provided  
                    };
                    let expected_absorption_id = 1;
                    assert(
                        absorber.get_absorptions_count() == expected_absorption_id,
                        'wrong absorption id'
                    );

                    // total shares is equal to amount provided  
                    let before_total_shares: Wad = first_provided_amt;
                    assert_update_is_correct(
                        absorber,
                        expected_absorption_id,
                        before_total_shares,
                        yangs,
                        first_update_assets,
                    );

                    let expected_blessings_multiplier: Ray = RAY_SCALE.into();
                    let absorption_epoch = 0;
                    assert_reward_cumulative_updated(
                        absorber,
                        before_total_shares,
                        absorption_epoch,
                        reward_tokens,
                        reward_amts_per_blessing,
                        expected_blessings_multiplier,
                    );

                    assert(
                        absorber.get_total_shares_for_current_epoch() == expected_total_shares,
                        'wrong total shares'
                    );
                    assert(absorber.get_current_epoch() == expected_epoch, 'wrong epoch');

                    let mut token_holders: Array<ContractAddress> = Default::default();
                    token_holders.append(provider);

                    let before_absorbed_bals = test_utils::get_token_balances(
                        yangs, token_holders.span()
                    );
                    let before_reward_bals = test_utils::get_token_balances(
                        reward_tokens, token_holders.span()
                    );
                    let before_last_absorption = absorber.get_provider_last_absorption(provider);

                    // Perform three different actions:
                    // 1. `reap`
                    // 2. `request` and `remove`
                    // 3. `provide`
                    // and check that the provider receives rewards and absorbed assets

                    let (_, preview_absorbed_amts, _, preview_reward_amts) = absorber
                        .preview_reap(provider);

                    let mut remove_as_second_action: bool = false;
                    set_contract_address(provider);
                    if percentages_to_drain.len() % 3 == 0 {
                        absorber.reap();
                    } else if percentages_to_drain.len() % 3 == 1 {
                        absorber.request();
                        set_block_timestamp(get_block_timestamp() + 60);
                        absorber.remove(BoundedU128::max().into());
                        remove_as_second_action = true;
                    } else {
                        provide_to_absorber(
                            shrine,
                            abbot,
                            absorber,
                            provider,
                            yangs,
                            provider_asset_amts(),
                            gates,
                            1_u128.into()
                        );
                    }

                    // One distribution from `update` and another distribution from 
                    // `reap`/`remove`/`provide` if not fully absorbed
                    let expected_blessings_multiplier = if is_fully_absorbed {
                        RAY_SCALE.into()
                    } else {
                        (RAY_SCALE * 2).into()
                    };

                    // Check rewards
                    // Custom error margin is used due to loss of precision and initial minimum shares
                    let error_margin: Wad = 500_u128.into();

                    assert_provider_received_absorbed_assets(
                        absorber,
                        provider,
                        yangs,
                        first_update_assets,
                        before_absorbed_bals,
                        preview_absorbed_amts,
                        error_margin,
                    );

                    assert_provider_received_rewards(
                        absorber,
                        provider,
                        reward_tokens,
                        reward_amts_per_blessing,
                        before_reward_bals,
                        preview_reward_amts,
                        expected_blessings_multiplier,
                        error_margin,
                    );
                    assert_provider_reward_cumulatives_updated(absorber, provider, reward_tokens);

                    let (_, _, _, after_preview_reward_amts) = absorber.preview_reap(provider);
                    if is_fully_absorbed {
                        assert(
                            after_preview_reward_amts.len().is_zero(), 'should not have rewards'
                        );
                        assert_reward_errors_propagated_to_next_epoch(
                            absorber, expected_epoch - 1, reward_tokens
                        );
                    } else if after_preview_reward_amts.len().is_non_zero() {
                        // Sanity check that updated preview reward amount is lower than before
                        assert(
                            *after_preview_reward_amts.at(0) < *preview_reward_amts.at(0),
                            'preview amount should decrease'
                        );
                    }

                    // If the second action was `remove`, check that the yin balances of absorber 
                    // and provider are updated.
                    if remove_as_second_action {
                        assert(
                            *percentage_to_drain != RAY_SCALE.into(), 'use a different value'
                        ); // sanity check

                        let expected_removed_amt: Wad = wadray::rmul_wr(
                            first_provided_amt, (RAY_SCALE.into() - *percentage_to_drain)
                        );
                        let error_margin: Wad = 1000_u128.into();
                        test_utils::assert_equalish(
                            shrine.get_yin(provider),
                            expected_removed_amt,
                            error_margin,
                            'wrong provider yin balance'
                        );
                        test_utils::assert_equalish(
                            shrine.get_yin(absorber.contract_address),
                            WadZeroable::zero(),
                            error_margin,
                            'wrong absorber yin balance'
                        );

                        // Check `request` is used
                        assert(
                            absorber.get_provider_request(provider).has_removed,
                            'request should be fulfilled'
                        );
                    }
                },
                Option::None(_) => {
                    break;
                },
            };
        };
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_update_unauthorized_fail() {
        let (shrine, abbot, absorber, yangs, gates) = absorber_deploy();
        let first_provided_amt: Wad = 1000000000000000000000_u128.into(); // 1_000 (Wad)
        provide_to_absorber(
            shrine,
            abbot,
            absorber,
            provider_1(),
            yangs,
            provider_asset_amts(),
            gates,
            first_provided_amt
        );

        let first_update_assets: Span<u128> = first_update_assets();

        set_contract_address(test_utils::badguy());
        absorber.update(yangs, first_update_assets);
    }

    //
    // Tests - Provider functions (provide, request, remove, reap)
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_provide_first_epoch() {
        let (shrine, abbot, absorber, yangs, gates) = absorber_deploy();
        let yin = IERC20Dispatcher { contract_address: shrine.contract_address };
        let reward_tokens: Span<ContractAddress> = reward_tokens_deploy();
        let reward_amts_per_blessing: Span<u128> = reward_amts_per_blessing();
        let blessers: Span<ContractAddress> = deploy_blesser_for_rewards(
            absorber, reward_tokens, reward_amts_per_blessing
        );
        add_rewards_to_absorber(absorber, reward_tokens, blessers);

        let provider: ContractAddress = provider_1();

        let first_provided_amt: Wad = 1000000000000000000000_u128.into(); // 1_000 (Wad)
        provide_to_absorber(
            shrine,
            abbot,
            absorber,
            provider,
            yangs,
            provider_asset_amts(),
            gates,
            first_provided_amt
        );

        let before_provider_info: Provision = absorber.get_provision(provider);
        let before_last_absorption_id: u32 = absorber.get_provider_last_absorption(provider);
        let before_total_shares: Wad = absorber.get_total_shares_for_current_epoch();
        let before_absorber_yin_bal: u256 = yin.balance_of(absorber.contract_address);

        let mut token_holders: Array<ContractAddress> = Default::default();
        token_holders.append(provider);
        let before_reward_bals: Span<Span<u128>> = test_utils::get_token_balances(
            reward_tokens, token_holders.span()
        );

        assert(
            before_provider_info.shares + Absorber::INITIAL_SHARES.into() == before_total_shares,
            'wrong total shares #1'
        );
        assert(before_total_shares == first_provided_amt, 'wrong total shares #2');
        assert(before_absorber_yin_bal == first_provided_amt.into(), 'wrong yin balance');

        // Get preview amounts to check expected rewards
        let (_, _, _, preview_reward_amts) = absorber.preview_reap(provider);

        // Test subsequent deposit
        let second_provided_amt: Wad = 400000000000000000000_u128.into(); // 400 (Wad)
        provide_to_absorber(
            shrine,
            abbot,
            absorber,
            provider,
            yangs,
            provider_asset_amts(),
            gates,
            second_provided_amt
        );

        let after_provider_info: Provision = absorber.get_provision(provider);
        let after_last_absorption_id: u32 = absorber.get_provider_last_absorption(provider);
        let after_total_shares: Wad = absorber.get_total_shares_for_current_epoch();
        let after_absorber_yin_bal: u256 = yin.balance_of(absorber.contract_address);

        // amount of new shares should be equal to amount of yin provided because amount of yin per share is 1 : 1
        assert(
            before_provider_info.shares
                + Absorber::INITIAL_SHARES.into()
                + second_provided_amt == after_total_shares,
            'wrong total shares #1'
        );
        assert(
            after_total_shares == before_total_shares + second_provided_amt, 'wrong total shares #2'
        );
        assert(
            after_absorber_yin_bal == (first_provided_amt + second_provided_amt).into(),
            'wrong yin balance'
        );
        assert(
            before_last_absorption_id == after_last_absorption_id, 'absorption id should not change'
        );

        let expected_blessings_multiplier: Ray = RAY_SCALE.into();
        let expected_epoch: u32 = 0;
        assert_reward_cumulative_updated(
            absorber,
            before_total_shares,
            expected_epoch,
            reward_tokens,
            reward_amts_per_blessing,
            expected_blessings_multiplier
        );

        // Check rewards
        let error_margin: Wad = 1000_u128.into();
        assert_provider_received_rewards(
            absorber,
            provider,
            reward_tokens,
            reward_amts_per_blessing,
            before_reward_bals,
            preview_reward_amts,
            expected_blessings_multiplier,
            error_margin,
        );
        assert_provider_reward_cumulatives_updated(absorber, provider, reward_tokens);
    }

    // Sequence of events
    // 1. Provider 1 provides.
    // 2. Full absorption occurs. Provider 1 receives 1 round of rewards.
    // 3. Provider 2 provides.
    // 4. Full absorption occurs. Provider 2 receives 1 round of rewards.
    // 5. Provider 1 reaps.
    // 6. Provider 2 reaps.
    #[test]
    #[available_gas(20000000000)]
    fn test_reap_different_epochs() {
        // Setup
        let (shrine, abbot, absorber, yangs, gates) = absorber_deploy();
        let reward_tokens: Span<ContractAddress> = reward_tokens_deploy();
        let reward_amts_per_blessing: Span<u128> = reward_amts_per_blessing();
        let blessers: Span<ContractAddress> = deploy_blesser_for_rewards(
            absorber, reward_tokens, reward_amts_per_blessing
        );
        add_rewards_to_absorber(absorber, reward_tokens, blessers);

        // Step 1
        let first_provider = provider_1();
        let first_provided_amt: Wad = 10000000000000000000000_u128.into(); // 10_000 (Wad)
        provide_to_absorber(
            shrine,
            abbot,
            absorber,
            first_provider,
            yangs,
            provider_asset_amts(),
            gates,
            first_provided_amt
        );

        let first_epoch_total_shares: Wad = absorber.get_total_shares_for_current_epoch();

        // Step 2
        let first_update_assets: Span<u128> = first_update_assets();
        simulate_update_with_pct_to_drain(
            shrine, absorber, yangs, first_update_assets, RAY_SCALE.into()
        );

        // Second epoch starts here
        // Step 3
        let second_provider = provider_2();
        let second_provided_amt: Wad = 5000000000000000000000_u128.into(); // 5_000 (Wad)
        provide_to_absorber(
            shrine,
            abbot,
            absorber,
            second_provider,
            yangs,
            provider_asset_amts(),
            gates,
            second_provided_amt
        );

        // Check provision in new epoch
        let second_provider_info: Provision = absorber.get_provision(second_provider);
        assert(
            absorber.get_total_shares_for_current_epoch() == second_provided_amt,
            'wrong total shares'
        );
        assert(
            second_provider_info.shares + Absorber::INITIAL_SHARES.into() == second_provided_amt,
            'wrong provider shares'
        );

        let expected_epoch: u32 = 1;
        assert(second_provider_info.epoch == expected_epoch, 'wrong provider epoch');

        let second_epoch_total_shares: Wad = absorber.get_total_shares_for_current_epoch();

        // Step 4
        let second_update_assets: Span<u128> = second_update_assets();
        simulate_update_with_pct_to_drain(
            shrine, absorber, yangs, second_update_assets, RAY_SCALE.into()
        );

        // Step 5
        let mut user_addresses: Array<ContractAddress> = Default::default();
        user_addresses.append(first_provider);

        let first_provider_before_reward_bals = test_utils::get_token_balances(
            reward_tokens, user_addresses.span()
        );
        let first_provider_before_absorbed_bals = test_utils::get_token_balances(
            yangs, user_addresses.span()
        );

        set_contract_address(first_provider);
        let (_, preview_absorbed_amts, _, preview_reward_amts) = absorber
            .preview_reap(first_provider);

        absorber.reap();

        assert(absorber.get_provider_last_absorption(first_provider) == 2, 'wrong last absorption');

        let error_margin: Wad = 1000_u128.into();
        assert_provider_received_absorbed_assets(
            absorber,
            first_provider,
            yangs,
            first_update_assets,
            first_provider_before_absorbed_bals,
            preview_absorbed_amts,
            error_margin,
        );

        let expected_blessings_multiplier: Ray = RAY_SCALE.into();
        let expected_epoch: u32 = 0;
        assert_reward_cumulative_updated(
            absorber,
            first_epoch_total_shares,
            expected_epoch,
            reward_tokens,
            reward_amts_per_blessing,
            expected_blessings_multiplier
        );

        // Check rewards
        assert_provider_received_rewards(
            absorber,
            first_provider,
            reward_tokens,
            reward_amts_per_blessing,
            first_provider_before_reward_bals,
            preview_reward_amts,
            expected_blessings_multiplier,
            error_margin,
        );
        assert_provider_reward_cumulatives_updated(absorber, first_provider, reward_tokens);

        // Step 6
        let mut user_addresses: Array<ContractAddress> = Default::default();
        user_addresses.append(second_provider);

        let second_provider_before_reward_bals = test_utils::get_token_balances(
            reward_tokens, user_addresses.span()
        );
        let second_provider_before_absorbed_bals = test_utils::get_token_balances(
            yangs, user_addresses.span()
        );

        set_contract_address(second_provider);
        let (_, preview_absorbed_amts, _, preview_reward_amts) = absorber
            .preview_reap(second_provider);

        absorber.reap();

        assert(
            absorber.get_provider_last_absorption(second_provider) == 2, 'wrong last absorption'
        );

        let error_margin: Wad = 1000_u128.into();
        assert_provider_received_absorbed_assets(
            absorber,
            second_provider,
            yangs,
            second_update_assets,
            second_provider_before_absorbed_bals,
            preview_absorbed_amts,
            error_margin,
        );

        let expected_blessings_multiplier: Ray = RAY_SCALE.into();
        let expected_epoch: u32 = 1;
        assert_reward_cumulative_updated(
            absorber,
            second_epoch_total_shares,
            expected_epoch,
            reward_tokens,
            reward_amts_per_blessing,
            expected_blessings_multiplier
        );

        // Check rewards
        assert_provider_received_rewards(
            absorber,
            second_provider,
            reward_tokens,
            reward_amts_per_blessing,
            second_provider_before_reward_bals,
            preview_reward_amts,
            expected_blessings_multiplier,
            error_margin,
        );
        assert_provider_reward_cumulatives_updated(absorber, second_provider, reward_tokens);
    }


    // Sequence of events:
    // 1. Provider 1 provides
    // 2. Absorption occurs; yin per share falls below threshold, and yin amount is 
    //    greater than the minimum initial shares. Provider 1 receives 1 round of rewards.
    // 3. Provider 2 provides, provider 1 receives 1 round of rewards.
    // 4. Provider 1 withdraws, both providers share 1 round of rewards.
    #[test]
    #[available_gas(20000000000)]
    fn test_provide_after_threshold_absorption_above_minimum() {
        // Setup
        let (shrine, abbot, absorber, yangs, gates) = absorber_deploy();
        let reward_tokens: Span<ContractAddress> = reward_tokens_deploy();
        let reward_amts_per_blessing: Span<u128> = reward_amts_per_blessing();
        let blessers: Span<ContractAddress> = deploy_blesser_for_rewards(
            absorber, reward_tokens, reward_amts_per_blessing
        );
        add_rewards_to_absorber(absorber, reward_tokens, blessers);

        // Step 1
        let first_provider = provider_1();
        let first_provided_amt: Wad = 10000000000000000000000_u128.into(); // 10_000 (Wad)
        provide_to_absorber(
            shrine,
            abbot,
            absorber,
            first_provider,
            yangs,
            provider_asset_amts(),
            gates,
            first_provided_amt
        );

        let first_epoch_total_shares: Wad = absorber.get_total_shares_for_current_epoch();

        // Step 2
        let first_update_assets: Span<u128> = first_update_assets();
        // Amount of yin remaining needs to be sufficiently significant to account for loss of precision
        // from conversion of shares across epochs, after discounting initial shares.
        let above_min_shares: Wad = (1000000000_u128).into(); // half-Wad scale
        let burn_amt: Wad = first_provided_amt - above_min_shares;
        simulate_update_with_amt_to_drain(shrine, absorber, yangs, first_update_assets, burn_amt);

        // Check epoch and total shares after threshold absorption
        let expected_epoch: u32 = 1;
        assert(absorber.get_current_epoch() == expected_epoch, 'wrong epoch');
        assert(
            absorber.get_total_shares_for_current_epoch() == above_min_shares, 'wrong total shares'
        );

        assert_reward_errors_propagated_to_next_epoch(absorber, expected_epoch - 1, reward_tokens);

        // Second epoch starts here
        // Step 3
        let second_provider = provider_2();
        let second_provided_amt: Wad = 5000000000000000000000_u128.into(); // 5_000 (Wad)
        provide_to_absorber(
            shrine,
            abbot,
            absorber,
            second_provider,
            yangs,
            provider_asset_amts(),
            gates,
            second_provided_amt
        );

        let second_provider_info: Provision = absorber.get_provision(second_provider);
        assert(second_provider_info.shares == second_provided_amt, 'wrong provider shares');
        assert(second_provider_info.epoch == 1, 'wrong provider epoch');

        let error_margin: Wad = 1000_u128.into();
        test_utils::assert_equalish(
            absorber.preview_remove(second_provider),
            second_provided_amt,
            error_margin,
            'wrong preview remove amount'
        );

        // Step 4
        let mut user_addresses: Array<ContractAddress> = Default::default();
        user_addresses.append(first_provider);

        let first_provider_before_yin_bal: Wad = shrine.get_yin(first_provider);
        let first_provider_before_reward_bals = test_utils::get_token_balances(
            reward_tokens, user_addresses.span()
        );
        let first_provider_before_absorbed_bals = test_utils::get_token_balances(
            yangs, user_addresses.span()
        );

        set_contract_address(first_provider);
        let (_, preview_absorbed_amts, _, preview_reward_amts) = absorber
            .preview_reap(first_provider);

        absorber.request();
        set_block_timestamp(get_block_timestamp() + 60);
        absorber.remove(BoundedU128::max().into());

        // Check that first provider receives some amount of yin from the converted 
        // epoch shares.
        assert(
            shrine.get_yin(first_provider) > first_provider_before_yin_bal,
            'yin balance should be higher'
        );

        let first_provider_info: Provision = absorber.get_provision(first_provider);
        assert(first_provider_info.shares == WadZeroable::zero(), 'wrong provider shares');
        assert(first_provider_info.epoch == 1, 'wrong provider epoch');

        let request: Request = absorber.get_provider_request(first_provider);
        assert(request.has_removed, 'request should be fulfilled');

        // Loosen error margin due to loss of precision from epoch share conversion
        let error_margin: Wad = WAD_SCALE.into();
        assert_provider_received_absorbed_assets(
            absorber,
            first_provider,
            yangs,
            first_update_assets,
            first_provider_before_absorbed_bals,
            preview_absorbed_amts,
            error_margin,
        );

        // Check rewards
        let expected_first_epoch_blessings_multiplier: Ray = RAY_SCALE.into();
        let first_epoch: u32 = 0;
        assert_reward_cumulative_updated(
            absorber,
            first_epoch_total_shares,
            first_epoch,
            reward_tokens,
            reward_amts_per_blessing,
            expected_first_epoch_blessings_multiplier
        );

        let expected_first_provider_blessings_multiplier = (2 * RAY_SCALE).into();
        assert_provider_received_rewards(
            absorber,
            first_provider,
            reward_tokens,
            reward_amts_per_blessing,
            first_provider_before_reward_bals,
            preview_reward_amts,
            expected_first_provider_blessings_multiplier,
            error_margin,
        );
        assert_provider_reward_cumulatives_updated(absorber, first_provider, reward_tokens);
    }

    // Sequence of events:
    // 1. Provider 1 provides
    // 2. Absorption occurs; yin per share falls below threshold, and yin amount is 
    //    below the minimum initial shares so total shares in new epoch starts from 0. 
    //    No rewards are distributed because total shares is zeroed.
    // 3. Provider 2 provides, provider 1 receives 1 round of rewards.
    // 4. Provider 1 withdraws, both providers share 1 round of rewards.
    #[test]
    #[available_gas(20000000000)]
    fn test_provide_after_threshold_absorption_below_minimum() {
        // Setup
        let (shrine, abbot, absorber, yangs, gates) = absorber_deploy();
        let reward_tokens: Span<ContractAddress> = reward_tokens_deploy();
        let reward_amts_per_blessing: Span<u128> = reward_amts_per_blessing();
        let blessers: Span<ContractAddress> = deploy_blesser_for_rewards(
            absorber, reward_tokens, reward_amts_per_blessing
        );
        add_rewards_to_absorber(absorber, reward_tokens, blessers);

        // Step 1
        let first_provider = provider_1();
        let first_provided_amt: Wad = 10000000000000000000000_u128.into(); // 10_000 (Wad)
        provide_to_absorber(
            shrine,
            abbot,
            absorber,
            first_provider,
            yangs,
            provider_asset_amts(),
            gates,
            first_provided_amt
        );

        let first_epoch_total_shares: Wad = absorber.get_total_shares_for_current_epoch();

        // Step 2
        let first_update_assets: Span<u128> = first_update_assets();
        let below_min_shares: Wad = (999_u128).into();
        let burn_amt: Wad = first_provided_amt - below_min_shares;
        simulate_update_with_amt_to_drain(shrine, absorber, yangs, first_update_assets, burn_amt);

        // Check epoch and total shares after threshold absorption
        let expected_epoch: u32 = 1;
        assert(absorber.get_current_epoch() == expected_epoch, 'wrong epoch');
        assert(
            absorber.get_total_shares_for_current_epoch() == WadZeroable::zero(),
            'wrong total shares'
        );

        assert_reward_errors_propagated_to_next_epoch(absorber, expected_epoch - 1, reward_tokens);

        // Second epoch starts here
        // Step 3
        let second_provider = provider_2();
        let second_provided_amt: Wad = 5000000000000000000000_u128.into(); // 5_000 (Wad)
        provide_to_absorber(
            shrine,
            abbot,
            absorber,
            second_provider,
            yangs,
            provider_asset_amts(),
            gates,
            second_provided_amt
        );

        let second_provider_info: Provision = absorber.get_provision(second_provider);
        assert(
            absorber.get_total_shares_for_current_epoch() == second_provided_amt,
            'wrong total shares'
        );
        assert(
            second_provider_info.shares == second_provided_amt - Absorber::INITIAL_SHARES.into(),
            'wrong provider shares'
        );
        assert(second_provider_info.epoch == 1, 'wrong provider epoch');

        let error_margin: Wad = 1000_u128.into(); // equal to initial minimum shares
        test_utils::assert_equalish(
            absorber.preview_remove(second_provider),
            second_provided_amt,
            error_margin,
            'wrong preview remove amount'
        );

        // Step 4
        let mut user_addresses: Array<ContractAddress> = Default::default();
        user_addresses.append(first_provider);

        let first_provider_before_yin_bal: Wad = shrine.get_yin(first_provider);
        let first_provider_before_reward_bals = test_utils::get_token_balances(
            reward_tokens, user_addresses.span()
        );
        let first_provider_before_absorbed_bals = test_utils::get_token_balances(
            yangs, user_addresses.span()
        );

        set_contract_address(first_provider);
        let (_, preview_absorbed_amts, _, preview_reward_amts) = absorber
            .preview_reap(first_provider);

        absorber.request();
        set_block_timestamp(get_block_timestamp() + 60);
        absorber.remove(BoundedU128::max().into());

        // First provider should not receive any yin
        assert(
            shrine.get_yin(first_provider) == first_provider_before_yin_bal,
            'yin balance should not change'
        );

        let first_provider_info: Provision = absorber.get_provision(first_provider);
        assert(first_provider_info.shares == WadZeroable::zero(), 'wrong provider shares');
        assert(first_provider_info.epoch == 1, 'wrong provider epoch');

        let request: Request = absorber.get_provider_request(first_provider);
        assert(request.has_removed, 'request should be fulfilled');

        let error_margin: Wad = 1000_u128.into();
        assert_provider_received_absorbed_assets(
            absorber,
            first_provider,
            yangs,
            first_update_assets,
            first_provider_before_absorbed_bals,
            preview_absorbed_amts,
            error_margin,
        );

        // Check rewards
        let expected_first_epoch_blessings_multiplier: Ray = RAY_SCALE.into();
        let first_epoch: u32 = 0;
        assert_reward_cumulative_updated(
            absorber,
            first_epoch_total_shares,
            first_epoch,
            reward_tokens,
            reward_amts_per_blessing,
            expected_first_epoch_blessings_multiplier
        );

        // First provider receives only 1 round of rewards from the full absorption.
        let expected_first_provider_blessings_multiplier =
            expected_first_epoch_blessings_multiplier;
        assert_provider_received_rewards(
            absorber,
            first_provider,
            reward_tokens,
            reward_amts_per_blessing,
            first_provider_before_reward_bals,
            preview_reward_amts,
            expected_first_provider_blessings_multiplier,
            error_margin,
        );
        assert_provider_reward_cumulatives_updated(absorber, first_provider, reward_tokens);
    }

    // Sequence of events:
    // 1. Provider 1 provides.
    // 2. Partial absorption happens, provider 1 receives 1 round of rewards.
    // 3. Provider 2 provides, provider 1 receives 1 round of rewards.
    // 4. Partial absorption happens, providers share 1 round of rewards.
    // 5. Provider 1 reaps, providers share 1 round of rewards
    // 6. Provider 2 reaps, providers share 1 round of rewards
    #[test]
    #[available_gas(20000000000)]
    fn test_multi_user_reap_same_epoch_multi_absorptions() {
        // Setup
        let (shrine, abbot, absorber, yangs, gates) = absorber_deploy();
        let reward_tokens: Span<ContractAddress> = reward_tokens_deploy();
        let reward_amts_per_blessing: Span<u128> = reward_amts_per_blessing();
        let blessers: Span<ContractAddress> = deploy_blesser_for_rewards(
            absorber, reward_tokens, reward_amts_per_blessing
        );
        add_rewards_to_absorber(absorber, reward_tokens, blessers);

        // Step 1
        let first_provider = provider_1();
        let first_provided_amt: Wad = 10000000000000000000000_u128.into(); // 10_000 (Wad)
        provide_to_absorber(
            shrine,
            abbot,
            absorber,
            first_provider,
            yangs,
            provider_asset_amts(),
            gates,
            first_provided_amt
        );

        let first_epoch_total_shares: Wad = absorber.get_total_shares_for_current_epoch();

        // Step 2
        let first_update_assets: Span<u128> = first_update_assets();
        let burn_pct: Ray = 266700000000000000000000000_u128.into(); // 26.67% (Ray)
        simulate_update_with_pct_to_drain(shrine, absorber, yangs, first_update_assets, burn_pct);

        let remaining_absorber_yin: Wad = shrine.get_yin(absorber.contract_address);
        let expected_yin_per_share: Ray = wadray::rdiv_ww(
            remaining_absorber_yin, first_provided_amt
        );

        // Step 3
        let second_provider = provider_2();
        let second_provided_amt: Wad = 5000000000000000000000_u128.into(); // 5_000 (Wad)
        provide_to_absorber(
            shrine,
            abbot,
            absorber,
            second_provider,
            yangs,
            provider_asset_amts(),
            gates,
            second_provided_amt
        );

        let expected_second_provider_shares: Wad = wadray::rdiv_wr(
            second_provided_amt, expected_yin_per_share
        );
        let second_provider_info: Provision = absorber.get_provision(second_provider);
        assert(
            second_provider_info.shares == expected_second_provider_shares, 'wrong provider shares'
        );

        let expected_epoch: u32 = 0;
        assert(second_provider_info.epoch == expected_epoch, 'wrong provider epoch');

        let error_margin: Wad = 1_u128
            .into(); // loss of precision from rounding favouring the protocol
        test_utils::assert_equalish(
            absorber.preview_remove(second_provider),
            second_provided_amt,
            error_margin,
            'wrong preview remove amount'
        );

        // Check that second provider's reward cumulatives are updated
        assert_provider_reward_cumulatives_updated(absorber, second_provider, reward_tokens);

        let aura_reward_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(*reward_tokens.at(0), 0);

        let total_shares: Wad = absorber.get_total_shares_for_current_epoch();
        let first_provider_info: Provision = absorber.get_provision(first_provider);
        let expected_first_provider_pct: Ray = wadray::rdiv_ww(
            first_provider_info.shares, total_shares
        );
        let expected_second_provider_pct: Ray = wadray::rdiv_ww(
            second_provider_info.shares, total_shares
        );

        // Step 4
        let second_update_assets: Span<u128> = second_update_assets();
        let burn_pct: Ray = 512390000000000000000000000_u128.into(); // 51.239% (Ray)
        simulate_update_with_pct_to_drain(shrine, absorber, yangs, second_update_assets, burn_pct);

        // Step 5
        let mut user_addresses: Array<ContractAddress> = Default::default();
        user_addresses.append(first_provider);

        let first_provider_before_yin_bal: Wad = shrine.get_yin(first_provider);
        let first_provider_before_reward_bals = test_utils::get_token_balances(
            reward_tokens, user_addresses.span()
        );
        let first_provider_before_absorbed_bals = test_utils::get_token_balances(
            yangs, user_addresses.span()
        );

        set_contract_address(first_provider);
        let (_, preview_absorbed_amts, _, preview_reward_amts) = absorber
            .preview_reap(first_provider);

        absorber.reap();

        // Derive the amount of absorbed assets the first provider is expected to receive
        let expected_first_provider_absorbed_asset_amts = combine_asset_amts(
            first_update_assets,
            get_asset_amts_by_pct(second_update_assets, expected_first_provider_pct)
        );

        let error_margin: Wad = 10000_u128.into(); // 10**6 (Wad)
        assert_provider_received_absorbed_assets(
            absorber,
            first_provider,
            yangs,
            expected_first_provider_absorbed_asset_amts,
            first_provider_before_absorbed_bals,
            preview_absorbed_amts,
            error_margin,
        );

        // Check reward cumulative is updated for AURA
        // Convert to Wad for fixed point operations
        let expected_aura_reward_increment: Wad = (2 * *reward_amts_per_blessing.at(0)).into();
        let expected_aura_reward_cumulative_increment: Wad = expected_aura_reward_increment
            / total_shares;
        let expected_aura_reward_cumulative: u128 = aura_reward_distribution.asset_amt_per_share
            + expected_aura_reward_cumulative_increment.val;
        let updated_aura_reward_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(*reward_tokens.at(0), 0);
        assert(
            updated_aura_reward_distribution.asset_amt_per_share == expected_aura_reward_cumulative,
            'wrong AURA reward cumulative #1'
        );

        // First provider receives 2 full rounds and 2 partial rounds of rewards.
        let expected_first_provider_partial_multiplier: Ray = (expected_first_provider_pct.val * 2)
            .into();
        let expected_first_provider_blessings_multiplier: Ray = (RAY_SCALE * 2).into()
            + expected_first_provider_partial_multiplier;
        assert_provider_received_rewards(
            absorber,
            first_provider,
            reward_tokens,
            reward_amts_per_blessing,
            first_provider_before_reward_bals,
            preview_reward_amts,
            expected_first_provider_blessings_multiplier,
            error_margin,
        );
        assert_provider_reward_cumulatives_updated(absorber, first_provider, reward_tokens);

        let expected_absorption_id: u32 = 2;
        assert(
            absorber.get_provider_last_absorption(first_provider) == expected_absorption_id,
            'wrong last absorption'
        );

        // Step 6
        let mut user_addresses: Array<ContractAddress> = Default::default();
        user_addresses.append(second_provider);

        let second_provider_before_yin_bal: Wad = shrine.get_yin(second_provider);
        let second_provider_before_reward_bals = test_utils::get_token_balances(
            reward_tokens, user_addresses.span()
        );
        let second_provider_before_absorbed_bals = test_utils::get_token_balances(
            yangs, user_addresses.span()
        );

        set_contract_address(second_provider);
        let (_, preview_absorbed_amts, _, preview_reward_amts) = absorber
            .preview_reap(second_provider);

        absorber.reap();

        // Derive the amount of absorbed assets the second provider is expected to receive
        let expected_second_provider_absorbed_asset_amts = get_asset_amts_by_pct(
            second_update_assets, expected_second_provider_pct
        );

        let error_margin: Wad = 10000_u128.into(); // 10**6 (Wad)
        assert_provider_received_absorbed_assets(
            absorber,
            second_provider,
            yangs,
            expected_second_provider_absorbed_asset_amts,
            second_provider_before_absorbed_bals,
            preview_absorbed_amts,
            error_margin,
        );

        // Check reward cumulative is updated for AURA
        // Convert to Wad for fixed point operations
        let aura_reward_distribution = updated_aura_reward_distribution;
        let expected_aura_reward_increment: Wad = (*reward_amts_per_blessing.at(0)).into();
        let expected_aura_reward_cumulative_increment: Wad = expected_aura_reward_increment
            / total_shares;
        let expected_aura_reward_cumulative: u128 = aura_reward_distribution.asset_amt_per_share
            + expected_aura_reward_cumulative_increment.val;
        let updated_aura_reward_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(*reward_tokens.at(0), 0);
        assert(
            updated_aura_reward_distribution.asset_amt_per_share == expected_aura_reward_cumulative,
            'wrong AURA reward cumulative #2'
        );

        // Second provider should receive 3 partial rounds of rewards.
        let expected_second_provider_blessings_multiplier: Ray = (expected_second_provider_pct.val
            * 3)
            .into();
        assert_provider_received_rewards(
            absorber,
            second_provider,
            reward_tokens,
            reward_amts_per_blessing,
            second_provider_before_reward_bals,
            preview_reward_amts,
            expected_second_provider_blessings_multiplier,
            error_margin,
        );
        assert_provider_reward_cumulatives_updated(absorber, second_provider, reward_tokens);

        let expected_absorption_id: u32 = 2;
        assert(
            absorber.get_provider_last_absorption(second_provider) == expected_absorption_id,
            'wrong last absorption'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_request_pass() {
        let (shrine, abbot, absorber, yangs, gates) = absorber_deploy();
        let provider: ContractAddress = provider_1();
        let first_provided_amt: Wad = 1000000000000000000000_u128.into(); // 1_000 (Wad)
        provide_to_absorber(
            shrine,
            abbot,
            absorber,
            provider,
            yangs,
            provider_asset_amts(),
            gates,
            first_provided_amt
        );
        set_contract_address(provider);
        let mut idx = 0;
        let mut expected_timelock = Absorber::REQUEST_BASE_TIMELOCK;
        loop {
            if idx == 6 {
                break;
            }

            let current_ts = get_block_timestamp();
            absorber.request();

            expected_timelock = min(expected_timelock, Absorber::REQUEST_MAX_TIMELOCK);

            let request: Request = absorber.get_provider_request(provider);
            assert(request.timestamp == current_ts, 'wrong timestamp');
            assert(request.timelock == expected_timelock, 'wrong timelock');

            let removal_ts = current_ts + expected_timelock;
            set_block_timestamp(removal_ts);

            // This should not revert
            absorber.remove(1_u128.into());

            expected_timelock *= Absorber::REQUEST_TIMELOCK_MULTIPLIER;
            idx += 1;
        };
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Relative LTV above limit', 'ENTRYPOINT_FAILED'))]
    fn test_remove_exceeds_limit_fail() {
        let (shrine, abbot, absorber, yangs, gates) = absorber_deploy();

        let provider = provider_1();
        let provided_amt: Wad = 10000000000000000000000_u128.into(); // 10_000 (Wad)
        provide_to_absorber(
            shrine,
            abbot,
            absorber,
            provider,
            yangs,
            provider_asset_amts(),
            gates,
            provided_amt
        );

        // Change ETH price to make Shrine's LTV to threshold above the limit
        let eth_addr: ContractAddress = *yangs.at(0);
        let (eth_yang_price, _, _) = shrine.get_current_yang_price(eth_addr);
        let new_eth_yang_price: Wad = (eth_yang_price.val / 5).into();  // 80% drop in price
        set_contract_address(ShrineUtils::admin());
        shrine.advance(eth_addr, new_eth_yang_price);

        let (threshold, value) = shrine.get_shrine_threshold_and_value();
        let debt: Wad = shrine.get_total_debt();
        let ltv: Ray = wadray::rdiv_ww(debt, value);
        let ltv_to_threshold: Ray = wadray::rdiv(ltv, threshold);
        let limit: Ray = absorber.get_removal_limit();
        assert(ltv_to_threshold > limit, 'sanity check for limit');

        set_contract_address(provider);
        absorber.request();
        set_block_timestamp(get_block_timestamp() + 60);
        absorber.remove(BoundedU128::max().into());
    }
}
