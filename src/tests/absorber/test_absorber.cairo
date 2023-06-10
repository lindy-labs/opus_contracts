#[cfg(test)]
mod TestAbsorber {
    use array::{ArrayTrait, SpanTrait};
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

    use aura::core::absorber::Absorber;
    use aura::core::roles::AbsorberRoles;

    use aura::interfaces::IAbsorber::{
        IAbsorberDispatcher, IAbsorberDispatcherTrait, IBlesserDispatcher, IBlesserDispatcherTrait
    };
    use aura::interfaces::IERC20::{
        IERC20Dispatcher, IERC20DispatcherTrait, IMintableDispatcher, IMintableDispatcherTrait
    };
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::types::{DistributionInfo, Provision, Reward};
    use aura::utils::wadray;
    use aura::utils::wadray::{Wad, WadZeroable, WAD_SCALE, Ray};

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

    //
    // Address constants
    //

    #[inline(always)]
    fn provider_1() -> ContractAddress {
        contract_address_const::<0xabcd>()
    }

    // TODO: delete once sentinel is up
    fn mock_sentinel() -> ContractAddress {
        contract_address_const::<0xeeee>()
    }

    //
    // Test setup helpers
    // 

    // Helper function to mint the given amount of yin to a address simulating a provider, 
    // and then provide the same amount to the Absorber
    fn provide_to_absorber(
        shrine: IShrineDispatcher,
        absorber: IAbsorberDispatcher,
        provider: ContractAddress,
        amt: Wad
    ) {
        set_contract_address(ShrineUtils::admin());
        shrine.inject(provider, amt);

        set_contract_address(provider);
        let yin = IERC20Dispatcher { contract_address: shrine.contract_address };
        yin.approve(absorber.contract_address, BoundedU256::max());
        absorber.provide(amt);
        set_contract_address(ContractAddressZeroable::zero());
    }

    fn absorber_deploy() -> (IShrineDispatcher, IAbsorberDispatcher) {
        // TODO: update to Shrine with real yangs
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        let sentinel: ContractAddress = mock_sentinel();

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(ShrineUtils::admin()));
        calldata.append(contract_address_to_felt252(shrine.contract_address));
        calldata.append(contract_address_to_felt252(sentinel));
        calldata.append(REMOVAL_LIMIT.into());

        let absorber_class_hash: ClassHash = class_hash_try_from_felt252(Absorber::TEST_CLASS_HASH)
            .unwrap();
        let (absorber_addr, _) = deploy_syscall(absorber_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        let absorber = IAbsorberDispatcher { contract_address: absorber_addr };
        (shrine, absorber)
    }

    // TODO: create a helper that deploys an ERC20 based on input args
    fn aura_token_deploy() -> ContractAddress {
        let mut calldata = Default::default();
        calldata.append('Aura');
        calldata.append('AURA');
        calldata.append(18);
        calldata.append(0); // u256.low
        calldata.append(0); // u256.high
        calldata.append(contract_address_to_felt252(ShrineUtils::admin()));

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
        calldata.append(contract_address_to_felt252(ShrineUtils::admin()));

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
        calldata.append(contract_address_to_felt252(ShrineUtils::admin()));
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
        set_contract_address(ShrineUtils::admin());

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

    //
    // Test assertion helpers
    //

    // Helper function to assert that:
    // 1. a provider has received the correct amount of reward tokens;
    // 2. the previewed amount returned by `preview_reap` is correct; and
    // 3. a provider's last cumulative asset amount per share wad value is updated for all reward tokens.
    // 
    // Arguments
    // 
    // - `absorber` - Deployed Absorber instance.
    //
    // - `provider` - Address of the provider.
    // 
    // - `epoch` - The epoch to check for
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
    fn assert_provider_received_rewards(
        absorber: IAbsorberDispatcher,
        provider: ContractAddress,
        epoch: u32,
        mut asset_addresses: Span<ContractAddress>,
        mut reward_amts_per_blessing: Span<u128>,
        mut before_balances: Span<Span<u128>>,
        mut preview_amts: Span<u128>,
        blessings_multiplier: Wad,
    ) {
        loop {
            match asset_addresses.pop_front() {
                Option::Some(asset) => {
                    // Check provider has received correct amount of reward tokens
                    // Convert to Wad for fixed point operations
                    let blessed_amt: Wad = (*reward_amts_per_blessing.pop_front().unwrap()).into()
                        * blessings_multiplier;
                    let after_provider_bal: u256 = IERC20Dispatcher {
                        contract_address: *asset
                    }.balance_of(provider);
                    let mut before_bal_arr: Span<u128> = *before_balances.pop_front().unwrap();
                    let expected_bal: Wad = (*before_bal_arr.pop_front().unwrap()).into()
                        + blessed_amt.into();
                    let error_margin: Wad = 100_u128.into();
                    ShrineUtils::assert_equalish(
                        after_provider_bal.try_into().unwrap(),
                        expected_bal,
                        error_margin,
                        'wrong rewards balance'
                    );

                    // Check preview amounts are equal
                    let preview_amt = *preview_amts.pop_front().unwrap();
                    let error_margin: Wad = 100_u128.into(); // slight offset due to initial shares
                    ShrineUtils::assert_equalish(
                        blessed_amt, preview_amt.into(), error_margin, 'wrong preview amount'
                    );

                    // Check provider's last cumulative is updated
                    let reward_info: DistributionInfo = absorber
                        .get_cumulative_reward_amt_by_epoch(*asset, epoch);
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

    // Helper function to assert that the cumulative reward token amount per share 
    // 
    // Arguments
    // 
    // - `absorber` - Deployed Absorber instance.
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
        blessings_multiplier: Wad
    ) {
        loop {
            match asset_addresses.pop_front() {
                Option::Some(asset) => {
                    let reward_distribution_info: DistributionInfo = absorber
                        .get_cumulative_reward_amt_by_epoch(*asset, epoch);
                    // Convert to Wad for fixed point operations
                    let expected_blessed_amt: Wad = (*reward_amts_per_blessing.pop_front().unwrap())
                        .into()
                        * blessings_multiplier;
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

    //
    // Tests - Setup
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_absorber_setup() {
        let (_, absorber) = absorber_deploy();

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
            absorber_ac.get_roles(ShrineUtils::admin()) == AbsorberRoles::default_admin_role(),
            'wrong role for admin'
        );
    }

    //
    // Tests - Setters
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_set_removal_limit_pass() {
        let (_, absorber) = absorber_deploy();

        set_contract_address(ShrineUtils::admin());

        let new_limit: Ray = 750000000000000000000000000_u128.into(); // 75% (Ray)
        absorber.set_removal_limit(new_limit);

        assert(absorber.get_removal_limit() == new_limit, 'limit not updated');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Limit is too low', 'ENTRYPOINT_FAILED'))]
    fn test_set_removal_limit_too_low_fail() {
        let (_, absorber) = absorber_deploy();

        set_contract_address(ShrineUtils::admin());

        let invalid_limit: Ray = (Absorber::MIN_LIMIT - 1).into();
        absorber.set_removal_limit(invalid_limit);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_removal_limit_unauthorized_fail() {
        let (_, absorber) = absorber_deploy();

        set_contract_address(ShrineUtils::badguy());

        let new_limit: Ray = 750000000000000000000000000_u128.into(); // 75% (Ray)
        absorber.set_removal_limit(new_limit);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_reward_pass() {
        let (_, absorber) = absorber_deploy();

        let aura_token: ContractAddress = aura_token_deploy();
        let aura_blesser: ContractAddress = deploy_blesser_for_reward(
            absorber, aura_token, AURA_BLESS_AMT
        );

        let veaura_token: ContractAddress = veaura_token_deploy();
        let veaura_blesser: ContractAddress = deploy_blesser_for_reward(
            absorber, veaura_token, VEAURA_BLESS_AMT
        );

        set_contract_address(ShrineUtils::admin());
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
        let (_, absorber) = absorber_deploy();

        let valid_address = contract_address_const::<0xffff>();
        let invalid_address = ContractAddressZeroable::zero();

        set_contract_address(ShrineUtils::admin());
        absorber.set_reward(valid_address, invalid_address, true);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Address cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_set_reward_blesser_zero_address_fail() {
        let (_, absorber) = absorber_deploy();

        let valid_address = contract_address_const::<0xffff>();
        let invalid_address = ContractAddressZeroable::zero();

        set_contract_address(ShrineUtils::admin());
        absorber.set_reward(invalid_address, valid_address, true);
    }

    //
    // Tests - Kill
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_kill_pass() {
        let (_, absorber) = absorber_deploy();

        set_contract_address(ShrineUtils::admin());
        absorber.kill();

        assert(!absorber.get_live(), 'should be killed');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_kill_unauthorized_fail() {
        let (_, absorber) = absorber_deploy();

        set_contract_address(ShrineUtils::badguy());
        absorber.kill();
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Not live', 'ENTRYPOINT_FAILED'))]
    fn test_provide_after_kill_fail() {
        let (shrine, absorber) = absorber_deploy();

        set_contract_address(ShrineUtils::admin());
        absorber.kill();
        provide_to_absorber(shrine, absorber, provider_1(), 1_u128.into());
    }

    //
    // Tests - Update
    //

    //
    // Tests - Provider functions (provide, request, remove, reap)
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_provide_first_epoch() {
        let (shrine, absorber) = absorber_deploy();
        let yin = IERC20Dispatcher { contract_address: shrine.contract_address };
        let reward_tokens: Span<ContractAddress> = reward_tokens_deploy();
        let reward_amts_per_blessing: Span<u128> = reward_amts_per_blessing();
        let blessers: Span<ContractAddress> = deploy_blesser_for_rewards(
            absorber, reward_tokens, reward_amts_per_blessing
        );
        add_rewards_to_absorber(absorber, reward_tokens, blessers);

        let provider: ContractAddress = provider_1();

        let first_provided_amt: Wad = 10000000000000000000000_u128.into(); // 10_000 (Wad)
        provide_to_absorber(shrine, absorber, provider, first_provided_amt);

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
        let second_provided_amt: Wad = 4000000000000000000000_u128.into(); // 4_000 (Wad)
        provide_to_absorber(shrine, absorber, provider, second_provided_amt);

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

        let expected_blessings_multiplier: Wad = WAD_SCALE.into();
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
        assert_provider_received_rewards(
            absorber,
            provider,
            expected_epoch,
            reward_tokens,
            reward_amts_per_blessing,
            before_reward_bals,
            preview_reward_amts,
            expected_blessings_multiplier,
        );
    // TODO: check reward cumulative updated
    }
}
