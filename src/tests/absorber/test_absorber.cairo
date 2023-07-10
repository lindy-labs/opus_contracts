#[cfg(test)]
mod TestAbsorber {
    use array::{ArrayTrait, SpanTrait};
    use cmp::min;
    use integer::{BoundedU128, BoundedU256};
    use option::OptionTrait;
    use starknet::{
        ContractAddress, contract_address_try_from_felt252, get_block_timestamp, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};
    use traits::{Default, Into};
    use zeroable::Zeroable;

    use aura::core::absorber::Absorber;
    use aura::core::roles::AbsorberRoles;

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IAbsorber::{
        IAbsorberDispatcher, IAbsorberDispatcherTrait, IBlesserDispatcher, IBlesserDispatcherTrait
    };
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::types::{DistributionInfo, Provision, Request, Reward};
    use aura::utils::wadray;
    use aura::utils::wadray::{
        Ray, RAY_ONE, RAY_PERCENT, RAY_SCALE, Wad, WadZeroable, WAD_ONE, WAD_SCALE
    };

    use aura::tests::absorber::utils::AbsorberUtils;
    use aura::tests::common;
    use aura::tests::shrine::utils::ShrineUtils;

    use debug::PrintTrait;

    //
    // Tests - Setup
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_absorber_setup() {
        let (_, _, _, absorber, _, _) = AbsorberUtils::absorber_deploy();

        assert(
            absorber.get_total_shares_for_current_epoch() == WadZeroable::zero(),
            'total shares should be 0'
        );
        assert(absorber.get_current_epoch() == 0, 'epoch should be 0');
        assert(absorber.get_absorptions_count() == 0, 'absorptions count should be 0');
        assert(absorber.get_rewards_count() == 0, 'rewards should be 0');
        assert(absorber.get_removal_limit() == AbsorberUtils::REMOVAL_LIMIT.into(), 'wrong limit');
        assert(absorber.get_live(), 'should be live');

        let absorber_ac = IAccessControlDispatcher { contract_address: absorber.contract_address };
        assert(
            absorber_ac.get_roles(AbsorberUtils::admin()) == AbsorberRoles::default_admin_role(),
            'wrong role for admin'
        );
    }

    //
    // Tests - Setters
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_set_removal_limit_pass() {
        let (_, _, _, absorber, _, _) = AbsorberUtils::absorber_deploy();

        set_contract_address(AbsorberUtils::admin());

        let new_limit: Ray = (75 * RAY_PERCENT).into();
        absorber.set_removal_limit(new_limit);

        assert(absorber.get_removal_limit() == new_limit, 'limit not updated');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Limit is too low', 'ENTRYPOINT_FAILED'))]
    fn test_set_removal_limit_too_low_fail() {
        let (_, _, _, absorber, _, _) = AbsorberUtils::absorber_deploy();

        set_contract_address(AbsorberUtils::admin());

        let invalid_limit: Ray = (Absorber::MIN_LIMIT - 1).into();
        absorber.set_removal_limit(invalid_limit);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_removal_limit_unauthorized_fail() {
        let (_, _, _, absorber, _, _) = AbsorberUtils::absorber_deploy();

        set_contract_address(common::badguy());

        let new_limit: Ray = (75 * RAY_PERCENT).into();
        absorber.set_removal_limit(new_limit);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_reward_pass() {
        let (_, _, _, absorber, _, _) = AbsorberUtils::absorber_deploy();

        let aura_token: ContractAddress = AbsorberUtils::aura_token_deploy();
        let aura_blesser: ContractAddress = AbsorberUtils::deploy_blesser_for_reward(
            absorber, aura_token, AbsorberUtils::AURA_BLESS_AMT, true
        );

        let veaura_token: ContractAddress = AbsorberUtils::veaura_token_deploy();
        let veaura_blesser: ContractAddress = AbsorberUtils::deploy_blesser_for_reward(
            absorber, veaura_token, AbsorberUtils::VEAURA_BLESS_AMT, true
        );

        set_contract_address(AbsorberUtils::admin());
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
        expected_rewards.append(veaura_reward);

        assert(absorber.get_rewards() == expected_rewards.span(), 'rewards not equal');

        // Update existing reward
        let new_aura_blesser: ContractAddress = contract_address_try_from_felt252(
            'new aura blesser'
        )
            .unwrap();
        aura_reward.is_active = false;
        aura_reward.blesser = IBlesserDispatcher { contract_address: new_aura_blesser };
        absorber.set_reward(aura_token, new_aura_blesser, false);

        let mut expected_rewards: Array<Reward> = Default::default();
        expected_rewards.append(aura_reward);
        expected_rewards.append(veaura_reward);

        assert(absorber.get_rewards() == expected_rewards.span(), 'rewards not equal');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Address cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_set_reward_blesser_zero_address_fail() {
        let (_, _, _, absorber, _, _) = AbsorberUtils::absorber_deploy();

        let valid_address = common::non_zero_address();
        let invalid_address = ContractAddressZeroable::zero();

        set_contract_address(AbsorberUtils::admin());
        absorber.set_reward(valid_address, invalid_address, true);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Address cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_set_reward_token_zero_address_fail() {
        let (_, _, _, absorber, _, _) = AbsorberUtils::absorber_deploy();

        let valid_address = common::non_zero_address();
        let invalid_address = ContractAddressZeroable::zero();

        set_contract_address(AbsorberUtils::admin());
        absorber.set_reward(invalid_address, valid_address, true);
    }

    //
    // Tests - Kill
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_kill_and_remove_pass() {
        let (shrine, _, absorber, _, _, _, _, _, provider, provided_amt) =
            AbsorberUtils::absorber_with_rewards_and_first_provider();

        set_contract_address(AbsorberUtils::admin());
        absorber.kill();

        assert(!absorber.get_live(), 'should be killed');

        // Check provider can remove
        let before_provider_yin_bal: Wad = shrine.get_yin(provider);
        set_contract_address(provider);
        absorber.request();
        set_block_timestamp(get_block_timestamp() + Absorber::REQUEST_BASE_TIMELOCK);
        absorber.remove(BoundedU128::max().into());

        // Loss of precision
        let error_margin: Wad = 1000_u128.into();
        common::assert_equalish(
            shrine.get_yin(provider),
            before_provider_yin_bal + provided_amt,
            error_margin,
            'wrong yin amount'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_kill_unauthorized_fail() {
        let (_, _, _, absorber, _, _) = AbsorberUtils::absorber_deploy();

        set_contract_address(common::badguy());
        absorber.kill();
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Not live', 'ENTRYPOINT_FAILED'))]
    fn test_provide_after_kill_fail() {
        let (shrine, _, _, absorber, _, _) = AbsorberUtils::absorber_deploy();

        set_contract_address(AbsorberUtils::admin());
        absorber.kill();
        absorber.provide(1_u128.into());
    }

    //
    // Tests - Update
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_update_and_subsequent_provider_action() {
        // Parametrization so that the second provider action is performed 
        // for each percentage
        let mut percentages_to_drain: Array<Ray> = Default::default();
        percentages_to_drain.append(21745231600000000000000000_u128.into()); // 2.17452316% (Ray)
        percentages_to_drain.append(439210000000000000000000000_u128.into()); // 43.291% (Ray)
        percentages_to_drain.append(RAY_ONE.into()); // 100% (Ray)

        percentages_to_drain.append(RAY_ONE.into()); // 100% (Ray) 
        percentages_to_drain.append(21745231600000000000000000_u128.into()); // 2.17452316% (Ray)
        percentages_to_drain.append(439210000000000000000000000_u128.into()); // 43.291% (Ray)

        percentages_to_drain.append(439210000000000000000000000_u128.into()); // 43.291% (Ray)
        percentages_to_drain.append(RAY_ONE.into()); // 100% (Ray)
        percentages_to_drain.append(21745231600000000000000000_u128.into()); // 2.17452316% (Ray)

        let mut percentages_to_drain = percentages_to_drain.span();

        loop {
            match percentages_to_drain.pop_front() {
                Option::Some(percentage_to_drain) => {
                    let (
                        shrine,
                        abbot,
                        absorber,
                        yangs,
                        gates,
                        reward_tokens,
                        _,
                        reward_amts_per_blessing,
                        provider,
                        first_provided_amt
                    ) =
                        AbsorberUtils::absorber_with_rewards_and_first_provider();

                    // Simulate absorption
                    let first_update_assets: Span<u128> = AbsorberUtils::first_update_assets();
                    AbsorberUtils::simulate_update_with_pct_to_drain(
                        shrine, absorber, yangs, first_update_assets, *percentage_to_drain
                    );

                    let is_fully_absorbed = *percentage_to_drain == RAY_SCALE.into();

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
                    AbsorberUtils::assert_update_is_correct(
                        absorber,
                        expected_absorption_id,
                        before_total_shares,
                        yangs,
                        first_update_assets,
                    );

                    let expected_blessings_multiplier: Ray = RAY_SCALE.into();
                    let absorption_epoch = 0;
                    AbsorberUtils::assert_reward_cumulative_updated(
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

                    let before_absorbed_bals = common::get_token_balances(yangs, provider.into());
                    let before_reward_bals = common::get_token_balances(
                        reward_tokens, provider.into()
                    );
                    let before_last_absorption = absorber.get_provider_last_absorption(provider);
                    let before_provider_yin_bal: Wad = shrine.get_yin(provider);

                    // Perform three different actions 
                    // (in the following order if the number of test cases is a multiple of 3):
                    // 1. `provide`
                    // 2. `request` and `remove`
                    // 3. `reap`
                    // and check that the provider receives rewards and absorbed assets

                    let (_, preview_absorbed_amts, _, preview_reward_amts) = absorber
                        .preview_reap(provider);

                    let mut remove_as_second_action: bool = false;
                    let mut provide_as_second_action: bool = false;
                    set_contract_address(provider);
                    if percentages_to_drain.len() % 3 == 2 {
                        absorber.provide(WAD_SCALE.into());
                        provide_as_second_action = true;
                    } else if percentages_to_drain.len() % 3 == 1 {
                        absorber.request();
                        set_block_timestamp(
                            get_block_timestamp() + Absorber::REQUEST_BASE_TIMELOCK
                        );
                        absorber.remove(BoundedU128::max().into());
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
                    // Custom error margin is used due to loss of precision and initial minimum shares
                    let error_margin: Wad = 500_u128.into();

                    AbsorberUtils::assert_provider_received_absorbed_assets(
                        absorber,
                        provider,
                        yangs,
                        first_update_assets,
                        before_absorbed_bals,
                        preview_absorbed_amts,
                        error_margin,
                    );

                    AbsorberUtils::assert_provider_received_rewards(
                        absorber,
                        provider,
                        reward_tokens,
                        reward_amts_per_blessing,
                        before_reward_bals,
                        preview_reward_amts,
                        expected_blessings_multiplier,
                        error_margin,
                    );
                    AbsorberUtils::assert_provider_reward_cumulatives_updated(
                        absorber, provider, reward_tokens
                    );

                    let (_, _, _, after_preview_reward_amts) = absorber.preview_reap(provider);
                    if is_fully_absorbed {
                        if provide_as_second_action {
                            // Updated preview amount should increase because of addition of error
                            // from previous redistribution
                            assert(
                                *after_preview_reward_amts.at(0) > *preview_reward_amts.at(0),
                                'preview amount should decrease'
                            );
                        } else {
                            assert(
                                after_preview_reward_amts.len().is_zero(), 'should not have rewards'
                            );
                            AbsorberUtils::assert_reward_errors_propagated_to_next_epoch(
                                absorber, expected_epoch - 1, reward_tokens
                            );
                        }
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
                        let expected_removed_amt: Wad = wadray::rmul_wr(
                            first_provided_amt, (RAY_SCALE.into() - *percentage_to_drain)
                        );
                        let error_margin: Wad = 1000_u128.into();
                        common::assert_equalish(
                            shrine.get_yin(provider),
                            before_provider_yin_bal + expected_removed_amt,
                            error_margin,
                            'wrong provider yin balance'
                        );
                        common::assert_equalish(
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
        let (_, _, absorber, yangs, _, _, _, _, _, _) =
            AbsorberUtils::absorber_with_rewards_and_first_provider();

        set_contract_address(common::badguy());
        let first_update_assets: Span<u128> = AbsorberUtils::first_update_assets();
        absorber.update(yangs, first_update_assets);
    }

    //
    // Tests - Provider functions (provide, request, remove, reap)
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_provide_first_epoch() {
        let (
            shrine,
            abbot,
            absorber,
            yangs,
            gates,
            reward_tokens,
            _,
            reward_amts_per_blessing,
            provider,
            first_provided_amt
        ) =
            AbsorberUtils::absorber_with_rewards_and_first_provider();
        let yin = IERC20Dispatcher { contract_address: shrine.contract_address };

        let before_provider_info: Provision = absorber.get_provision(provider);
        let before_last_absorption_id: u32 = absorber.get_provider_last_absorption(provider);
        let before_total_shares: Wad = absorber.get_total_shares_for_current_epoch();
        let before_absorber_yin_bal: u256 = yin.balance_of(absorber.contract_address);

        let before_reward_bals: Span<Span<u128>> = common::get_token_balances(
            reward_tokens, provider.into()
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
        let second_provided_amt: Wad = (400 * WAD_ONE).into();
        AbsorberUtils::provide_to_absorber(
            shrine,
            abbot,
            absorber,
            provider,
            yangs,
            AbsorberUtils::provider_asset_amts(),
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
        AbsorberUtils::assert_reward_cumulative_updated(
            absorber,
            before_total_shares,
            expected_epoch,
            reward_tokens,
            reward_amts_per_blessing,
            expected_blessings_multiplier
        );

        // Check rewards
        let error_margin: Wad = 1000_u128.into();
        AbsorberUtils::assert_provider_received_rewards(
            absorber,
            provider,
            reward_tokens,
            reward_amts_per_blessing,
            before_reward_bals,
            preview_reward_amts,
            expected_blessings_multiplier,
            error_margin,
        );
        AbsorberUtils::assert_provider_reward_cumulatives_updated(
            absorber, provider, reward_tokens
        );
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
        let (
            shrine,
            abbot,
            absorber,
            yangs,
            gates,
            reward_tokens,
            _,
            reward_amts_per_blessing,
            first_provider,
            first_provided_amt
        ) =
            AbsorberUtils::absorber_with_rewards_and_first_provider();

        let first_epoch_total_shares: Wad = absorber.get_total_shares_for_current_epoch();

        // Step 2
        let first_update_assets: Span<u128> = AbsorberUtils::first_update_assets();
        AbsorberUtils::simulate_update_with_pct_to_drain(
            shrine, absorber, yangs, first_update_assets, RAY_SCALE.into()
        );

        // Second epoch starts here
        // Step 3
        let second_provider = AbsorberUtils::provider_2();
        let second_provided_amt: Wad = (5000 * WAD_ONE).into();
        AbsorberUtils::provide_to_absorber(
            shrine,
            abbot,
            absorber,
            second_provider,
            yangs,
            AbsorberUtils::provider_asset_amts(),
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
        let second_update_assets: Span<u128> = AbsorberUtils::second_update_assets();
        AbsorberUtils::simulate_update_with_pct_to_drain(
            shrine, absorber, yangs, second_update_assets, RAY_SCALE.into()
        );

        // Step 5
        let first_provider_before_reward_bals = common::get_token_balances(
            reward_tokens, first_provider.into()
        );
        let first_provider_before_absorbed_bals = common::get_token_balances(
            yangs, first_provider.into()
        );

        set_contract_address(first_provider);
        let (_, preview_absorbed_amts, _, preview_reward_amts) = absorber
            .preview_reap(first_provider);

        absorber.reap();

        assert(absorber.get_provider_last_absorption(first_provider) == 2, 'wrong last absorption');

        let error_margin: Wad = 1000_u128.into();
        AbsorberUtils::assert_provider_received_absorbed_assets(
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
        AbsorberUtils::assert_reward_cumulative_updated(
            absorber,
            first_epoch_total_shares,
            expected_epoch,
            reward_tokens,
            reward_amts_per_blessing,
            expected_blessings_multiplier
        );

        // Check rewards
        AbsorberUtils::assert_provider_received_rewards(
            absorber,
            first_provider,
            reward_tokens,
            reward_amts_per_blessing,
            first_provider_before_reward_bals,
            preview_reward_amts,
            expected_blessings_multiplier,
            error_margin,
        );
        AbsorberUtils::assert_provider_reward_cumulatives_updated(
            absorber, first_provider, reward_tokens
        );

        // Step 6
        let second_provider_before_reward_bals = common::get_token_balances(
            reward_tokens, second_provider.into()
        );
        let second_provider_before_absorbed_bals = common::get_token_balances(
            yangs, second_provider.into()
        );

        set_contract_address(second_provider);
        let (_, preview_absorbed_amts, _, preview_reward_amts) = absorber
            .preview_reap(second_provider);

        absorber.reap();

        assert(
            absorber.get_provider_last_absorption(second_provider) == 2, 'wrong last absorption'
        );

        let error_margin: Wad = 1000_u128.into();
        AbsorberUtils::assert_provider_received_absorbed_assets(
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
        AbsorberUtils::assert_reward_cumulative_updated(
            absorber,
            second_epoch_total_shares,
            expected_epoch,
            reward_tokens,
            reward_amts_per_blessing,
            expected_blessings_multiplier
        );

        // Check rewards
        AbsorberUtils::assert_provider_received_rewards(
            absorber,
            second_provider,
            reward_tokens,
            reward_amts_per_blessing,
            second_provider_before_reward_bals,
            preview_reward_amts,
            expected_blessings_multiplier,
            error_margin,
        );
        AbsorberUtils::assert_provider_reward_cumulatives_updated(
            absorber, second_provider, reward_tokens
        );
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
        let (
            shrine,
            abbot,
            absorber,
            yangs,
            gates,
            reward_tokens,
            _,
            reward_amts_per_blessing,
            first_provider,
            first_provided_amt
        ) =
            AbsorberUtils::absorber_with_rewards_and_first_provider();

        let first_epoch_total_shares: Wad = absorber.get_total_shares_for_current_epoch();

        // Step 2
        let first_update_assets: Span<u128> = AbsorberUtils::first_update_assets();
        // Amount of yin remaining needs to be sufficiently significant to account for loss of precision
        // from conversion of shares across epochs, after discounting initial shares.
        let above_min_shares: Wad = Absorber::MINIMUM_SHARES.into();
        let burn_amt: Wad = first_provided_amt - above_min_shares;
        AbsorberUtils::simulate_update_with_amt_to_drain(
            shrine, absorber, yangs, first_update_assets, burn_amt
        );

        // Check epoch and total shares after threshold absorption
        let expected_epoch: u32 = 1;
        assert(absorber.get_current_epoch() == expected_epoch, 'wrong epoch');
        assert(
            absorber.get_total_shares_for_current_epoch() == above_min_shares, 'wrong total shares'
        );

        AbsorberUtils::assert_reward_errors_propagated_to_next_epoch(
            absorber, expected_epoch - 1, reward_tokens
        );

        // Second epoch starts here
        // Step 3
        let second_provider = AbsorberUtils::provider_2();
        let second_provided_amt: Wad = (5000 * WAD_ONE).into();
        AbsorberUtils::provide_to_absorber(
            shrine,
            abbot,
            absorber,
            second_provider,
            yangs,
            AbsorberUtils::provider_asset_amts(),
            gates,
            second_provided_amt
        );

        let second_provider_info: Provision = absorber.get_provision(second_provider);
        assert(second_provider_info.shares == second_provided_amt, 'wrong provider shares');
        assert(second_provider_info.epoch == 1, 'wrong provider epoch');

        let error_margin: Wad = 1000_u128.into();
        common::assert_equalish(
            absorber.preview_remove(second_provider),
            second_provided_amt,
            error_margin,
            'wrong preview remove amount'
        );

        // Step 4
        let first_provider_before_yin_bal: Wad = shrine.get_yin(first_provider);
        let first_provider_before_reward_bals = common::get_token_balances(
            reward_tokens, first_provider.into()
        );
        let first_provider_before_absorbed_bals = common::get_token_balances(
            yangs, first_provider.into()
        );

        set_contract_address(first_provider);
        let (_, preview_absorbed_amts, _, preview_reward_amts) = absorber
            .preview_reap(first_provider);

        absorber.request();
        set_block_timestamp(get_block_timestamp() + Absorber::REQUEST_BASE_TIMELOCK);
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
        AbsorberUtils::assert_provider_received_absorbed_assets(
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
        AbsorberUtils::assert_reward_cumulative_updated(
            absorber,
            first_epoch_total_shares,
            first_epoch,
            reward_tokens,
            reward_amts_per_blessing,
            expected_first_epoch_blessings_multiplier
        );

        let expected_first_provider_blessings_multiplier = (2 * RAY_SCALE).into();
        AbsorberUtils::assert_provider_received_rewards(
            absorber,
            first_provider,
            reward_tokens,
            reward_amts_per_blessing,
            first_provider_before_reward_bals,
            preview_reward_amts,
            expected_first_provider_blessings_multiplier,
            error_margin,
        );
        AbsorberUtils::assert_provider_reward_cumulatives_updated(
            absorber, first_provider, reward_tokens
        );
    }

    // Test minimum shares amount of yin remaining after absorption.
    // Sequence of events:
    // 1. Provider 1 provides
    // 2. Absorption occurs; yin per share falls below threshold, and yin amount is 
    //    exactly 1 wei greater than the minimum initial shares. 
    // 3. Provider 1 withdraws, which should be zero due to loss of precision.
    #[test]
    #[available_gas(20000000000)]
    fn test_remove_after_threshold_absorption_with_minimum_shares() {
        let (
            shrine,
            abbot,
            absorber,
            yangs,
            gates,
            reward_tokens,
            _,
            reward_amts_per_blessing,
            first_provider,
            first_provided_amt
        ) =
            AbsorberUtils::absorber_with_rewards_and_first_provider();

        let first_epoch_total_shares: Wad = absorber.get_total_shares_for_current_epoch();

        // Step 2
        let first_update_assets: Span<u128> = AbsorberUtils::first_update_assets();
        // Amount of yin remaining needs to be sufficiently significant to account for loss of precision
        // from conversion of shares across epochs, after discounting initial shares.
        let excess_above_minimum: Wad = 1_u128.into();
        let above_min_shares: Wad = Absorber::INITIAL_SHARES.into() + excess_above_minimum;
        let burn_amt: Wad = first_provided_amt - above_min_shares;
        AbsorberUtils::simulate_update_with_amt_to_drain(
            shrine, absorber, yangs, first_update_assets, burn_amt
        );

        // Check epoch and total shares after threshold absorption
        let expected_epoch: u32 = 1;
        assert(absorber.get_current_epoch() == expected_epoch, 'wrong epoch');
        assert(
            absorber.get_total_shares_for_current_epoch() == above_min_shares, 'wrong total shares'
        );

        AbsorberUtils::assert_reward_errors_propagated_to_next_epoch(
            absorber, expected_epoch - 1, reward_tokens
        );

        // Step 3
        let first_provider_before_yin_bal: Wad = shrine.get_yin(first_provider);

        set_contract_address(first_provider);
        let (_, preview_absorbed_amts, _, preview_reward_amts) = absorber
            .preview_reap(first_provider);

        // Trigger an update of the provider's Provision
        absorber.provide(WadZeroable::zero());
        let first_provider_info: Provision = absorber.get_provision(first_provider);
        assert(first_provider_info.shares == 1_u128.into(), 'wrong provider shares');
        assert(first_provider_info.epoch == 1, 'wrong provider epoch');

        absorber.request();
        set_block_timestamp(get_block_timestamp() + Absorber::REQUEST_BASE_TIMELOCK);
        absorber.remove(BoundedU128::max().into());

        // First provider should not receive any yin even though he has 1 share due to 
        // loss of precision
        assert(
            shrine.get_yin(first_provider) == first_provider_before_yin_bal, 'yin should not change'
        );

        let first_provider_info: Provision = absorber.get_provision(first_provider);
        assert(first_provider_info.shares == WadZeroable::zero(), 'wrong provider shares');
        assert(first_provider_info.epoch == 1, 'wrong provider epoch');

        let request: Request = absorber.get_provider_request(first_provider);
        assert(request.has_removed, 'request should be fulfilled');
    }

    // Sequence of events:
    // 1. Provider 1 provides
    // 2. Absorption occurs; yin per share falls below threshold, and yin amount is 
    //    below the initial shares so total shares in new epoch starts from 0. 
    //    No rewards are distributed because total shares is zeroed.
    // 3. Provider 2 provides, provider 1 receives 1 round of rewards.
    // 4. Provider 1 withdraws, both providers share 1 round of rewards.
    #[test]
    #[available_gas(20000000000)]
    fn test_provide_after_threshold_absorption_below_initial_shares() {
        let (
            shrine,
            abbot,
            absorber,
            yangs,
            gates,
            reward_tokens,
            _,
            reward_amts_per_blessing,
            first_provider,
            first_provided_amt
        ) =
            AbsorberUtils::absorber_with_rewards_and_first_provider();

        let first_epoch_total_shares: Wad = absorber.get_total_shares_for_current_epoch();

        // Step 2
        let first_update_assets: Span<u128> = AbsorberUtils::first_update_assets();
        let burn_amt: Wad = first_provided_amt - Absorber::INITIAL_SHARES.into();
        AbsorberUtils::simulate_update_with_amt_to_drain(
            shrine, absorber, yangs, first_update_assets, burn_amt
        );

        // Check epoch and total shares after threshold absorption
        let expected_epoch: u32 = 1;
        assert(absorber.get_current_epoch() == expected_epoch, 'wrong epoch');
        assert(
            absorber.get_total_shares_for_current_epoch() == WadZeroable::zero(),
            'wrong total shares #1'
        );

        AbsorberUtils::assert_reward_errors_propagated_to_next_epoch(
            absorber, expected_epoch - 1, reward_tokens
        );

        // Second epoch starts here
        // Step 3
        let second_provider = AbsorberUtils::provider_2();
        let second_provided_amt: Wad = (5000 * WAD_ONE).into();
        AbsorberUtils::provide_to_absorber(
            shrine,
            abbot,
            absorber,
            second_provider,
            yangs,
            AbsorberUtils::provider_asset_amts(),
            gates,
            second_provided_amt
        );

        let second_provider_info: Provision = absorber.get_provision(second_provider);
        assert(
            absorber.get_total_shares_for_current_epoch() == second_provided_amt,
            'wrong total shares #2'
        );
        assert(
            second_provider_info.shares == second_provided_amt - Absorber::INITIAL_SHARES.into(),
            'wrong provider shares'
        );
        assert(second_provider_info.epoch == 1, 'wrong provider epoch');

        let error_margin: Wad = 1000_u128.into(); // equal to initial minimum shares
        common::assert_equalish(
            absorber.preview_remove(second_provider),
            second_provided_amt,
            error_margin,
            'wrong preview remove amount'
        );

        // Step 4
        let first_provider_before_yin_bal: Wad = shrine.get_yin(first_provider);
        let first_provider_before_reward_bals = common::get_token_balances(
            reward_tokens, first_provider.into()
        );
        let first_provider_before_absorbed_bals = common::get_token_balances(
            yangs, first_provider.into()
        );

        set_contract_address(first_provider);
        let (_, preview_absorbed_amts, _, preview_reward_amts) = absorber
            .preview_reap(first_provider);

        absorber.request();
        set_block_timestamp(get_block_timestamp() + Absorber::REQUEST_BASE_TIMELOCK);
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
        AbsorberUtils::assert_provider_received_absorbed_assets(
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
        AbsorberUtils::assert_reward_cumulative_updated(
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
        AbsorberUtils::assert_provider_received_rewards(
            absorber,
            first_provider,
            reward_tokens,
            reward_amts_per_blessing,
            first_provider_before_reward_bals,
            preview_reward_amts,
            expected_first_provider_blessings_multiplier,
            error_margin,
        );
        AbsorberUtils::assert_provider_reward_cumulatives_updated(
            absorber, first_provider, reward_tokens
        );
    }

    // Test amount of yin remaining after absorption is above initial shares but below 
    // minimum shares
    // Sequence of events:
    // 1. Provider 1 provides
    // 2. Absorption occurs; yin per share falls below threshold, and yin amount is 
    //    above initial shares but below minimum shares
    // 3. Provider 1 withdraws, no rewards should be distributed.
    #[test]
    #[available_gas(20000000000)]
    fn test_after_threshold_absorption_between_initial_and_minimum_shares() {
        let mut remaining_yin_amts: Array<Wad> = Default::default();
        // lower bound for remaining yin without total shares being zeroed
        remaining_yin_amts.append((Absorber::INITIAL_SHARES + 1).into());
        // upper bound for remaining yin before rewards are distributed
        remaining_yin_amts.append((Absorber::MINIMUM_SHARES - 1).into());
        let mut remaining_yin_amts = remaining_yin_amts.span();

        loop {
            match remaining_yin_amts.pop_front() {
                Option::Some(remaining_yin_amt) => {
                    let (
                        shrine,
                        abbot,
                        absorber,
                        yangs,
                        gates,
                        reward_tokens,
                        _,
                        reward_amts_per_blessing,
                        first_provider,
                        first_provided_amt
                    ) =
                        AbsorberUtils::absorber_with_rewards_and_first_provider();

                    let first_epoch_total_shares: Wad = absorber
                        .get_total_shares_for_current_epoch();

                    // Step 2
                    let first_update_assets: Span<u128> = AbsorberUtils::first_update_assets();
                    let burn_amt: Wad = first_provided_amt - *remaining_yin_amt;
                    AbsorberUtils::simulate_update_with_amt_to_drain(
                        shrine, absorber, yangs, first_update_assets, burn_amt
                    );

                    // Check epoch and total shares after threshold absorption
                    let expected_epoch: u32 = 1;
                    assert(absorber.get_current_epoch() == expected_epoch, 'wrong epoch');
                    // New total shares should be equivalent to remaining yin in Absorber
                    assert(
                        absorber.get_total_shares_for_current_epoch() == *remaining_yin_amt,
                        'wrong total shares'
                    );

                    AbsorberUtils::assert_reward_errors_propagated_to_next_epoch(
                        absorber, expected_epoch - 1, reward_tokens
                    );

                    // Step 3
                    let first_provider_before_reward_bals = common::get_token_balances(
                        reward_tokens, first_provider.into()
                    );

                    set_contract_address(first_provider);
                    let (_, _, _, preview_reward_amts) = absorber.preview_reap(first_provider);

                    // Trigger an update of the provider's Provision
                    absorber.provide(WadZeroable::zero());
                    let first_provider_info: Provision = absorber.get_provision(first_provider);
                    let expected_provider_shares: Wad = *remaining_yin_amt
                        - Absorber::INITIAL_SHARES.into();
                    assert(
                        first_provider_info.shares == expected_provider_shares,
                        'wrong provider shares'
                    );
                    assert(first_provider_info.epoch == 1, 'wrong provider epoch');

                    let expected_first_provider_blessings_multiplier = RAY_SCALE.into();
                    let error_margin: Wad = 1000_u128.into();
                    AbsorberUtils::assert_provider_received_rewards(
                        absorber,
                        first_provider,
                        reward_tokens,
                        reward_amts_per_blessing,
                        first_provider_before_reward_bals,
                        preview_reward_amts,
                        expected_first_provider_blessings_multiplier,
                        error_margin,
                    );

                    let (_, _, _, mut preview_reward_amts) = absorber.preview_reap(first_provider);
                    loop {
                        match preview_reward_amts.pop_front() {
                            Option::Some(reward_amt) => {
                                assert((*reward_amt).is_zero(), 'expected rewards should be 0');
                            },
                            Option::None(_) => {
                                break;
                            }
                        };
                    };
                },
                Option::None(_) => {
                    break;
                }
            };
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
    #[available_gas(20000000000)]
    fn test_multi_user_reap_same_epoch_multi_absorptions() {
        let (
            shrine,
            abbot,
            absorber,
            yangs,
            gates,
            reward_tokens,
            _,
            reward_amts_per_blessing,
            first_provider,
            first_provided_amt
        ) =
            AbsorberUtils::absorber_with_rewards_and_first_provider();

        let first_epoch_total_shares: Wad = absorber.get_total_shares_for_current_epoch();

        // Step 2
        let first_update_assets: Span<u128> = AbsorberUtils::first_update_assets();
        let burn_pct: Ray = 266700000000000000000000000_u128.into(); // 26.67% (Ray)
        AbsorberUtils::simulate_update_with_pct_to_drain(
            shrine, absorber, yangs, first_update_assets, burn_pct
        );

        let remaining_absorber_yin: Wad = shrine.get_yin(absorber.contract_address);
        let expected_yin_per_share: Ray = wadray::rdiv_ww(
            remaining_absorber_yin, first_provided_amt
        );

        // Step 3
        let second_provider = AbsorberUtils::provider_2();
        let second_provided_amt: Wad = (5000 * WAD_ONE).into();
        AbsorberUtils::provide_to_absorber(
            shrine,
            abbot,
            absorber,
            second_provider,
            yangs,
            AbsorberUtils::provider_asset_amts(),
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
        common::assert_equalish(
            absorber.preview_remove(second_provider),
            second_provided_amt,
            error_margin,
            'wrong preview remove amount'
        );

        // Check that second provider's reward cumulatives are updated
        AbsorberUtils::assert_provider_reward_cumulatives_updated(
            absorber, second_provider, reward_tokens
        );

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
        let second_update_assets: Span<u128> = AbsorberUtils::second_update_assets();
        let burn_pct: Ray = 512390000000000000000000000_u128.into(); // 51.239% (Ray)
        AbsorberUtils::simulate_update_with_pct_to_drain(
            shrine, absorber, yangs, second_update_assets, burn_pct
        );

        // Step 5
        let first_provider_before_yin_bal: Wad = shrine.get_yin(first_provider);
        let first_provider_before_reward_bals = common::get_token_balances(
            reward_tokens, first_provider.into()
        );
        let first_provider_before_absorbed_bals = common::get_token_balances(
            yangs, first_provider.into()
        );

        set_contract_address(first_provider);
        let (_, preview_absorbed_amts, _, preview_reward_amts) = absorber
            .preview_reap(first_provider);

        absorber.reap();

        // Derive the amount of absorbed assets the first provider is expected to receive
        let expected_first_provider_absorbed_asset_amts = common::combine_spans(
            first_update_assets,
            common::scale_span_by_pct(second_update_assets, expected_first_provider_pct)
        );

        let error_margin: Wad = 10000_u128.into();
        AbsorberUtils::assert_provider_received_absorbed_assets(
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
            / (total_shares - Absorber::INITIAL_SHARES.into());
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
        AbsorberUtils::assert_provider_received_rewards(
            absorber,
            first_provider,
            reward_tokens,
            reward_amts_per_blessing,
            first_provider_before_reward_bals,
            preview_reward_amts,
            expected_first_provider_blessings_multiplier,
            error_margin,
        );
        AbsorberUtils::assert_provider_reward_cumulatives_updated(
            absorber, first_provider, reward_tokens
        );

        let expected_absorption_id: u32 = 2;
        assert(
            absorber.get_provider_last_absorption(first_provider) == expected_absorption_id,
            'wrong last absorption'
        );

        // Step 6
        let second_provider_before_yin_bal: Wad = shrine.get_yin(second_provider);
        let second_provider_before_reward_bals = common::get_token_balances(
            reward_tokens, second_provider.into()
        );
        let second_provider_before_absorbed_bals = common::get_token_balances(
            yangs, second_provider.into()
        );

        set_contract_address(second_provider);
        let (_, preview_absorbed_amts, _, preview_reward_amts) = absorber
            .preview_reap(second_provider);

        absorber.reap();

        // Derive the amount of absorbed assets the second provider is expected to receive
        let expected_second_provider_absorbed_asset_amts = common::scale_span_by_pct(
            second_update_assets, expected_second_provider_pct
        );

        let error_margin: Wad = 10000_u128.into();
        AbsorberUtils::assert_provider_received_absorbed_assets(
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
        let expected_aura_reward_increment: Wad = (*reward_amts_per_blessing.at(0)).into()
            + aura_reward_distribution.error.into();
        let expected_aura_reward_cumulative_increment: Wad = expected_aura_reward_increment
            / (total_shares - Absorber::INITIAL_SHARES.into());
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
        AbsorberUtils::assert_provider_received_rewards(
            absorber,
            second_provider,
            reward_tokens,
            reward_amts_per_blessing,
            second_provider_before_reward_bals,
            preview_reward_amts,
            expected_second_provider_blessings_multiplier,
            error_margin,
        );
        AbsorberUtils::assert_provider_reward_cumulatives_updated(
            absorber, second_provider, reward_tokens
        );

        let expected_absorption_id: u32 = 2;
        assert(
            absorber.get_provider_last_absorption(second_provider) == expected_absorption_id,
            'wrong last absorption'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_request_pass() {
        let (_, _, absorber, _, _, _, _, _, provider, _) =
            AbsorberUtils::absorber_with_rewards_and_first_provider();

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
        let (shrine, _, absorber, yangs, _, _, _, _, provider, provided_amt) =
            AbsorberUtils::absorber_with_rewards_and_first_provider();

        // Change ETH price to make Shrine's LTV to threshold above the limit
        let eth_addr: ContractAddress = *yangs.at(0);
        let (eth_yang_price, _, _) = shrine.get_current_yang_price(eth_addr);
        let new_eth_yang_price: Wad = (eth_yang_price.val / 5).into(); // 80% drop in price
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
        set_block_timestamp(get_block_timestamp() + Absorber::REQUEST_BASE_TIMELOCK);
        absorber.remove(BoundedU128::max().into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: No request found', 'ENTRYPOINT_FAILED'))]
    fn test_remove_no_request_fail() {
        let (_, _, absorber, _, _, _, _, _, provider, _) =
            AbsorberUtils::absorber_with_rewards_and_first_provider();

        set_contract_address(provider);
        absorber.remove(BoundedU128::max().into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Only 1 removal per request', 'ENTRYPOINT_FAILED'))]
    fn test_remove_fulfilled_request_fail() {
        let (_, _, absorber, _, _, _, _, _, provider, _) =
            AbsorberUtils::absorber_with_rewards_and_first_provider();

        set_contract_address(provider);
        absorber.request();
        set_block_timestamp(get_block_timestamp() + Absorber::REQUEST_BASE_TIMELOCK);
        // This should succeed
        absorber.remove(1_u128.into());

        // This should fail
        absorber.remove(1_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Request is not valid yet', 'ENTRYPOINT_FAILED'))]
    fn test_remove_request_not_valid_yet_fail() {
        let (_, _, absorber, _, _, _, _, _, provider, _) =
            AbsorberUtils::absorber_with_rewards_and_first_provider();

        set_contract_address(provider);
        absorber.request();
        // Early by 1 second
        set_block_timestamp(get_block_timestamp() + Absorber::REQUEST_BASE_TIMELOCK - 1);
        absorber.remove(1_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Request has expired', 'ENTRYPOINT_FAILED'))]
    fn test_remove_request_expired_fail() {
        let (_, _, absorber, _, _, _, _, _, provider, _) =
            AbsorberUtils::absorber_with_rewards_and_first_provider();

        set_contract_address(provider);
        absorber.request();
        // 1 second after validity period
        set_block_timestamp(
            get_block_timestamp()
                + Absorber::REQUEST_BASE_TIMELOCK
                + Absorber::REQUEST_VALIDITY_PERIOD
                + 1
        );
        absorber.remove(1_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Not a provider', 'ENTRYPOINT_FAILED'))]
    fn test_non_provider_request_fail() {
        let (_, _, _, absorber, _, _) = AbsorberUtils::absorber_deploy();

        set_contract_address(common::badguy());
        absorber.request();
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Not a provider', 'ENTRYPOINT_FAILED'))]
    fn test_non_provider_remove_fail() {
        let (_, _, _, absorber, _, _) = AbsorberUtils::absorber_deploy();

        set_contract_address(common::badguy());
        absorber.remove(0_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('ABS: Not a provider', 'ENTRYPOINT_FAILED'))]
    fn test_non_provider_reap_fail() {
        let (_, _, _, absorber, _, _) = AbsorberUtils::absorber_deploy();

        set_contract_address(common::badguy());
        absorber.reap();
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_provide_less_than_initial_shares_fail() {
        let (shrine, _, abbot, absorber, yangs, gates) = AbsorberUtils::absorber_deploy();

        let provider = AbsorberUtils::provider_1();
        let less_than_initial_shares_amt: Wad = (Absorber::INITIAL_SHARES - 1).into();
        AbsorberUtils::provide_to_absorber(
            shrine,
            abbot,
            absorber,
            provider,
            yangs,
            AbsorberUtils::provider_asset_amts(),
            gates,
            less_than_initial_shares_amt
        );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED'))]
    fn test_provide_insufficient_yin_fail() {
        let (shrine, _, abbot, absorber, yangs, gates) = AbsorberUtils::absorber_deploy();

        let provider = AbsorberUtils::provider_1();
        let provided_amt: Wad = (10000 * WAD_ONE).into();

        let yang_asset_amts: Span<u128> = AbsorberUtils::provider_asset_amts();
        common::fund_user(provider, yangs, yang_asset_amts);
        common::open_trove_helper(abbot, provider, yangs, yang_asset_amts, gates, provided_amt);

        set_contract_address(provider);
        let yin = IERC20Dispatcher { contract_address: shrine.contract_address };
        yin.approve(absorber.contract_address, BoundedU256::max());

        let insufficient_amt: Wad = (provided_amt.val + 1).into();
        absorber.provide(insufficient_amt);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u256_sub Overflow', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED'))]
    fn test_provide_insufficient_allowance_fail() {
        let (shrine, _, abbot, absorber, yangs, gates) = AbsorberUtils::absorber_deploy();

        let provider = AbsorberUtils::provider_1();
        let provided_amt: Wad = (10000 * WAD_ONE).into();

        let yang_asset_amts: Span<u128> = AbsorberUtils::provider_asset_amts();
        common::fund_user(provider, yangs, yang_asset_amts);
        common::open_trove_helper(abbot, provider, yangs, yang_asset_amts, gates, provided_amt);

        set_contract_address(provider);
        absorber.provide(provided_amt);
    }

    //
    // Tests - Bestow
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_bestow_inactive_reward() {
        let (
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
        ) =
            AbsorberUtils::absorber_with_rewards_and_first_provider();

        let expected_epoch: u32 = 0;
        let aura_addr: ContractAddress = *reward_tokens.at(0);
        let aura_blesser_addr: ContractAddress = *blessers.at(0);
        let veaura_addr: ContractAddress = *reward_tokens.at(1);
        let veaura_blesser_addr: ContractAddress = *blessers.at(1);

        let before_aura_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(aura_addr, expected_epoch);
        let before_veaura_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(veaura_addr, expected_epoch);

        // Set veAURA to inactive
        set_contract_address(AbsorberUtils::admin());
        absorber.set_reward(veaura_addr, veaura_blesser_addr, false);

        // Trigger rewards
        set_contract_address(provider);
        absorber.provide(0_u128.into());

        let after_aura_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(aura_addr, expected_epoch);
        assert(
            after_aura_distribution
                .asset_amt_per_share > before_aura_distribution
                .asset_amt_per_share,
            'cumulative should increase'
        );

        let after_veaura_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(veaura_addr, expected_epoch);
        assert(
            after_veaura_distribution
                .asset_amt_per_share == before_veaura_distribution
                .asset_amt_per_share,
            'cumulative should not increase'
        );

        // Set AURA to inactive
        set_contract_address(AbsorberUtils::admin());
        absorber.set_reward(aura_addr, aura_blesser_addr, false);

        // Trigger rewards
        set_contract_address(provider);
        absorber.provide(0_u128.into());

        let final_aura_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(aura_addr, expected_epoch);
        assert(
            final_aura_distribution
                .asset_amt_per_share == after_aura_distribution
                .asset_amt_per_share,
            'cumulative should bit increase'
        );

        let final_veaura_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(veaura_addr, expected_epoch);
        assert(
            final_veaura_distribution
                .asset_amt_per_share == after_veaura_distribution
                .asset_amt_per_share,
            'cumulative should not increase'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_bestow_depleted_active_reward() {
        let (shrine, _, abbot, absorber, yangs, gates) = AbsorberUtils::absorber_deploy();
        let reward_tokens: Span<ContractAddress> = AbsorberUtils::reward_tokens_deploy();
        let reward_amts_per_blessing: Span<u128> = AbsorberUtils::reward_amts_per_blessing();

        let aura_addr: ContractAddress = *reward_tokens.at(0);
        let veaura_addr: ContractAddress = *reward_tokens.at(1);

        // Manually deploy blesser to control minting of reward tokens to blesser
        // so that AURA blesser has no tokens
        let aura_blesser_addr: ContractAddress = AbsorberUtils::deploy_blesser_for_reward(
            absorber, aura_addr, AbsorberUtils::AURA_BLESS_AMT, false
        );
        let veaura_blesser_addr: ContractAddress = AbsorberUtils::deploy_blesser_for_reward(
            absorber, veaura_addr, AbsorberUtils::AURA_BLESS_AMT, true
        );

        let mut blessers: Array<ContractAddress> = Default::default();
        blessers.append(aura_blesser_addr);
        blessers.append(veaura_blesser_addr);

        AbsorberUtils::add_rewards_to_absorber(absorber, reward_tokens, blessers.span());

        let provider = AbsorberUtils::provider_1();
        let provided_amt: Wad = (10000 * WAD_ONE).into();
        AbsorberUtils::provide_to_absorber(
            shrine,
            abbot,
            absorber,
            provider,
            yangs,
            AbsorberUtils::provider_asset_amts(),
            gates,
            provided_amt
        );

        let expected_epoch: u32 = 0;
        let before_aura_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(aura_addr, expected_epoch);
        let before_veaura_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(veaura_addr, expected_epoch);

        // Trigger rewards
        set_contract_address(provider);
        absorber.provide(0_u128.into());

        let after_aura_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(aura_addr, expected_epoch);
        assert(
            after_aura_distribution
                .asset_amt_per_share == before_aura_distribution
                .asset_amt_per_share,
            'cumulative should not increase'
        );

        let after_veaura_distribution: DistributionInfo = absorber
            .get_cumulative_reward_amt_by_epoch(veaura_addr, expected_epoch);
        assert(
            after_veaura_distribution
                .asset_amt_per_share > before_veaura_distribution
                .asset_amt_per_share,
            'cumulative should increase'
        );
    }
}
