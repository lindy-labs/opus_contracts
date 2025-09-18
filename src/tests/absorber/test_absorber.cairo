mod test_absorber {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::num::traits::{Bounded, Zero};
    use opus::core::absorber::absorber as absorber_contract;
    use opus::core::roles::absorber_roles;
    use opus::interfaces::IAbsorber::{IAbsorberDispatcherTrait, IBlesserDispatcher};
    use opus::interfaces::IERC20::IERC20DispatcherTrait;
    use opus::interfaces::IShrine::IShrineDispatcherTrait;
    use opus::tests::absorber::utils::absorber_utils;
    use opus::tests::absorber::utils::absorber_utils::{AbsorberRewardsTestConfig, AbsorberTestConfig};
    use opus::tests::common;
    use opus::tests::common::{AddressIntoSpan, RewardPartialEq};
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::{AssetBalance, DistributionInfo, Provision, Reward};
    use snforge_std::{
        EventSpyAssertionsTrait, EventSpyTrait, spy_events, start_cheat_caller_address, stop_cheat_caller_address,
    };
    use starknet::ContractAddress;
    use wadray::{RAY_ONE, RAY_SCALE, Ray, WAD_ONE, WAD_SCALE, Wad};
    //
    // Tests - Setup
    //

    #[test]
    fn test_absorber_setup() {
        let AbsorberTestConfig { absorber, .. } = absorber_utils::absorber_deploy(Option::None);

        assert(absorber.get_total_shares_for_current_epoch().is_zero(), 'total shares should be 0');
        assert(absorber.get_current_epoch() == absorber_contract::FIRST_EPOCH, 'epoch should be 1');
        assert(absorber.get_absorptions_count() == 0, 'absorptions count should be 0');
        assert(absorber.get_rewards_count() == 0, 'rewards should be 0');
        assert(absorber.get_live(), 'should be live');
        assert(!absorber.is_operational(), 'should not be operational');

        let absorber_ac = IAccessControlDispatcher { contract_address: absorber.contract_address };
        assert(absorber_ac.get_roles(absorber_utils::ADMIN) == absorber_roles::ADMIN, 'wrong role for admin');
    }

    //
    // Tests - Setters
    //

    #[test]
    fn test_set_reward_pass() {
        let classes = absorber_utils::declare_contracts();
        let AbsorberTestConfig { absorber, .. } = absorber_utils::absorber_deploy(Option::Some(classes));

        let mut spy = spy_events();

        let opus_token: ContractAddress = absorber_utils::opus_token_deploy(classes.token);
        let opus_blesser: ContractAddress = absorber_utils::deploy_blesser_for_reward(
            absorber, opus_token, absorber_utils::OPUS_BLESS_AMT, true, classes.blesser,
        );

        let veopus_token: ContractAddress = absorber_utils::veopus_token_deploy(classes.token);
        let veopus_blesser: ContractAddress = absorber_utils::deploy_blesser_for_reward(
            absorber, veopus_token, absorber_utils::veOPUS_BLESS_AMT, true, classes.blesser,
        );

        let mut expected_events: Array<(ContractAddress, absorber_contract::Event)> = ArrayTrait::new();

        start_cheat_caller_address(absorber.contract_address, absorber_utils::ADMIN);
        absorber.set_reward(opus_token, opus_blesser, true);

        assert(absorber.get_rewards_count() == 1, 'rewards count not updated');

        let mut opus_reward = Reward {
            asset: opus_token, blesser: IBlesserDispatcher { contract_address: opus_blesser }, is_active: true,
        };
        let mut expected_rewards: Array<Reward> = array![opus_reward];

        assert(absorber.get_rewards() == expected_rewards.span(), 'rewards not equal');

        expected_events
            .append(
                (
                    absorber.contract_address,
                    absorber_contract::Event::RewardSet(
                        absorber_contract::RewardSet { asset: opus_token, blesser: opus_blesser, is_active: true },
                    ),
                ),
            );

        // Add another reward

        absorber.set_reward(veopus_token, veopus_blesser, true);

        assert(absorber.get_rewards_count() == 2, 'rewards count not updated');

        let veopus_reward = Reward {
            asset: veopus_token, blesser: IBlesserDispatcher { contract_address: veopus_blesser }, is_active: true,
        };
        expected_rewards.append(veopus_reward);

        assert(absorber.get_rewards() == expected_rewards.span(), 'rewards not equal');

        expected_events
            .append(
                (
                    absorber.contract_address,
                    absorber_contract::Event::RewardSet(
                        absorber_contract::RewardSet { asset: veopus_token, blesser: veopus_blesser, is_active: true },
                    ),
                ),
            );

        // Update existing reward
        let new_opus_blesser: ContractAddress = 'new opus blesser'.try_into().unwrap();
        opus_reward.is_active = false;
        opus_reward.blesser = IBlesserDispatcher { contract_address: new_opus_blesser };
        absorber.set_reward(opus_token, new_opus_blesser, false);

        let mut expected_rewards: Array<Reward> = array![opus_reward, veopus_reward];

        assert(absorber.get_rewards() == expected_rewards.span(), 'rewards not equal');
        expected_events
            .append(
                (
                    absorber.contract_address,
                    absorber_contract::Event::RewardSet(
                        absorber_contract::RewardSet { asset: opus_token, blesser: new_opus_blesser, is_active: false },
                    ),
                ),
            );

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: 'ABS: Address cannot be 0')]
    fn test_set_reward_blesser_zero_address_fail() {
        let AbsorberTestConfig { absorber, .. } = absorber_utils::absorber_deploy(Option::None);

        let valid_address = common::NON_ZERO_ADDR;
        let invalid_address = Zero::zero();

        start_cheat_caller_address(absorber.contract_address, absorber_utils::ADMIN);
        absorber.set_reward(valid_address, invalid_address, true);
    }

    #[test]
    #[should_panic(expected: 'ABS: Address cannot be 0')]
    fn test_set_reward_token_zero_address_fail() {
        let AbsorberTestConfig { absorber, .. } = absorber_utils::absorber_deploy(Option::None);

        let valid_address = common::NON_ZERO_ADDR;
        let invalid_address = Zero::zero();

        start_cheat_caller_address(absorber.contract_address, absorber_utils::ADMIN);
        absorber.set_reward(invalid_address, valid_address, true);
    }

    //
    // Tests - Kill
    //

    #[test]
    fn test_kill_and_remove_pass() {
        let (AbsorberTestConfig { shrine, absorber, .. }, AbsorberRewardsTestConfig { provider, provided_amt, .. }) =
            absorber_utils::absorber_with_rewards_and_first_provider(
            Option::None,
        );

        let mut spy = spy_events();

        start_cheat_caller_address(absorber.contract_address, absorber_utils::ADMIN);
        absorber.kill();

        assert(!absorber.get_live(), 'should be killed');

        // Check provider can remove
        let before_provider_yin_bal: Wad = shrine.get_yin(provider);
        start_cheat_caller_address(absorber.contract_address, provider);
        absorber.remove(Bounded::MAX);

        // Loss of precision
        let error_margin: Wad = 10_u128.into();
        common::assert_equalish(
            shrine.get_yin(provider),
            before_provider_yin_bal + provided_amt - absorber_contract::INITIAL_SHARES.into(),
            error_margin,
            'wrong yin amount',
        );

        let expected_events = array![
            (absorber.contract_address, absorber_contract::Event::Killed(absorber_contract::Killed {})),
        ];
        spy.assert_emitted(@expected_events);
    }

    // Sequence of events
    // 1. Provider 1 provides.
    // 2. Absorber is killed.
    // 3. Full absorption occurs. Provider 1 receives zero rewards.
    // 4. Provider 1 reaps.
    #[test]
    fn test_update_after_kill_pass() {
        // Setup
        let (
            AbsorberTestConfig {
                shrine, absorber, yangs, ..,
                }, AbsorberRewardsTestConfig {
                reward_tokens, provider, ..,
            },
        ) =
            absorber_utils::absorber_with_rewards_and_first_provider(
            Option::None,
        );

        let mut spy = spy_events();

        let expected_recipient_shares: Wad = absorber.get_total_shares_for_current_epoch()
            - absorber_contract::INITIAL_SHARES.into();
        let expected_epoch = 1;
        let expected_absorption_id = 1;

        // Step 2
        start_cheat_caller_address(absorber.contract_address, absorber_utils::ADMIN);
        absorber.kill();

        // Step 3
        let first_update_assets: Span<u128> = absorber_utils::first_update_assets();
        absorber_utils::simulate_update_with_pct_to_drain(
            shrine, absorber, yangs, first_update_assets, RAY_SCALE.into(),
        );

        // Assert rewards are not distributed in `update`
        assert(
            absorber
                .get_cumulative_reward_amt_by_epoch(*reward_tokens[0], expected_epoch)
                .asset_amt_per_share
                .is_zero(),
            'should be zero #1',
        );
        assert(
            absorber
                .get_cumulative_reward_amt_by_epoch(*reward_tokens[1], expected_epoch)
                .asset_amt_per_share
                .is_zero(),
            'should be zero #2',
        );

        let expected_absorbed_assets: Span<AssetBalance> = common::combine_assets_and_amts(yangs, first_update_assets);
        let expected_events = array![
            (
                absorber.contract_address,
                absorber_contract::Event::Gain(
                    absorber_contract::Gain {
                        assets: expected_absorbed_assets,
                        total_recipient_shares: expected_recipient_shares,
                        epoch: expected_epoch,
                        absorption_id: expected_absorption_id,
                    },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);

        // Step 4
        let provider_before_absorbed_bals = common::get_token_balances(yangs, provider.into());

        start_cheat_caller_address(absorber.contract_address, provider);
        let (preview_absorbed_assets, preview_reward_assets) = absorber.preview_reap(provider);

        let mut preview_reward_assets_copy = preview_reward_assets;
        for reward_asset_balance in preview_reward_assets_copy {
            assert((*reward_asset_balance).amount.is_zero(), 'rewards should be zero');
        }

        absorber.reap();

        // Assert rewards are not distributed in `reap`
        assert(
            absorber
                .get_cumulative_reward_amt_by_epoch(*reward_tokens[0], expected_epoch)
                .asset_amt_per_share
                .is_zero(),
            'should be zero #3',
        );
        assert(
            absorber
                .get_cumulative_reward_amt_by_epoch(*reward_tokens[1], expected_epoch)
                .asset_amt_per_share
                .is_zero(),
            'should be zero #4',
        );

        assert(absorber.get_provider_last_absorption(provider) == 1, 'wrong last absorption');

        let error_margin: u128 = 10000;
        absorber_utils::assert_provider_received_absorbed_assets(
            absorber,
            provider,
            first_update_assets,
            provider_before_absorbed_bals,
            preview_absorbed_assets,
            error_margin,
        );

        let expected_events = array![
            (
                absorber.contract_address,
                absorber_contract::Event::Reap(
                    absorber_contract::Reap {
                        provider, absorbed_assets: preview_absorbed_assets, reward_assets: preview_reward_assets,
                    },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_kill_unauthorized_fail() {
        let AbsorberTestConfig { absorber, .. } = absorber_utils::absorber_deploy(Option::None);

        start_cheat_caller_address(absorber.contract_address, common::BAD_GUY);
        absorber.kill();
    }

    #[test]
    #[should_panic(expected: 'ABS: Not live')]
    fn test_provide_after_kill_fail() {
        let AbsorberTestConfig { absorber, .. } = absorber_utils::absorber_deploy(Option::None);

        start_cheat_caller_address(absorber.contract_address, absorber_utils::ADMIN);
        absorber.kill();
        absorber.provide(1_u128.into());
    }

    //
    // Tests - Update
    //

    #[test]
    fn test_update_and_subsequent_provider_action() {
        let classes = absorber_utils::declare_contracts();

        // Parametrization so that the second provider action is performed
        // for each percentage
        let percentages_to_drain: Span<Ray> = array![
            21745231600000000000000000_u128.into(), // 2.17452316% (Ray)
            439210000000000000000000000_u128.into(), // 43.291% (Ray)
            RAY_ONE.into(), // 100% (Ray)
            RAY_ONE.into(), // 100% (Ray)
            21745231600000000000000000_u128.into(), // 2.17452316% (Ray)
            439210000000000000000000000_u128.into(), // 43.291% (Ray)
            439210000000000000000000000_u128.into(), // 43.291% (Ray)
            RAY_ONE.into(), // 100% (Ray)
            21745231600000000000000000_u128.into() // 2.17452316% (Ray)
        ]
            .span();

        for percentage_to_drain in percentages_to_drain {
            let (
                AbsorberTestConfig {
                    shrine, sentinel, absorber, yangs, ..,
                    }, AbsorberRewardsTestConfig {
                    reward_tokens, reward_amts_per_blessing, provider, provided_amt, ..,
                },
            ) =
                absorber_utils::absorber_with_rewards_and_first_provider(
                Option::Some(classes),
            );
            let first_provided_amt = provided_amt;

            let mut spy = spy_events();

            assert(absorber.is_operational(), 'should be operational');

            // total shares is equal to amount provided
            let before_total_shares: Wad = first_provided_amt;
            let before_gate_balances: Span<u128> = absorber_utils::get_gate_balances(sentinel, yangs);

            let expected_absorption_id = 1;

            // Simulate absorption
            let first_update_assets: Span<u128> = absorber_utils::first_update_assets();
            absorber_utils::simulate_update_with_pct_to_drain(
                shrine, absorber, yangs, first_update_assets, *percentage_to_drain,
            );

            let expected_absorbed_assets: Span<AssetBalance> = common::combine_assets_and_amts(
                yangs, first_update_assets,
            );
            let expected_rewarded_assets: Span<AssetBalance> = common::combine_assets_and_amts(
                reward_tokens, reward_amts_per_blessing,
            );
            let expected_recipient_shares = before_total_shares - absorber_contract::INITIAL_SHARES.into();
            let mut expected_events = array![
                (
                    absorber.contract_address,
                    absorber_contract::Event::Gain(
                        absorber_contract::Gain {
                            assets: expected_absorbed_assets,
                            total_recipient_shares: expected_recipient_shares,
                            epoch: 1,
                            absorption_id: expected_absorption_id,
                        },
                    ),
                ),
                (
                    absorber.contract_address,
                    absorber_contract::Event::Bestow(
                        absorber_contract::Bestow {
                            assets: expected_rewarded_assets,
                            total_recipient_shares: expected_recipient_shares,
                            epoch: 1,
                        },
                    ),
                ),
            ];

            let is_fully_absorbed = *percentage_to_drain == RAY_SCALE.into();

            let expected_epoch = if is_fully_absorbed {
                absorber_contract::FIRST_EPOCH + 1
            } else {
                absorber_contract::FIRST_EPOCH
            };
            let expected_total_shares: Wad = if is_fully_absorbed {
                Zero::zero()
            } else {
                first_provided_amt // total shares is equal to amount provided
            };

            if is_fully_absorbed {
                expected_events
                    .append(
                        (
                            absorber.contract_address,
                            absorber_contract::Event::EpochChanged(
                                absorber_contract::EpochChanged {
                                    old_epoch: absorber_contract::FIRST_EPOCH, new_epoch: expected_epoch,
                                },
                            ),
                        ),
                    );
            }

            spy.assert_emitted(@expected_events);

            assert(absorber.get_absorptions_count() == expected_absorption_id, 'wrong absorption id');

            absorber_utils::assert_update_is_correct(
                sentinel,
                absorber,
                expected_absorption_id,
                expected_recipient_shares,
                yangs,
                first_update_assets,
                before_gate_balances,
            );

            let expected_blessings_multiplier: Ray = RAY_SCALE.into();
            let absorption_epoch = absorber_contract::FIRST_EPOCH;
            absorber_utils::assert_reward_cumulative_updated(
                absorber,
                expected_recipient_shares,
                absorption_epoch,
                reward_tokens,
                reward_amts_per_blessing,
                expected_blessings_multiplier,
            );

            assert(absorber.get_total_shares_for_current_epoch() == expected_total_shares, 'wrong total shares');
            assert(absorber.get_current_epoch() == expected_epoch, 'wrong epoch');

            let before_absorbed_bals = common::get_token_balances(yangs, provider.into());
            let before_reward_bals = common::get_token_balances(reward_tokens, provider.into());
            let before_provider_yin_bal: Wad = shrine.get_yin(provider);
            let before_absorber_yin_bal: Wad = shrine.get_yin(absorber.contract_address);

            // Perform three different actions
            // (in the following order if the number of test cases is a multiple of 3):
            // 1. `provide`
            // 2. `remove`
            // 3. `reap`
            // and check that the provider receives rewards and absorbed assets

            let (preview_absorbed_assets, preview_reward_assets) = absorber.preview_reap(provider);

            let mut remove_as_second_action: bool = false;
            let mut provide_as_second_action: bool = false;
            start_cheat_caller_address(absorber.contract_address, provider);
            if percentages_to_drain.len() % 3 == 2 {
                absorber.provide(WAD_SCALE.into());
                provide_as_second_action = true;
            } else if percentages_to_drain.len() % 3 == 1 {
                absorber.remove(Bounded::MAX);
                remove_as_second_action = true;
            } else {
                absorber.reap();
            }

            // One distribution from `update` and another distribution from
            // `reap`/`remove`/`provide` if not fully absorbed
            let expected_blessings_multiplier = if is_fully_absorbed {
                RAY_SCALE.into()
            } else {
                (RAY_SCALE * 2).into()
            };

            // Check rewards
            let error_margin: u128 = 10000;
            absorber_utils::assert_provider_received_absorbed_assets(
                absorber, provider, first_update_assets, before_absorbed_bals, preview_absorbed_assets, error_margin,
            );

            let error_margin: u128 = 500;
            absorber_utils::assert_provider_received_rewards(
                absorber,
                provider,
                reward_amts_per_blessing,
                before_reward_bals,
                preview_reward_assets,
                expected_blessings_multiplier,
                error_margin,
            );
            absorber_utils::assert_provider_reward_cumulatives_updated(absorber, provider, reward_tokens);

            let (_, after_preview_reward_assets) = absorber.preview_reap(provider);
            if is_fully_absorbed {
                if provide_as_second_action {
                    // Updated preview amount should increase because of addition of error
                    // from previous redistribution
                    assert(
                        *after_preview_reward_assets.at(0).amount > *preview_reward_assets.at(0).amount,
                        'preview amount should decrease',
                    );
                    assert(absorber.is_operational(), 'should be operational');
                } else {
                    assert(after_preview_reward_assets.len().is_zero(), 'should not have rewards');
                    absorber_utils::assert_reward_errors_propagated_to_next_epoch(
                        absorber, expected_epoch - 1, reward_tokens,
                    );
                    assert(!absorber.is_operational(), 'should not be operational');
                }
            } else if after_preview_reward_assets.len().is_non_zero() {
                // Sanity check that updated preview reward amount is lower than before
                assert(
                    (*after_preview_reward_assets.at(0)).amount < (*preview_reward_assets.at(0)).amount,
                    'preview amount should decrease',
                );
            }

            // If the second action was `remove`, check that the yin balances of absorber
            // and provider are updated.
            if remove_as_second_action {
                let expected_removed_amt: Wad = wadray::rmul_wr(
                    first_provided_amt - absorber_contract::INITIAL_SHARES.into(),
                    (RAY_SCALE.into() - *percentage_to_drain),
                );
                let error_margin: Wad = 1000_u128.into();
                common::assert_equalish(
                    shrine.get_yin(provider),
                    before_provider_yin_bal + expected_removed_amt,
                    error_margin,
                    'wrong provider yin balance',
                );

                let expected_absorber_yin: Wad = before_absorber_yin_bal - expected_removed_amt;
                common::assert_equalish(
                    shrine.get_yin(absorber.contract_address),
                    expected_absorber_yin,
                    error_margin,
                    'wrong absorber yin balance',
                );
            }
        };
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_update_unauthorized_fail() {
        let classes = absorber_utils::declare_contracts();
        let (AbsorberTestConfig { absorber, yangs, .. }, _) = absorber_utils::absorber_with_rewards_and_first_provider(
            Option::Some(classes),
        );

        start_cheat_caller_address(absorber.contract_address, common::BAD_GUY);
        let first_update_assets: Span<AssetBalance> = common::combine_assets_and_amts(
            yangs, absorber_utils::first_update_assets(),
        );
        absorber.update(first_update_assets);
    }

    //
    // Tests - Provider functions (provide, remove, reap)
    //

    #[test]
    fn test_provide_first_epoch() {
        let classes = absorber_utils::declare_contracts();

        let (
            AbsorberTestConfig {
                shrine, abbot, absorber, yangs, gates, ..,
                }, AbsorberRewardsTestConfig {
                reward_tokens, reward_amts_per_blessing, provider, provided_amt, ..,
            },
        ) =
            absorber_utils::absorber_with_rewards_and_first_provider(
            Option::Some(classes),
        );
        let first_provided_amt = provided_amt;

        let mut spy = spy_events();

        let yin = shrine_utils::yin(shrine.contract_address);

        let before_provider_info: Provision = absorber.get_provision(provider);
        let before_last_absorption_id: u32 = absorber.get_provider_last_absorption(provider);
        let before_total_shares: Wad = absorber.get_total_shares_for_current_epoch();
        let before_absorber_yin_bal: u256 = yin.balance_of(absorber.contract_address);

        let before_reward_bals: Span<Span<u128>> = common::get_token_balances(reward_tokens, provider.into());

        assert(
            before_provider_info.shares + absorber_contract::INITIAL_SHARES.into() == before_total_shares,
            'wrong total shares #1',
        );
        assert(before_total_shares == first_provided_amt, 'wrong total shares #2');
        assert(before_absorber_yin_bal == first_provided_amt.into(), 'wrong yin balance');

        // Get preview amounts to check expected rewards
        let (_, preview_reward_assets) = absorber.preview_reap(provider);

        // Test subsequent deposit
        let second_provided_amt: Wad = (400 * WAD_ONE).into();
        absorber_utils::provide_to_absorber(
            shrine, abbot, absorber, provider, yangs, absorber_utils::provider_asset_amts(), gates, second_provided_amt,
        );

        let after_last_absorption_id: u32 = absorber.get_provider_last_absorption(provider);
        let after_total_shares: Wad = absorber.get_total_shares_for_current_epoch();
        let after_absorber_yin_bal: u256 = yin.balance_of(absorber.contract_address);

        // amount of new shares should be equal to amount of yin provided because amount of yin per share is 1 : 1
        assert(
            before_provider_info.shares
                + absorber_contract::INITIAL_SHARES.into()
                + second_provided_amt == after_total_shares,
            'wrong total shares #1',
        );
        assert(after_total_shares == before_total_shares + second_provided_amt, 'wrong total shares #2');
        assert(after_absorber_yin_bal == (first_provided_amt + second_provided_amt).into(), 'wrong yin balance');
        assert(before_last_absorption_id == after_last_absorption_id, 'absorption id should not change');

        let expected_recipient_shares: Wad = before_total_shares - absorber_contract::INITIAL_SHARES.into();
        let expected_blessings_multiplier: Ray = RAY_SCALE.into();
        let expected_epoch: u32 = 1;
        absorber_utils::assert_reward_cumulative_updated(
            absorber,
            expected_recipient_shares,
            expected_epoch,
            reward_tokens,
            reward_amts_per_blessing,
            expected_blessings_multiplier,
        );

        // Check rewards
        let error_margin: u128 = 1000;
        absorber_utils::assert_provider_received_rewards(
            absorber,
            provider,
            reward_amts_per_blessing,
            before_reward_bals,
            preview_reward_assets,
            expected_blessings_multiplier,
            error_margin,
        );
        absorber_utils::assert_provider_reward_cumulatives_updated(absorber, provider, reward_tokens);

        let expected_rewarded_assets: Span<AssetBalance> = common::combine_assets_and_amts(
            reward_tokens, reward_amts_per_blessing,
        );
        let expected_recipient_shares = before_total_shares - absorber_contract::INITIAL_SHARES.into();
        let expected_events = array![
            (
                absorber.contract_address,
                absorber_contract::Event::Provide(
                    absorber_contract::Provide { provider: provider, epoch: expected_epoch, yin: second_provided_amt },
                ),
            ),
            (
                absorber.contract_address,
                absorber_contract::Event::Bestow(
                    absorber_contract::Bestow {
                        assets: expected_rewarded_assets, total_recipient_shares: expected_recipient_shares, epoch: 1,
                    },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: 'ABS: Amount too low')]
    fn test_provide_amount_too_low_zero_shares_fail() {
        let AbsorberTestConfig {
            shrine, abbot, absorber, yangs, gates, ..,
        } = absorber_utils::absorber_deploy(Option::None);

        let donor: ContractAddress = absorber_utils::PROVIDER_1;
        let provider: ContractAddress = absorber_utils::PROVIDER_2;

        let provided_amt: Wad = (10000 * WAD_ONE).into();
        let provider_amt: Wad = (5000 * WAD_ONE).into();

        let yang_asset_amts: Span<u128> = absorber_utils::provider_asset_amts();
        common::fund_user(donor, yangs, yang_asset_amts);
        common::open_trove_helper(abbot, donor, yangs, yang_asset_amts, gates, provided_amt);

        let yin = shrine_utils::yin(shrine.contract_address);
        start_cheat_caller_address(shrine.contract_address, donor);
        yin.approve(absorber.contract_address, Bounded::MAX);
        yin.transfer(provider, provider_amt.into());
        stop_cheat_caller_address(shrine.contract_address);

        // Donor provides INITIAL_SHARES amount of yin
        start_cheat_caller_address(absorber.contract_address, donor);
        let initial_shares_amt: Wad = absorber_contract::INITIAL_SHARES.into();
        absorber.provide(initial_shares_amt);
        stop_cheat_caller_address(absorber.contract_address);

        let donor_provision: Provision = absorber.get_provision(donor);
        assert(donor_provision.shares.is_zero(), 'donor shares not zero');

        // Donor donates 1,000 yin
        let donation_amt: Wad = (1000 * WAD_ONE).into();
        start_cheat_caller_address(shrine.contract_address, donor);
        yin.transfer(absorber.contract_address, donation_amt.into());
        stop_cheat_caller_address(shrine.contract_address);

        assert_eq!(
            yin.balance_of(absorber.contract_address),
            (donation_amt + initial_shares_amt).into(),
            "wrong absorber yin bal",
        );

        // Provider provides a small amount
        start_cheat_caller_address(shrine.contract_address, provider);
        yin.approve(absorber.contract_address, Bounded::MAX);
        stop_cheat_caller_address(shrine.contract_address);

        start_cheat_caller_address(absorber.contract_address, provider);
        let provider_provide_amt: Wad = 1_u128.into();
        absorber.provide(provider_provide_amt);
    }

    // Sequence of events
    // 1. Provider 1 provides.
    // 2. Full absorption occurs. Provider 1 receives 1 round of rewards.
    // 3. Provider 2 provides.
    // 4. Full absorption occurs. Provider 2 receives 1 round of rewards.
    // 5. Provider 1 reaps.
    // 6. Provider 2 reaps.
    #[test]
    fn test_reap_different_epochs() {
        // Setup
        let classes = absorber_utils::declare_contracts();

        let (
            AbsorberTestConfig {
                shrine, abbot, absorber, yangs, gates, ..,
                }, AbsorberRewardsTestConfig {
                reward_tokens, reward_amts_per_blessing, provider, ..,
            },
        ) =
            absorber_utils::absorber_with_rewards_and_first_provider(
            Option::Some(classes),
        );
        let first_provider = provider;

        let mut first_spy = spy_events();

        let first_epoch_recipient_shares: Wad = absorber.get_total_shares_for_current_epoch()
            - absorber_contract::INITIAL_SHARES.into();

        // Step 2
        let first_update_assets: Span<u128> = absorber_utils::first_update_assets();
        absorber_utils::simulate_update_with_pct_to_drain(
            shrine, absorber, yangs, first_update_assets, RAY_SCALE.into(),
        );

        // Second epoch starts here
        // Step 3
        let second_provider = absorber_utils::PROVIDER_2;
        let second_provided_amt: Wad = (5000 * WAD_ONE).into();
        absorber_utils::provide_to_absorber(
            shrine,
            abbot,
            absorber,
            second_provider,
            yangs,
            absorber_utils::provider_asset_amts(),
            gates,
            second_provided_amt,
        );

        // Check provision in new epoch
        let second_provider_info: Provision = absorber.get_provision(second_provider);
        assert(absorber.get_total_shares_for_current_epoch() == second_provided_amt, 'wrong total shares');
        assert(
            second_provider_info.shares + absorber_contract::INITIAL_SHARES.into() == second_provided_amt,
            'wrong provider shares',
        );

        let second_epoch: u32 = absorber_contract::FIRST_EPOCH + 1;
        assert(second_provider_info.epoch == second_epoch, 'wrong provider epoch');

        let second_epoch_recipient_shares: Wad = absorber.get_total_shares_for_current_epoch()
            - absorber_contract::INITIAL_SHARES.into();

        // Step 4

        let second_update_assets: Span<u128> = absorber_utils::second_update_assets();
        absorber_utils::simulate_update_with_pct_to_drain(
            shrine, absorber, yangs, second_update_assets, RAY_SCALE.into(),
        );

        let third_epoch: u32 = second_epoch + 1;
        assert(absorber.get_current_epoch() == third_epoch, 'wrong epoch');
        assert(!absorber.is_operational(), 'should not be operational');

        let expected_absorption_id = 2;
        let expected_absorbed_assets: Span<AssetBalance> = common::combine_assets_and_amts(yangs, second_update_assets);
        let expected_rewarded_assets: Span<AssetBalance> = common::combine_assets_and_amts(
            reward_tokens, reward_amts_per_blessing,
        );
        let expected_events = array![
            (
                absorber.contract_address,
                absorber_contract::Event::Gain(
                    absorber_contract::Gain {
                        assets: expected_absorbed_assets,
                        total_recipient_shares: second_epoch_recipient_shares,
                        epoch: second_epoch,
                        absorption_id: expected_absorption_id,
                    },
                ),
            ),
            // Rewards should be distributed together with the second full
            // absorption
            (
                absorber.contract_address,
                absorber_contract::Event::Bestow(
                    absorber_contract::Bestow {
                        assets: expected_rewarded_assets,
                        total_recipient_shares: second_epoch_recipient_shares,
                        epoch: second_epoch,
                    },
                ),
            ),
        ];
        first_spy.assert_emitted(@expected_events);

        // Step 5
        // Reset the event spy so all previous unchecked events are dropped
        let mut second_spy = spy_events();

        let first_provider_before_reward_bals = common::get_token_balances(reward_tokens, first_provider.into());
        let first_provider_before_absorbed_bals = common::get_token_balances(yangs, first_provider.into());

        start_cheat_caller_address(absorber.contract_address, first_provider);
        let (preview_absorbed_assets, preview_reward_assets) = absorber.preview_reap(first_provider);

        absorber.reap();

        assert(absorber.get_provider_last_absorption(first_provider) == 2, 'wrong last absorption');

        let error_margin: u128 = 10000;
        absorber_utils::assert_provider_received_absorbed_assets(
            absorber,
            first_provider,
            first_update_assets,
            first_provider_before_absorbed_bals,
            preview_absorbed_assets,
            error_margin,
        );

        let expected_blessings_multiplier: Ray = RAY_SCALE.into();
        absorber_utils::assert_reward_cumulative_updated(
            absorber,
            first_epoch_recipient_shares,
            absorber_contract::FIRST_EPOCH,
            reward_tokens,
            reward_amts_per_blessing,
            expected_blessings_multiplier,
        );

        // Check rewards
        absorber_utils::assert_provider_received_rewards(
            absorber,
            first_provider,
            reward_amts_per_blessing,
            first_provider_before_reward_bals,
            preview_reward_assets,
            expected_blessings_multiplier,
            error_margin,
        );
        absorber_utils::assert_provider_reward_cumulatives_updated(absorber, first_provider, reward_tokens);

        let third_epoch_total_shares: Wad = absorber.get_total_shares_for_current_epoch();
        assert(third_epoch_total_shares.is_zero(), 'wrong total shares');
        let expected_events = array![
            (
                absorber.contract_address,
                absorber_contract::Event::Reap(
                    absorber_contract::Reap {
                        provider: first_provider,
                        absorbed_assets: preview_absorbed_assets,
                        reward_assets: preview_reward_assets,
                    },
                ),
            ),
        ];

        let events = second_spy.get_events().events;

        // No rewards should be bestowed because Absorber is inoperational
        // after second absorption.
        common::assert_event_not_emitted_by_name(events.span(), selector!("Bestow"));

        second_spy.assert_emitted(@expected_events);

        // Step 6
        // Reset the event spy so all previous unchecked events are dropped
        let mut third_spy = spy_events();

        let second_provider_before_reward_bals = common::get_token_balances(reward_tokens, second_provider.into());
        let second_provider_before_absorbed_bals = common::get_token_balances(yangs, second_provider.into());

        start_cheat_caller_address(absorber.contract_address, second_provider);
        let (preview_absorbed_assets, preview_reward_assets) = absorber.preview_reap(second_provider);

        absorber.reap();

        assert(absorber.get_provider_last_absorption(second_provider) == 2, 'wrong last absorption');

        let error_margin: u128 = 10000;
        absorber_utils::assert_provider_received_absorbed_assets(
            absorber,
            second_provider,
            second_update_assets,
            second_provider_before_absorbed_bals,
            preview_absorbed_assets,
            error_margin,
        );

        let expected_blessings_multiplier: Ray = RAY_SCALE.into();
        absorber_utils::assert_reward_cumulative_updated(
            absorber,
            second_epoch_recipient_shares,
            second_epoch,
            reward_tokens,
            reward_amts_per_blessing,
            expected_blessings_multiplier,
        );

        // Check rewards
        absorber_utils::assert_provider_received_rewards(
            absorber,
            second_provider,
            reward_amts_per_blessing,
            second_provider_before_reward_bals,
            preview_reward_assets,
            expected_blessings_multiplier,
            error_margin,
        );
        absorber_utils::assert_provider_reward_cumulatives_updated(absorber, second_provider, reward_tokens);

        let expected_events = array![
            (
                absorber.contract_address,
                absorber_contract::Event::Reap(
                    absorber_contract::Reap {
                        provider: second_provider,
                        absorbed_assets: preview_absorbed_assets,
                        reward_assets: preview_reward_assets,
                    },
                ),
            ),
        ];

        let events = third_spy.get_events().events;

        // No rewards should be bestowed because Absorber is inoperational
        // after second absorption.
        common::assert_event_not_emitted_by_name(events.span(), selector!("Bestow"));

        third_spy.assert_emitted(@expected_events);
    }


    // Sequence of events:
    // 1. Provider 1 provides
    // 2. Absorption occurs; yin per share falls below threshold, and yin amount is
    //    greater than the minimum initial shares. Provider 1 receives 1 round of rewards.
    // 3. Provider 2 provides, provider 1 receives 1 round of rewards.
    // 4. Provider 1 withdraws, both providers share 1 round of rewards.
    #[test]
    fn test_provide_after_threshold_absorption_above_minimum() {
        let classes = absorber_utils::declare_contracts();

        let (
            AbsorberTestConfig {
                shrine, abbot, absorber, yangs, gates, ..,
                }, AbsorberRewardsTestConfig {
                reward_tokens, reward_amts_per_blessing, provider, provided_amt, ..,
            },
        ) =
            absorber_utils::absorber_with_rewards_and_first_provider(
            Option::Some(classes),
        );
        let first_provider = provider;
        let first_provided_amt = provided_amt;

        let mut spy = spy_events();

        assert(absorber.is_operational(), 'should be operational');

        let first_epoch_total_shares: Wad = absorber.get_total_shares_for_current_epoch();

        // Step 2
        let first_update_assets: Span<u128> = absorber_utils::first_update_assets();
        // Amount of yin remaining needs to be sufficiently significant to account for loss of precision
        // from conversion of shares across epochs, after discounting initial shares.
        let above_min_shares: Wad = (absorber_contract::INITIAL_SHARES + absorber_contract::MINIMUM_RECIPIENT_SHARES)
            .into();
        let burn_amt: Wad = first_provided_amt - above_min_shares;
        absorber_utils::simulate_update_with_amt_to_drain(shrine, absorber, yangs, first_update_assets, burn_amt);

        assert(absorber.is_operational(), 'should be operational');

        // Check epoch and total shares after threshold absorption
        let expected_current_epoch: u32 = absorber_contract::FIRST_EPOCH + 1;
        assert(absorber.get_current_epoch() == expected_current_epoch, 'wrong epoch');
        assert(absorber.get_total_shares_for_current_epoch() == above_min_shares, 'wrong total shares');

        absorber_utils::assert_reward_errors_propagated_to_next_epoch(
            absorber, absorber_contract::FIRST_EPOCH, reward_tokens,
        );

        let expected_absorbed_assets: Span<AssetBalance> = common::combine_assets_and_amts(yangs, first_update_assets);
        let expected_rewarded_assets: Span<AssetBalance> = common::combine_assets_and_amts(
            reward_tokens, reward_amts_per_blessing,
        );
        let first_epoch_recipient_shares = first_epoch_total_shares - absorber_contract::INITIAL_SHARES.into();
        let expected_events = array![
            (
                absorber.contract_address,
                absorber_contract::Event::Gain(
                    absorber_contract::Gain {
                        assets: expected_absorbed_assets,
                        total_recipient_shares: first_epoch_recipient_shares,
                        epoch: absorber_contract::FIRST_EPOCH,
                        absorption_id: 1,
                    },
                ),
            ),
            (
                absorber.contract_address,
                absorber_contract::Event::Bestow(
                    absorber_contract::Bestow {
                        assets: expected_rewarded_assets,
                        total_recipient_shares: first_epoch_recipient_shares,
                        epoch: absorber_contract::FIRST_EPOCH,
                    },
                ),
            ),
            (
                absorber.contract_address,
                absorber_contract::Event::EpochChanged(
                    absorber_contract::EpochChanged {
                        old_epoch: absorber_contract::FIRST_EPOCH, new_epoch: expected_current_epoch,
                    },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);

        // Second epoch starts here
        // Step 3
        let second_epoch_recipient_shares: Wad = absorber.get_total_shares_for_current_epoch()
            - absorber_contract::INITIAL_SHARES.into();

        let second_provider = absorber_utils::PROVIDER_2;
        let second_provided_amt: Wad = (5000 * WAD_ONE).into();
        absorber_utils::provide_to_absorber(
            shrine,
            abbot,
            absorber,
            second_provider,
            yangs,
            absorber_utils::provider_asset_amts(),
            gates,
            second_provided_amt,
        );

        assert(absorber.is_operational(), 'should be operational');

        let second_provider_info: Provision = absorber.get_provision(second_provider);
        assert(second_provider_info.shares == second_provided_amt, 'wrong provider shares');
        assert(second_provider_info.epoch == expected_current_epoch, 'wrong provider epoch');

        let error_margin: Wad = 1000_u128.into();
        common::assert_equalish(
            absorber.preview_remove(second_provider), second_provided_amt, error_margin, 'wrong preview remove amount',
        );

        let expected_events = array![
            (
                absorber.contract_address,
                absorber_contract::Event::Provide(
                    absorber_contract::Provide {
                        provider: second_provider, epoch: expected_current_epoch, yin: second_provided_amt,
                    },
                ),
            ),
            (
                absorber.contract_address,
                absorber_contract::Event::Bestow(
                    absorber_contract::Bestow {
                        assets: expected_rewarded_assets,
                        total_recipient_shares: second_epoch_recipient_shares,
                        epoch: expected_current_epoch,
                    },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);

        // Step 4
        let first_provider_before_yin_bal: Wad = shrine.get_yin(first_provider);
        let first_provider_before_reward_bals = common::get_token_balances(reward_tokens, first_provider.into());
        let first_provider_before_absorbed_bals = common::get_token_balances(yangs, first_provider.into());

        let updated_second_epoch_recipient_shares: Wad = absorber.get_total_shares_for_current_epoch()
            - absorber_contract::INITIAL_SHARES.into();

        start_cheat_caller_address(absorber.contract_address, first_provider);
        let (preview_absorbed_assets, preview_reward_assets) = absorber.preview_reap(first_provider);

        absorber.remove(Bounded::MAX);

        assert(absorber.is_operational(), 'should be operational');

        // Check that first provider receives some amount of yin from the converted
        // epoch shares.
        let first_provider_after_yin_bal = shrine.get_yin(first_provider);
        assert(first_provider_after_yin_bal > first_provider_before_yin_bal, 'yin balance should be higher');

        let first_provider_info: Provision = absorber.get_provision(first_provider);
        assert(first_provider_info.shares.is_zero(), 'wrong provider shares');
        assert(first_provider_info.epoch == expected_current_epoch, 'wrong provider epoch');

        let error_margin: u128 = 10000;
        absorber_utils::assert_provider_received_absorbed_assets(
            absorber,
            first_provider,
            first_update_assets,
            first_provider_before_absorbed_bals,
            preview_absorbed_assets,
            error_margin,
        );

        // Check rewards
        let expected_first_epoch_blessings_multiplier: Ray = RAY_SCALE.into();
        absorber_utils::assert_reward_cumulative_updated(
            absorber,
            first_epoch_recipient_shares,
            absorber_contract::FIRST_EPOCH,
            reward_tokens,
            reward_amts_per_blessing,
            expected_first_epoch_blessings_multiplier,
        );

        let expected_first_provider_blessings_multiplier = (2 * RAY_SCALE).into();
        // Loosen error margin due to loss of precision from epoch share conversion
        let error_margin: u128 = WAD_SCALE;
        absorber_utils::assert_provider_received_rewards(
            absorber,
            first_provider,
            reward_amts_per_blessing,
            first_provider_before_reward_bals,
            preview_reward_assets,
            expected_first_provider_blessings_multiplier,
            error_margin,
        );
        absorber_utils::assert_provider_reward_cumulatives_updated(absorber, first_provider, reward_tokens);

        let expected_events = array![
            (
                absorber.contract_address,
                absorber_contract::Event::Remove(
                    absorber_contract::Remove {
                        provider: first_provider,
                        epoch: expected_current_epoch,
                        yin: first_provider_after_yin_bal - first_provider_before_yin_bal,
                    },
                ),
            ),
            (
                absorber.contract_address,
                absorber_contract::Event::Bestow(
                    absorber_contract::Bestow {
                        assets: expected_rewarded_assets,
                        total_recipient_shares: updated_second_epoch_recipient_shares,
                        epoch: expected_current_epoch,
                    },
                ),
            ),
            (
                absorber.contract_address,
                absorber_contract::Event::Reap(
                    absorber_contract::Reap {
                        provider: first_provider,
                        absorbed_assets: preview_absorbed_assets,
                        reward_assets: preview_reward_assets,
                    },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    // Test 1 wei above initial shares remaining after absorption.
    // Sequence of events:
    // 1. Provider 1 provides
    // 2. Absorption occurs; yin per share falls below threshold, and yin amount is
    //    exactly 1 wei greater than the minimum initial shares.
    // 3. Provider 1 should have zero shares due to loss of precision
    #[test]
    fn test_provider_shares_after_threshold_absorption_with_minimum_shares() {
        let classes = absorber_utils::declare_contracts();
        let (
            AbsorberTestConfig {
                shrine, absorber, yangs, ..,
                }, AbsorberRewardsTestConfig {
                reward_tokens, provider, provided_amt, ..,
            },
        ) =
            absorber_utils::absorber_with_rewards_and_first_provider(
            Option::Some(classes),
        );
        let first_provider = provider;
        let first_provided_amt = provided_amt;

        let mut spy = spy_events();

        // Step 2
        let first_update_assets: Span<u128> = absorber_utils::first_update_assets();
        // Amount of yin remaining needs to be sufficiently significant to account for loss of precision
        // from conversion of shares across epochs, after discounting initial shares.
        let excess_above_minimum: Wad = 1_u128.into();
        let above_min_shares: Wad = absorber_contract::INITIAL_SHARES.into() + excess_above_minimum;
        let burn_amt: Wad = first_provided_amt - above_min_shares;
        absorber_utils::simulate_update_with_amt_to_drain(shrine, absorber, yangs, first_update_assets, burn_amt);

        // Check epoch and total shares after threshold absorption
        let expected_epoch: u32 = absorber_contract::FIRST_EPOCH + 1;
        assert(absorber.get_current_epoch() == expected_epoch, 'wrong epoch');
        assert(absorber.get_total_shares_for_current_epoch() == above_min_shares, 'wrong total shares #1');
        assert(!absorber.is_operational(), 'should not be operational');

        absorber_utils::assert_reward_errors_propagated_to_next_epoch(absorber, expected_epoch - 1, reward_tokens);

        // Step 3
        start_cheat_caller_address(absorber.contract_address, first_provider);

        // Trigger an update of the provider's Provision
        absorber.reap();
        let first_provider_info: Provision = absorber.get_provision(first_provider);
        // FIrst provider has zero shares due to loss of precision
        assert(first_provider_info.shares.is_zero(), 'wrong provider shares');
        assert(first_provider_info.epoch == expected_epoch, 'wrong provider epoch');
        assert(absorber.get_total_shares_for_current_epoch() == above_min_shares, 'wrong total shares #2');

        let expected_events = array![
            (
                absorber.contract_address,
                absorber_contract::Event::EpochChanged(
                    absorber_contract::EpochChanged {
                        old_epoch: absorber_contract::FIRST_EPOCH, new_epoch: expected_epoch,
                    },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    // Sequence of events:
    // 1. Provider 1 provides
    // 2. Absorption occurs; yin per share falls below threshold, and yin amount is
    //    below the initial shares so total shares in new epoch starts from 0.
    //    No rewards are distributed because total shares is zeroed.
    // 3. Provider 2 provides, provider 1 receives 1 round of rewards.
    // 4. Provider 1 withdraws, both providers share 1 round of rewards.
    #[test]
    fn test_provide_after_threshold_absorption_below_initial_shares() {
        let classes = absorber_utils::declare_contracts();
        let (
            AbsorberTestConfig {
                shrine, abbot, absorber, yangs, gates, ..,
                }, AbsorberRewardsTestConfig {
                reward_tokens, reward_amts_per_blessing, provider, provided_amt, ..,
            },
        ) =
            absorber_utils::absorber_with_rewards_and_first_provider(
            Option::Some(classes),
        );
        let first_provider = provider;
        let first_provided_amt = provided_amt;

        let mut spy = spy_events();

        let first_epoch_recipient_shares: Wad = absorber.get_total_shares_for_current_epoch()
            - absorber_contract::INITIAL_SHARES.into();

        // Step 2
        let first_update_assets: Span<u128> = absorber_utils::first_update_assets();
        let burn_amt: Wad = first_provided_amt - absorber_contract::INITIAL_SHARES.into();
        absorber_utils::simulate_update_with_amt_to_drain(shrine, absorber, yangs, first_update_assets, burn_amt);

        // Check epoch and total shares after threshold absorption
        let expected_current_epoch: u32 = absorber_contract::FIRST_EPOCH + 1;
        assert(absorber.get_current_epoch() == expected_current_epoch, 'wrong epoch');
        assert(absorber.get_total_shares_for_current_epoch().is_zero(), 'wrong total shares #1');

        absorber_utils::assert_reward_errors_propagated_to_next_epoch(
            absorber, absorber_contract::FIRST_EPOCH, reward_tokens,
        );

        assert(!absorber.is_operational(), 'should not be operational');

        let expected_events = array![
            (
                absorber.contract_address,
                absorber_contract::Event::EpochChanged(
                    absorber_contract::EpochChanged {
                        old_epoch: absorber_contract::FIRST_EPOCH, new_epoch: expected_current_epoch,
                    },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);

        // Second epoch starts here
        // Step 3
        let second_provider = absorber_utils::PROVIDER_2;
        let second_provided_amt: Wad = (5000 * WAD_ONE).into();
        absorber_utils::provide_to_absorber(
            shrine,
            abbot,
            absorber,
            second_provider,
            yangs,
            absorber_utils::provider_asset_amts(),
            gates,
            second_provided_amt,
        );

        assert(absorber.is_operational(), 'should be operational');

        let second_provider_info: Provision = absorber.get_provision(second_provider);
        assert(absorber.get_total_shares_for_current_epoch() == second_provided_amt, 'wrong total shares #2');
        assert(
            second_provider_info.shares == second_provided_amt - absorber_contract::INITIAL_SHARES.into(),
            'wrong provider shares',
        );
        assert(second_provider_info.epoch == expected_current_epoch, 'wrong provider epoch');

        let error_margin: Wad = 1000_u128.into(); // equal to initial minimum shares
        common::assert_equalish(
            absorber.preview_remove(second_provider), second_provided_amt, error_margin, 'wrong preview remove amount',
        );

        // Step 4
        let first_provider_before_yin_bal: Wad = shrine.get_yin(first_provider);
        let first_provider_before_reward_bals = common::get_token_balances(reward_tokens, first_provider.into());
        let first_provider_before_absorbed_bals = common::get_token_balances(yangs, first_provider.into());

        start_cheat_caller_address(absorber.contract_address, first_provider);
        let (preview_absorbed_assets, preview_reward_assets) = absorber.preview_reap(first_provider);

        absorber.remove(Bounded::MAX);

        assert(absorber.is_operational(), 'should be operational');

        // First provider should not receive any yin
        assert(shrine.get_yin(first_provider) == first_provider_before_yin_bal, 'yin balance should not change');

        let first_provider_info: Provision = absorber.get_provision(first_provider);
        assert(first_provider_info.shares.is_zero(), 'wrong provider shares');
        assert(first_provider_info.epoch == expected_current_epoch, 'wrong provider epoch');

        let error_margin: u128 = 10000;
        absorber_utils::assert_provider_received_absorbed_assets(
            absorber,
            first_provider,
            first_update_assets,
            first_provider_before_absorbed_bals,
            preview_absorbed_assets,
            error_margin,
        );

        // Check rewards
        let expected_first_epoch_blessings_multiplier: Ray = RAY_SCALE.into();
        absorber_utils::assert_reward_cumulative_updated(
            absorber,
            first_epoch_recipient_shares,
            absorber_contract::FIRST_EPOCH,
            reward_tokens,
            reward_amts_per_blessing,
            expected_first_epoch_blessings_multiplier,
        );

        // First provider receives only 1 round of rewards from the full absorption.
        let expected_first_provider_blessings_multiplier = expected_first_epoch_blessings_multiplier;
        absorber_utils::assert_provider_received_rewards(
            absorber,
            first_provider,
            reward_amts_per_blessing,
            first_provider_before_reward_bals,
            preview_reward_assets,
            expected_first_provider_blessings_multiplier,
            error_margin,
        );
        absorber_utils::assert_provider_reward_cumulatives_updated(absorber, first_provider, reward_tokens);
    }

    // Test amount of yin remaining after absorption is above initial shares but below
    // minimum shares
    // Sequence of events:
    // 1. Provider 1 provides
    // 2. Absorption occurs; yin per share falls below threshold, and yin amount is
    //    above initial shares but below minimum shares
    // 3. Provider 1 withdraws, no rewards should be distributed.
    #[test]
    fn test_after_threshold_absorption_between_initial_and_minimum_shares() {
        let classes = absorber_utils::declare_contracts();

        let remaining_yin_amts: Array<Wad> = array![
            // lower bound for remaining yin without total shares being zeroed
            (absorber_contract::INITIAL_SHARES + 1)
                .into(), // upper bound for remaining yin before rewards are distributed
            (absorber_contract::INITIAL_SHARES + absorber_contract::MINIMUM_RECIPIENT_SHARES - 1).into(),
        ];
        let mut remaining_yin_amts = remaining_yin_amts.span();

        for remaining_yin_amt in remaining_yin_amts {
            let (
                AbsorberTestConfig {
                    shrine, absorber, yangs, ..,
                    }, AbsorberRewardsTestConfig {
                    reward_tokens, reward_amts_per_blessing, provider, provided_amt, ..,
                },
            ) =
                absorber_utils::absorber_with_rewards_and_first_provider(
                Option::Some(classes),
            );
            let first_provider = provider;
            let first_provided_amt = provided_amt;

            let mut spy = spy_events();

            // Step 2
            let first_update_assets: Span<u128> = absorber_utils::first_update_assets();
            let burn_amt: Wad = first_provided_amt - *remaining_yin_amt;
            absorber_utils::simulate_update_with_amt_to_drain(shrine, absorber, yangs, first_update_assets, burn_amt);

            assert(!absorber.is_operational(), 'should not be operational');

            // Check epoch and total shares after threshold absorption
            let expected_epoch: u32 = absorber_contract::FIRST_EPOCH + 1;
            assert(absorber.get_current_epoch() == expected_epoch, 'wrong epoch');
            // New total shares should be equivalent to remaining yin in Absorber
            assert(absorber.get_total_shares_for_current_epoch() == *remaining_yin_amt, 'wrong total shares');

            absorber_utils::assert_reward_errors_propagated_to_next_epoch(absorber, expected_epoch - 1, reward_tokens);

            let expected_events = array![
                (
                    absorber.contract_address,
                    absorber_contract::Event::EpochChanged(
                        absorber_contract::EpochChanged {
                            old_epoch: absorber_contract::FIRST_EPOCH, new_epoch: expected_epoch,
                        },
                    ),
                ),
            ];
            spy.assert_emitted(@expected_events);

            // Step 3
            let first_provider_before_reward_bals = common::get_token_balances(reward_tokens, first_provider.into());

            start_cheat_caller_address(absorber.contract_address, first_provider);
            let (_, preview_reward_assets) = absorber.preview_reap(first_provider);

            // Trigger an update of the provider's Provision
            absorber.reap();
            let first_provider_info: Provision = absorber.get_provision(first_provider);
            let expected_provider_shares: Wad = *remaining_yin_amt - absorber_contract::INITIAL_SHARES.into();
            common::assert_equalish(
                first_provider_info.shares,
                expected_provider_shares,
                1_u128.into(), // error margin for loss of precision from rounding down
                'wrong provider shares',
            );
            assert(first_provider_info.epoch == expected_epoch, 'wrong provider epoch');

            let expected_first_provider_blessings_multiplier: Ray = RAY_SCALE.into();
            let error_margin: u128 = 1000;
            absorber_utils::assert_provider_received_rewards(
                absorber,
                first_provider,
                reward_amts_per_blessing,
                first_provider_before_reward_bals,
                preview_reward_assets,
                expected_first_provider_blessings_multiplier,
                error_margin,
            );

            let (_, preview_reward_assets) = absorber.preview_reap(first_provider);
            for reward_asset in preview_reward_assets {
                assert((*reward_asset.amount).is_zero(), 'expected rewards should be 0');
            }
        };
    }

    // Sequence of events:
    // 1. Provider 1 provides.
    // 2. Partial absorption happens, provider 1 receives 1 round of rewards.
    // 3. Provider 2 provides, provider 1 receives 1 round of rewards.
    // 4. Partial absorption happens, providers share 1 round of rewards.
    // 5. Provider 1 reaps, providers share 1 round of rewards
    // 6. Provider 2 reaps, providers share 1 round of rewards
    #[test]
    fn test_multi_user_reap_same_epoch_multi_absorptions() {
        let classes = absorber_utils::declare_contracts();
        let (
            AbsorberTestConfig {
                shrine, abbot, absorber, yangs, gates, ..,
                }, AbsorberRewardsTestConfig {
                reward_tokens, reward_amts_per_blessing, provider, provided_amt, ..,
            },
        ) =
            absorber_utils::absorber_with_rewards_and_first_provider(
            Option::Some(classes),
        );
        let first_provider = provider;
        let first_provided_amt = provided_amt;

        // Step 2
        let first_update_assets: Span<u128> = absorber_utils::first_update_assets();
        let burn_pct: Ray = 266700000000000000000000000_u128.into(); // 26.67% (Ray)
        absorber_utils::simulate_update_with_pct_to_drain(shrine, absorber, yangs, first_update_assets, burn_pct);

        let remaining_absorber_yin: Wad = shrine.get_yin(absorber.contract_address);
        let expected_yin_per_share: Ray = wadray::rdiv_ww(remaining_absorber_yin, first_provided_amt);

        // Step 3
        let second_provider = absorber_utils::PROVIDER_2;
        let second_provided_amt: Wad = (5000 * WAD_ONE).into();
        absorber_utils::provide_to_absorber(
            shrine,
            abbot,
            absorber,
            second_provider,
            yangs,
            absorber_utils::provider_asset_amts(),
            gates,
            second_provided_amt,
        );

        let expected_second_provider_shares: Wad = wadray::rdiv_wr(second_provided_amt, expected_yin_per_share);
        let second_provider_info: Provision = absorber.get_provision(second_provider);
        assert(second_provider_info.shares == expected_second_provider_shares, 'wrong provider shares');

        let expected_current_epoch: u32 = absorber_contract::FIRST_EPOCH;
        assert(second_provider_info.epoch == expected_current_epoch, 'wrong provider epoch');

        // loss of precision from rounding favouring the protocol
        let error_margin: Wad = 1_u128.into();
        common::assert_equalish(
            absorber.preview_remove(second_provider), second_provided_amt, error_margin, 'wrong preview remove amount',
        );

        // Check that second provider's reward cumulatives are updated
        absorber_utils::assert_provider_reward_cumulatives_updated(absorber, second_provider, reward_tokens);

        let opus_reward_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(*reward_tokens.at(0), absorber_contract::FIRST_EPOCH);

        let total_recipient_shares: Wad = absorber.get_total_shares_for_current_epoch()
            - absorber_contract::INITIAL_SHARES.into();
        let first_provider_info: Provision = absorber.get_provision(first_provider);
        let expected_first_provider_pct: Ray = wadray::rdiv_ww(first_provider_info.shares, total_recipient_shares);
        let expected_second_provider_pct: Ray = wadray::rdiv_ww(second_provider_info.shares, total_recipient_shares);

        // Step 4
        let second_update_assets: Span<u128> = absorber_utils::second_update_assets();
        let burn_pct: Ray = 512390000000000000000000000_u128.into(); // 51.239% (Ray)
        absorber_utils::simulate_update_with_pct_to_drain(shrine, absorber, yangs, second_update_assets, burn_pct);

        // Step 5
        let first_provider_before_reward_bals = common::get_token_balances(reward_tokens, first_provider.into());
        let first_provider_before_absorbed_bals = common::get_token_balances(yangs, first_provider.into());

        start_cheat_caller_address(absorber.contract_address, first_provider);
        let (preview_absorbed_assets, preview_reward_assets) = absorber.preview_reap(first_provider);

        absorber.reap();

        // Derive the amount of absorbed assets the first provider is expected to receive
        let expected_first_provider_absorbed_asset_amts = common::combine_spans(
            first_update_assets, common::scale_span_by_pct(second_update_assets, expected_first_provider_pct),
        );

        let error_margin: u128 = 10000;
        absorber_utils::assert_provider_received_absorbed_assets(
            absorber,
            first_provider,
            expected_first_provider_absorbed_asset_amts,
            first_provider_before_absorbed_bals,
            preview_absorbed_assets,
            error_margin,
        );

        // Check reward cumulative is updated for opus
        // Convert to Wad for fixed point operations
        let expected_opus_reward_increment: Wad = (2 * *reward_amts_per_blessing.at(0)).into();
        let expected_opus_reward_cumulative_increment: Wad = expected_opus_reward_increment / total_recipient_shares;
        let expected_opus_reward_cumulative: u128 = opus_reward_distribution.asset_amt_per_share
            + expected_opus_reward_cumulative_increment.into();
        let updated_opus_reward_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(*reward_tokens.at(0), absorber_contract::FIRST_EPOCH);
        assert(
            updated_opus_reward_distribution.asset_amt_per_share == expected_opus_reward_cumulative,
            'wrong opus reward cumulative #1',
        );

        // First provider receives 2 full rounds and 2 partial rounds of rewards.
        let expected_first_provider_partial_multiplier: Ray = (expected_first_provider_pct.into() * 2_u128).into();
        let expected_first_provider_blessings_multiplier: Ray = (RAY_SCALE * 2).into()
            + expected_first_provider_partial_multiplier;
        absorber_utils::assert_provider_received_rewards(
            absorber,
            first_provider,
            reward_amts_per_blessing,
            first_provider_before_reward_bals,
            preview_reward_assets,
            expected_first_provider_blessings_multiplier,
            error_margin,
        );
        absorber_utils::assert_provider_reward_cumulatives_updated(absorber, first_provider, reward_tokens);

        let expected_absorption_id: u32 = 2;
        assert(
            absorber.get_provider_last_absorption(first_provider) == expected_absorption_id, 'wrong last absorption',
        );

        // Step 6
        let second_provider_before_reward_bals = common::get_token_balances(reward_tokens, second_provider.into());
        let second_provider_before_absorbed_bals = common::get_token_balances(yangs, second_provider.into());

        start_cheat_caller_address(absorber.contract_address, second_provider);
        let (preview_absorbed_assets, preview_reward_assets) = absorber.preview_reap(second_provider);

        absorber.reap();

        // Derive the amount of absorbed assets the second provider is expected to receive
        let expected_second_provider_absorbed_asset_amts = common::scale_span_by_pct(
            second_update_assets, expected_second_provider_pct,
        );

        //let error_margin: u128 = 10000;
        absorber_utils::assert_provider_received_absorbed_assets(
            absorber,
            second_provider,
            expected_second_provider_absorbed_asset_amts,
            second_provider_before_absorbed_bals,
            preview_absorbed_assets,
            error_margin,
        );

        // Check reward cumulative is updated for opus
        // Convert to Wad for fixed point operations
        let opus_reward_distribution = updated_opus_reward_distribution;
        let expected_opus_reward_increment: Wad = (*reward_amts_per_blessing.at(0)).into()
            + opus_reward_distribution.error.into();
        let expected_opus_reward_cumulative_increment: Wad = expected_opus_reward_increment / total_recipient_shares;
        let expected_opus_reward_cumulative: u128 = opus_reward_distribution.asset_amt_per_share
            + expected_opus_reward_cumulative_increment.into();
        let updated_opus_reward_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(*reward_tokens.at(0), absorber_contract::FIRST_EPOCH);
        assert(
            updated_opus_reward_distribution.asset_amt_per_share == expected_opus_reward_cumulative,
            'wrong opus reward cumulative #2',
        );

        // Second provider should receive 3 partial rounds of rewards.
        let expected_second_provider_blessings_multiplier: Ray = (expected_second_provider_pct.into() * 3_u128).into();
        absorber_utils::assert_provider_received_rewards(
            absorber,
            second_provider,
            reward_amts_per_blessing,
            second_provider_before_reward_bals,
            preview_reward_assets,
            expected_second_provider_blessings_multiplier,
            error_margin,
        );
        absorber_utils::assert_provider_reward_cumulatives_updated(absorber, second_provider, reward_tokens);

        let expected_absorption_id: u32 = 2;
        assert(
            absorber.get_provider_last_absorption(second_provider) == expected_absorption_id, 'wrong last absorption',
        );
    }

    #[test]
    fn test_shrine_killed_and_remove_pass() {
        let (
            AbsorberTestConfig {
                shrine, absorber, yangs, ..,
                }, AbsorberRewardsTestConfig {
                provider, provided_amt, ..,
            },
        ) =
            absorber_utils::absorber_with_rewards_and_first_provider(
            Option::None,
        );

        shrine_utils::recovery_mode_test_setup(shrine, yangs, common::RecoveryModeSetupType::BufferLowerBound);

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.kill();
        stop_cheat_caller_address(shrine.contract_address);

        assert(!shrine.get_live(), 'should be killed');

        // Check provider can remove
        let before_provider_yin_bal: Wad = shrine.get_yin(provider);
        start_cheat_caller_address(absorber.contract_address, provider);
        absorber.remove(Bounded::MAX);

        // Loss of precision
        let error_margin: Wad = 1000_u128.into();
        common::assert_equalish(
            shrine.get_yin(provider),
            before_provider_yin_bal + provided_amt - absorber_contract::INITIAL_SHARES.into(),
            error_margin,
            'wrong yin amount',
        );
    }

    #[test]
    #[should_panic(expected: 'ABS: Recovery Mode active')]
    fn test_remove_exceeds_limit_fail() {
        let classes = absorber_utils::declare_contracts();
        let (AbsorberTestConfig { shrine, absorber, yangs, .. }, AbsorberRewardsTestConfig { provider, .. }) =
            absorber_utils::absorber_with_rewards_and_first_provider(
            Option::Some(classes),
        );

        // Change ETH price to make Shrine's LTV to threshold above the limit
        let eth_addr: ContractAddress = *yangs.at(0);
        let (eth_yang_price, _, _) = shrine.get_current_yang_price(eth_addr);
        let new_eth_yang_price: Wad = (eth_yang_price.into() / 5_u128).into(); // 80% drop in price
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.advance(eth_addr, new_eth_yang_price);
        stop_cheat_caller_address(shrine.contract_address);
        assert(shrine.is_recovery_mode(), 'sanity check for RM threshold');

        start_cheat_caller_address(absorber.contract_address, provider);
        absorber.remove(Bounded::MAX);
    }

    #[test]
    #[should_panic(expected: 'ABS: Not a provider')]
    fn test_non_provider_remove_fail() {
        let AbsorberTestConfig { absorber, .. } = absorber_utils::absorber_deploy(Option::None);

        start_cheat_caller_address(absorber.contract_address, common::BAD_GUY);
        absorber.remove(0_u128.into());
    }

    #[test]
    #[should_panic(expected: 'ABS: Not a provider')]
    fn test_non_provider_reap_fail() {
        let AbsorberTestConfig { absorber, .. } = absorber_utils::absorber_deploy(Option::None);

        start_cheat_caller_address(absorber.contract_address, common::BAD_GUY);
        absorber.reap();
    }

    #[test]
    #[should_panic(expected: 'ABS: provision < minimum')]
    fn test_provide_less_than_initial_shares_fail() {
        let AbsorberTestConfig {
            shrine, abbot, absorber, yangs, gates, ..,
        } = absorber_utils::absorber_deploy(Option::None);

        let provider = absorber_utils::PROVIDER_1;
        let less_than_initial_shares_amt: Wad = (absorber_contract::INITIAL_SHARES - 1).into();
        absorber_utils::provide_to_absorber(
            shrine,
            abbot,
            absorber,
            provider,
            yangs,
            absorber_utils::provider_asset_amts(),
            gates,
            less_than_initial_shares_amt,
        );
    }

    #[test]
    #[should_panic(expected: 'SH: Insufficient yin balance')]
    fn test_provide_insufficient_yin_fail() {
        let AbsorberTestConfig {
            shrine, abbot, absorber, yangs, gates, ..,
        } = absorber_utils::absorber_deploy(Option::None);

        let provider = absorber_utils::PROVIDER_1;
        let provided_amt: Wad = (10000 * WAD_ONE).into();

        let yang_asset_amts: Span<u128> = absorber_utils::provider_asset_amts();
        common::fund_user(provider, yangs, yang_asset_amts);
        common::open_trove_helper(abbot, provider, yangs, yang_asset_amts, gates, provided_amt);

        start_cheat_caller_address(shrine.contract_address, provider);
        let yin = shrine_utils::yin(shrine.contract_address);
        yin.approve(absorber.contract_address, Bounded::MAX);
        stop_cheat_caller_address(shrine.contract_address);

        start_cheat_caller_address(absorber.contract_address, provider);
        let insufficient_amt: Wad = provided_amt + 1_u128.into();
        absorber.provide(insufficient_amt);
    }

    #[test]
    #[should_panic(expected: 'SH: Insufficient yin allowance')]
    fn test_provide_insufficient_allowance_fail() {
        let AbsorberTestConfig { abbot, absorber, yangs, gates, .. } = absorber_utils::absorber_deploy(Option::None);

        let provider = absorber_utils::PROVIDER_1;
        let provided_amt: Wad = (10000 * WAD_ONE).into();

        let yang_asset_amts: Span<u128> = absorber_utils::provider_asset_amts();
        common::fund_user(provider, yangs, yang_asset_amts);
        common::open_trove_helper(abbot, provider, yangs, yang_asset_amts, gates, provided_amt);

        start_cheat_caller_address(absorber.contract_address, provider);
        absorber.provide(provided_amt);
    }

    //
    // Tests - Bestow
    //

    #[test]
    fn test_bestow_inactive_reward() {
        let classes = absorber_utils::declare_contracts();

        let (AbsorberTestConfig { absorber, .. }, AbsorberRewardsTestConfig { reward_tokens, blessers, provider, .. }) =
            absorber_utils::absorber_with_rewards_and_first_provider(
            Option::Some(classes),
        );

        let mut spy = spy_events();

        let expected_epoch: u32 = absorber_contract::FIRST_EPOCH;
        let opus_addr: ContractAddress = *reward_tokens.at(0);
        let opus_blesser_addr: ContractAddress = *blessers.at(0);
        let veopus_addr: ContractAddress = *reward_tokens.at(1);
        let veopus_blesser_addr: ContractAddress = *blessers.at(1);

        let before_opus_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(opus_addr, expected_epoch);
        let before_veopus_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(veopus_addr, expected_epoch);

        // Set veopus to inactive
        start_cheat_caller_address(absorber.contract_address, absorber_utils::ADMIN);
        absorber.set_reward(veopus_addr, veopus_blesser_addr, false);

        // Trigger rewards
        start_cheat_caller_address(absorber.contract_address, provider);
        absorber.reap();

        let after_opus_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(opus_addr, expected_epoch);
        assert(
            after_opus_distribution.asset_amt_per_share > before_opus_distribution.asset_amt_per_share,
            'cumulative should increase',
        );

        let after_veopus_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(veopus_addr, expected_epoch);
        assert(
            after_veopus_distribution.asset_amt_per_share == before_veopus_distribution.asset_amt_per_share,
            'cumulative should not increase',
        );

        let total_recipient_shares: Wad = absorber.get_total_shares_for_current_epoch()
            - absorber_contract::INITIAL_SHARES.into();
        let expected_events = array![
            (
                absorber.contract_address,
                absorber_contract::Event::Bestow(
                    absorber_contract::Bestow {
                        assets: array![AssetBalance { address: opus_addr, amount: absorber_utils::OPUS_BLESS_AMT }]
                            .span(),
                        total_recipient_shares,
                        epoch: expected_epoch,
                    },
                ),
            ),
        ];

        spy.assert_emitted(@expected_events);

        // Set OPUS to inactive
        start_cheat_caller_address(absorber.contract_address, absorber_utils::ADMIN);
        absorber.set_reward(opus_addr, opus_blesser_addr, false);

        // Trigger rewards
        start_cheat_caller_address(absorber.contract_address, provider);
        absorber.reap();

        let final_opus_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(opus_addr, expected_epoch);
        assert(
            final_opus_distribution.asset_amt_per_share == after_opus_distribution.asset_amt_per_share,
            'cumulative should not increase',
        );

        let final_veopus_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(veopus_addr, expected_epoch);
        assert(
            final_veopus_distribution.asset_amt_per_share == after_veopus_distribution.asset_amt_per_share,
            'cumulative should not increase',
        );
    }

    #[test]
    fn test_bestow_depleted_active_reward() {
        let classes = absorber_utils::declare_contracts();
        let AbsorberTestConfig {
            shrine, abbot, absorber, yangs, gates, ..,
        } = absorber_utils::absorber_deploy(Option::Some(classes));
        let mut spy = spy_events();

        let reward_tokens: Span<ContractAddress> = absorber_utils::reward_tokens_deploy(classes.token);

        let opus_addr: ContractAddress = *reward_tokens.at(0);
        let veopus_addr: ContractAddress = *reward_tokens.at(1);

        // Manually deploy blesser to control minting of reward tokens to blesser
        // so that opus blesser has no tokens
        let opus_blesser_addr: ContractAddress = absorber_utils::deploy_blesser_for_reward(
            absorber, opus_addr, absorber_utils::OPUS_BLESS_AMT, false, classes.blesser,
        );
        let veopus_blesser_addr: ContractAddress = absorber_utils::deploy_blesser_for_reward(
            absorber, veopus_addr, absorber_utils::veOPUS_BLESS_AMT, true, classes.blesser,
        );

        let mut blessers: Array<ContractAddress> = array![opus_blesser_addr, veopus_blesser_addr];

        absorber_utils::add_rewards_to_absorber(absorber, reward_tokens, blessers.span());

        let provider = absorber_utils::PROVIDER_1;
        let provided_amt: Wad = (10000 * WAD_ONE).into();
        absorber_utils::provide_to_absorber(
            shrine, abbot, absorber, provider, yangs, absorber_utils::provider_asset_amts(), gates, provided_amt,
        );

        let expected_epoch: u32 = absorber_contract::FIRST_EPOCH;
        let before_opus_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(opus_addr, expected_epoch);
        let before_veopus_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(veopus_addr, expected_epoch);

        // Trigger rewards
        start_cheat_caller_address(absorber.contract_address, provider);
        absorber.reap();

        let after_opus_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(opus_addr, expected_epoch);
        assert(
            after_opus_distribution.asset_amt_per_share == before_opus_distribution.asset_amt_per_share,
            'cumulative should not increase',
        );

        let after_veopus_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(veopus_addr, expected_epoch);
        assert(
            after_veopus_distribution.asset_amt_per_share > before_veopus_distribution.asset_amt_per_share,
            'cumulative should increase',
        );

        let total_recipient_shares: Wad = absorber.get_total_shares_for_current_epoch()
            - absorber_contract::INITIAL_SHARES.into();
        let expected_events = array![
            (
                absorber.contract_address,
                absorber_contract::Event::Bestow(
                    absorber_contract::Bestow {
                        assets: array![AssetBalance { address: veopus_addr, amount: absorber_utils::veOPUS_BLESS_AMT }]
                            .span(),
                        total_recipient_shares,
                        epoch: expected_epoch,
                    },
                ),
            ),
        ];

        spy.assert_emitted(@expected_events);
    }
}
