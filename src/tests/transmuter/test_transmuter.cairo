mod test_transmuter {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::cmp::min;
    use core::num::traits::{Bounded, Pow, Zero};
    use opus::core::roles::transmuter_roles;
    use opus::core::transmuter::transmuter as transmuter_contract;
    use opus::interfaces::IERC20::{
        IERC20Dispatcher, IERC20DispatcherTrait, IMintableDispatcher, IMintableDispatcherTrait,
    };
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::ITransmuter::{ITransmuterDispatcher, ITransmuterDispatcherTrait};
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::tests::transmuter::utils::transmuter_utils;
    use opus::tests::transmuter::utils::transmuter_utils::TransmuterTestConfig;
    use opus::utils::math::{fixed_point_to_wad, wad_to_fixed_point};
    use snforge_std::{
        ContractClass, EventSpyAssertionsTrait, spy_events, start_cheat_caller_address, stop_cheat_caller_address,
    };
    use starknet::ContractAddress;
    use wadray::{RAY_PERCENT, Ray, Signed, SignedWad, WAD_ONE, Wad};

    //
    // Tests - Deployment
    //

    // Check constructor function
    #[test]
    fn test_transmuter_deploy() {
        let mut spy = spy_events();
        let TransmuterTestConfig {
            transmuter, wad_usd_stable, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        // Check Transmuter getters
        let ceiling: Wad = transmuter_utils::INITIAL_CEILING.into();
        let receiver: ContractAddress = transmuter_utils::RECEIVER;

        assert(transmuter.get_asset() == wad_usd_stable.contract_address, 'wrong asset');
        assert(transmuter.get_total_transmuted().is_zero(), 'wrong total transmuted');
        assert(transmuter.get_ceiling() == ceiling, 'wrong ceiling');
        assert(
            transmuter.get_percentage_cap() == transmuter_contract::INITIAL_PERCENTAGE_CAP.into(),
            'wrong percentage cap',
        );
        assert(transmuter.get_receiver() == receiver, 'wrong receiver');
        assert(transmuter.get_reversibility(), 'not reversible');
        assert(transmuter.get_transmute_fee().is_zero(), 'non-zero transmute fee');
        assert(transmuter.get_reverse_fee().is_zero(), 'non-zero reverse fee');
        assert(transmuter.get_live(), 'not live');
        assert(!transmuter.get_reclaimable(), 'reclaimable');

        let transmuter_ac: IAccessControlDispatcher = IAccessControlDispatcher {
            contract_address: transmuter.contract_address,
        };
        let admin: ContractAddress = transmuter_utils::ADMIN;
        assert(transmuter_ac.get_admin() == admin, 'wrong admin');
        assert(transmuter_ac.get_roles(admin) == transmuter_roles::ADMIN, 'wrong admin roles');

        let expected_events = array![
            (
                transmuter.contract_address,
                transmuter_contract::Event::CeilingUpdated(
                    transmuter_contract::CeilingUpdated { old_ceiling: Zero::zero(), new_ceiling: ceiling },
                ),
            ),
            (
                transmuter.contract_address,
                transmuter_contract::Event::ReceiverUpdated(
                    transmuter_contract::ReceiverUpdated { old_receiver: Zero::zero(), new_receiver: receiver },
                ),
            ),
            (
                transmuter.contract_address,
                transmuter_contract::Event::PercentageCapUpdated(
                    transmuter_contract::PercentageCapUpdated {
                        cap: transmuter_contract::INITIAL_PERCENTAGE_CAP.into(),
                    },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    //
    // Tests - Setters
    //

    #[test]
    fn test_set_ceiling() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        let mut spy = spy_events();

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        // 2_000_000 (Wad)
        let new_ceiling: Wad = 2000000000000000000000000_u128.into();
        transmuter.set_ceiling(new_ceiling);

        assert(transmuter.get_ceiling() == new_ceiling, 'wrong ceiling');

        let expected_events = array![
            (
                transmuter.contract_address,
                transmuter_contract::Event::CeilingUpdated(
                    transmuter_contract::CeilingUpdated {
                        old_ceiling: transmuter_utils::INITIAL_CEILING.into(), new_ceiling,
                    },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_set_ceiling_unauthorized() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, common::BAD_GUY);
        // 2_000_000 (Wad)
        let new_ceiling: Wad = 2000000000000000000000000_u128.into();
        transmuter.set_ceiling(new_ceiling);
    }

    #[test]
    fn test_set_percentage_cap() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        let mut spy = spy_events();

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        // 5% (Ray)
        let cap: Ray = 50000000000000000000000000_u128.into();
        transmuter.set_percentage_cap(cap);

        assert(transmuter.get_percentage_cap() == cap, 'wrong percentage cap');

        let expected_events = array![
            (
                transmuter.contract_address,
                transmuter_contract::Event::PercentageCapUpdated(transmuter_contract::PercentageCapUpdated { cap }),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: 'TR: Exceeds upper bound')]
    fn test_set_percentage_cap_too_high_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        // 100% + 1E-27 (Ray)
        let cap: Ray = (transmuter_contract::PERCENTAGE_CAP_UPPER_BOUND + 1).into();
        transmuter.set_percentage_cap(cap);
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_set_percentage_cap_unauthorized_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, common::BAD_GUY);
        // 5% (Ray)
        let cap: Ray = 50000000000000000000000000_u128.into();
        transmuter.set_percentage_cap(cap);
    }

    #[test]
    fn test_set_receiver() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        let mut spy = spy_events();

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        let new_receiver: ContractAddress = 'new receiver'.try_into().unwrap();
        transmuter.set_receiver(new_receiver);

        assert(transmuter.get_receiver() == new_receiver, 'wrong receiver');

        let expected_events = array![
            (
                transmuter.contract_address,
                transmuter_contract::Event::ReceiverUpdated(
                    transmuter_contract::ReceiverUpdated { old_receiver: transmuter_utils::RECEIVER, new_receiver },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: 'TR: Zero address')]
    fn test_set_receiver_zero_addr_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        transmuter.set_receiver(Zero::zero());
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_set_receiver_unauthorized_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, common::BAD_GUY);
        let new_receiver: ContractAddress = 'new receiver'.try_into().unwrap();
        transmuter.set_receiver(new_receiver);
    }

    #[test]
    fn test_set_transmute_and_reverse_fee() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        let mut spy = spy_events();

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        // 0.5% (Ray)
        let new_fee: Ray = 5000000000000000000000000_u128.into();

        // transmute
        transmuter.set_transmute_fee(new_fee);

        assert(transmuter.get_transmute_fee() == new_fee, 'wrong transmute fee');

        let expected_events = array![
            (
                transmuter.contract_address,
                transmuter_contract::Event::TransmuteFeeUpdated(
                    transmuter_contract::TransmuteFeeUpdated { old_fee: Zero::zero(), new_fee },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);

        // reverse
        transmuter.set_reverse_fee(new_fee);

        assert(transmuter.get_reverse_fee() == new_fee, 'wrong reverse fee');

        let expected_events = array![
            (
                transmuter.contract_address,
                transmuter_contract::Event::ReverseFeeUpdated(
                    transmuter_contract::ReverseFeeUpdated { old_fee: Zero::zero(), new_fee },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: 'TR: Exceeds max fee')]
    fn test_set_transmute_fee_exceeds_max_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        // 1% + 1E-27 (Ray)
        let new_fee: Ray = 10000000000000000000000001_u128.into();
        transmuter.set_transmute_fee(new_fee);
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_set_transmute_fee_unauthorized_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, common::BAD_GUY);
        // 0.5% (Ray)
        let new_fee: Ray = 5000000000000000000000000_u128.into();
        transmuter.set_transmute_fee(new_fee);
    }

    #[test]
    #[should_panic(expected: 'TR: Exceeds max fee')]
    fn test_set_reverse_fee_exceeds_max_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        // 1% + 1E-27 (Ray)
        let new_fee: Ray = 10000000000000000000000001_u128.into();
        transmuter.set_reverse_fee(new_fee);
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_set_reverse_fee_unauthorized_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, common::BAD_GUY);
        // 0.5% (Ray)
        let new_fee: Ray = 5000000000000000000000000_u128.into();
        transmuter.set_reverse_fee(new_fee);
    }

    #[test]
    fn test_toggle_reversibility_pass() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        let mut spy = spy_events();

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        transmuter.toggle_reversibility();
        assert(!transmuter.get_reversibility(), 'reversible');

        let expected_events = array![
            (
                transmuter.contract_address,
                transmuter_contract::Event::ReversibilityToggled(
                    transmuter_contract::ReversibilityToggled { reversibility: false },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);

        transmuter.toggle_reversibility();
        assert(transmuter.get_reversibility(), 'not reversible');

        let expected_events = array![
            (
                transmuter.contract_address,
                transmuter_contract::Event::ReversibilityToggled(
                    transmuter_contract::ReversibilityToggled { reversibility: true },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    //
    // Tests - Transmute
    //

    #[test]
    fn test_transmute_with_preview_parametrized() {
        let transmuter_class: ContractClass = transmuter_utils::declare_transmuter();
        let token_class = common::declare_token();
        let TransmuterTestConfig {
            shrine, transmuter, ..,
        } =
            transmuter_utils::shrine_with_wad_usd_stable_transmuter(
                Option::Some(transmuter_class), Option::Some(token_class),
            );
        let wad_transmuter = transmuter;
        let nonwad_usd_stable = transmuter_utils::nonwad_usd_stable_deploy(Option::Some(token_class));
        let nonwad_transmuter = transmuter_utils::transmuter_deploy(
            Option::Some(transmuter_class),
            shrine.contract_address,
            nonwad_usd_stable.contract_address,
            transmuter_utils::RECEIVER,
        );

        let mut transmuters: Span<ITransmuterDispatcher> = array![wad_transmuter, nonwad_transmuter].span();

        let transmute_fees: Span<Ray> = array![
            Zero::zero(), // 0%
            1_u128.into(), // 1E-27 %
            1000000000000000000000000_u128.into(), // 0.1%
            2345000000000000000000000_u128.into(), // 0.2345
            10000000000000000000000000_u128.into() // 1% 
        ]
            .span();

        let real_transmute_amt: u128 = 1000;
        let transmute_amt_wad: Wad = (real_transmute_amt * WAD_ONE).into();
        let expected_wad_transmuted_amts: Span<Wad> = array![
            transmute_amt_wad, // 0% fee, 1000
            transmute_amt_wad, // 1E-27% fee (loss of precision), 1000
            999000000000000000000_u128.into(), // 0.1% fee, 999.00
            997655000000000000137_u128.into(), // 0.2345% fee, 997.655...
            990000000000000000000_u128.into() // 1% fee, 990.00
        ]
            .span();

        let user: ContractAddress = common::NON_ZERO_ADDR;

        for transmuter in transmuters {
            let transmuter = *transmuter;
            let asset = IERC20Dispatcher { contract_address: transmuter.get_asset() };

            let mut spy = spy_events();

            // approve Transmuter to transfer user's mock USD stable
            start_cheat_caller_address(asset.contract_address, user);
            asset.approve(transmuter.contract_address, Bounded::MAX);
            stop_cheat_caller_address(asset.contract_address);

            // Set up transmute amount to be equivalent to 1_000 (Wad) yin
            let asset_decimals: u8 = asset.decimals();
            let transmute_amt: u128 = real_transmute_amt * 10_u128.pow(asset_decimals.into());

            let mut expected_wad_transmuted_amts_copy = expected_wad_transmuted_amts;

            for transmute_fee in transmute_fees {
                start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
                transmuter.set_transmute_fee(*transmute_fee);

                start_cheat_caller_address(transmuter.contract_address, user);

                // check preview
                let preview: Wad = transmuter.preview_transmute(transmute_amt);
                let expected: Wad = *expected_wad_transmuted_amts_copy.pop_front().unwrap();
                common::assert_equalish(
                    preview, expected, (WAD_ONE / 100).into(), // error margin
                    'wrong preview transmute amt',
                );

                // transmute
                let expected_fee: Wad = transmute_amt_wad - preview;

                let before_user_yin_bal: Wad = shrine.get_yin(user);
                let before_total_yin: Wad = shrine.get_total_yin();
                let before_total_transmuted: Wad = transmuter.get_total_transmuted();
                let before_shrine_budget: SignedWad = shrine.get_budget();
                let before_transmuter_asset_bal: u256 = asset.balance_of(transmuter.contract_address);

                let expected_budget: SignedWad = before_shrine_budget + expected_fee.into();

                transmuter.transmute(transmute_amt);
                assert(shrine.get_yin(user) == before_user_yin_bal + preview, 'wrong user yin');
                assert(shrine.get_total_yin() == before_total_yin + preview, 'wrong total yin');
                assert(shrine.get_budget() == expected_budget, 'wrong budget');
                assert(
                    transmuter.get_total_transmuted() == before_total_transmuted + transmute_amt_wad,
                    'wrong total transmuted',
                );
                assert(
                    asset.balance_of(transmuter.contract_address) == before_transmuter_asset_bal + transmute_amt.into(),
                    'wrong transmuter asset bal',
                );

                let expected_events = array![
                    (
                        transmuter.contract_address,
                        transmuter_contract::Event::Transmute(
                            transmuter_contract::Transmute {
                                user, asset_amt: transmute_amt, yin_amt: preview, fee: expected_fee,
                            },
                        ),
                    ),
                ];
                spy.assert_emitted(@expected_events);
            };
        };
    }

    #[test]
    #[should_panic(expected: 'SH: Debt ceiling reached')]
    fn test_transmute_exceeds_shrine_ceiling_fail() {
        let TransmuterTestConfig {
            shrine, transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);
        let user: ContractAddress = common::NON_ZERO_ADDR;

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        let debt_ceiling: Wad = shrine.get_debt_ceiling();
        shrine.inject(user, debt_ceiling);

        transmuter.transmute(1_u128);
    }

    #[test]
    #[should_panic(expected: 'TR: Transmute is paused')]
    fn test_transmute_exceeds_transmuter_ceiling_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, common::NON_ZERO_ADDR);

        let ceiling: Wad = transmuter.get_ceiling();
        transmuter.transmute(ceiling.into());
        assert(transmuter.get_total_transmuted() == ceiling, 'sanity check');

        transmuter.transmute(1_u128.into());
    }

    #[test]
    #[should_panic(expected: 'TR: Transmute is paused')]
    fn test_transmute_exceeds_percentage_cap_fail() {
        let TransmuterTestConfig {
            shrine, transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);

        // reduce total supply to 1m yin
        let target_total_yin: Wad = 1000000000000000000000000_u128.into();
        shrine.eject(transmuter_utils::RECEIVER, transmuter_utils::START_TOTAL_YIN.into() - target_total_yin);
        assert(shrine.get_total_yin() == target_total_yin, 'sanity check #1');

        stop_cheat_caller_address(shrine.contract_address);

        // now, the cap is at 100_000
        start_cheat_caller_address(transmuter.contract_address, common::NON_ZERO_ADDR);
        let expected_cap: u128 = 100000 * WAD_ONE;
        transmuter.transmute(expected_cap + 1);
    }

    #[test]
    #[should_panic(expected: 'TR: Transmute is paused')]
    fn test_transmute_yin_spot_price_too_low_fail() {
        let TransmuterTestConfig {
            shrine, transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.update_yin_spot_price((WAD_ONE - 1).into());

        transmuter.transmute(1_u128.into());
    }

    //
    // Tests - Reverse
    //

    #[test]
    fn test_reverse_with_preview_parametrized() {
        let transmuter_class: ContractClass = transmuter_utils::declare_transmuter();
        let token_class = common::declare_token();

        let TransmuterTestConfig {
            shrine, transmuter, ..,
        } =
            transmuter_utils::shrine_with_wad_usd_stable_transmuter(
                Option::Some(transmuter_class), Option::Some(token_class),
            );
        let wad_transmuter = transmuter;
        let nonwad_usd_stable = transmuter_utils::nonwad_usd_stable_deploy(Option::Some(token_class));
        let nonwad_transmuter = transmuter_utils::transmuter_deploy(
            Option::Some(transmuter_class),
            shrine.contract_address,
            nonwad_usd_stable.contract_address,
            transmuter_utils::RECEIVER,
        );

        let mut transmuters: Span<ITransmuterDispatcher> = array![wad_transmuter, nonwad_transmuter].span();

        let reverse_fees: Span<Ray> = array![
            Zero::zero(), // 0%
            1_u128.into(), // 1E-27 %
            1000000000000000000000000_u128.into(), // 0.1%
            2345000000000000000000000_u128.into(), // 0.2345
            10000000000000000000000000_u128.into() // 1% 
        ]
            .span();

        let real_reverse_amt: u128 = 1000;
        let reverse_yin_amt: Wad = (real_reverse_amt * WAD_ONE).into();

        let user: ContractAddress = common::NON_ZERO_ADDR;

        for transmuter in transmuters {
            let transmuter = *transmuter;
            let asset = IERC20Dispatcher { contract_address: transmuter.get_asset() };

            // approve Transmuter to transfer user's mock USD stable
            start_cheat_caller_address(asset.contract_address, user);
            asset.approve(transmuter.contract_address, Bounded::MAX);
            stop_cheat_caller_address(asset.contract_address);

            // Transmute an amount of yin to set up Transmuter for reverse
            let asset_decimals: u8 = asset.decimals();
            let real_transmute_amt: u128 = reverse_fees.len().into() * real_reverse_amt;
            let asset_decimal_scale: u128 = 10_u128.pow(asset_decimals.into());
            let transmute_amt: u128 = real_transmute_amt * asset_decimal_scale;

            start_cheat_caller_address(transmuter.contract_address, user);
            transmuter.transmute(transmute_amt);
            stop_cheat_caller_address(transmuter.contract_address);

            let mut expected_reversed_asset_amts: Span<u128> = array![
                wad_to_fixed_point(reverse_yin_amt, asset_decimals).into(), // 0% fee, 1000
                wad_to_fixed_point(reverse_yin_amt, asset_decimals).into(), // 1E-27% fee (loss of precision), 1000
                wad_to_fixed_point(reverse_yin_amt - WAD_ONE.into(), asset_decimals), // 0.1% fee, 999.00
                wad_to_fixed_point(
                    reverse_yin_amt - 2345000000000000000_u128.into(), asset_decimals,
                ), // 0.2345% fee, 997.655...
                wad_to_fixed_point(reverse_yin_amt - (10 * WAD_ONE).into(), asset_decimals) // 1% fee, 990.00
            ]
                .span();

            let mut cumulative_asset_fees: u128 = 0;
            let mut cumulative_yin_fees = Zero::zero();

            for reverse_fee in reverse_fees {
                let mut spy = spy_events();

                start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
                transmuter.set_reverse_fee(*reverse_fee);
                stop_cheat_caller_address(transmuter.contract_address);

                start_cheat_caller_address(transmuter.contract_address, user);

                // check preview
                let preview: u128 = transmuter.preview_reverse(reverse_yin_amt);
                let expected: u128 = *expected_reversed_asset_amts.pop_front().unwrap();
                common::assert_equalish(
                    preview, expected, (asset_decimal_scale / 100), // error margin
                    'wrong preview reverse amt',
                );

                // transmute
                let expected_fee: Wad = wadray::rmul_rw(*reverse_fee, reverse_yin_amt);

                let before_user_yin_bal: Wad = shrine.get_yin(user);
                let before_total_yin: Wad = shrine.get_total_yin();
                let before_total_transmuted: Wad = transmuter.get_total_transmuted();
                let before_shrine_budget: SignedWad = shrine.get_budget();
                let before_transmuter_asset_bal: u256 = asset.balance_of(transmuter.contract_address);

                let expected_budget: SignedWad = before_shrine_budget + expected_fee.into();

                transmuter.reverse(reverse_yin_amt);
                assert(shrine.get_yin(user) == before_user_yin_bal - reverse_yin_amt, 'wrong user yin');
                assert(shrine.get_total_yin() == before_total_yin - reverse_yin_amt, 'wrong total yin');
                assert(shrine.get_budget() == expected_budget, 'wrong budget');
                assert(
                    transmuter.get_total_transmuted() == before_total_transmuted - reverse_yin_amt + expected_fee,
                    'wrong total transmuted',
                );
                assert(
                    asset.balance_of(transmuter.contract_address) == before_transmuter_asset_bal - preview.into(),
                    'wrong transmuter asset bal',
                );

                let expected_events = array![
                    (
                        transmuter.contract_address,
                        transmuter_contract::Event::Reverse(
                            transmuter_contract::Reverse {
                                user, asset_amt: preview, yin_amt: reverse_yin_amt, fee: expected_fee,
                            },
                        ),
                    ),
                ];
                spy.assert_emitted(@expected_events);

                cumulative_asset_fees += (real_reverse_amt * asset_decimal_scale) - preview;
                cumulative_yin_fees += expected_fee;

                stop_cheat_caller_address(transmuter.contract_address);
            }

            assert(
                asset.balance_of(transmuter.contract_address) == cumulative_asset_fees.into(),
                'wrong cumulative asset fees',
            );
            assert(transmuter.get_total_transmuted() == cumulative_yin_fees, 'wrong cumulative yin fees');
        };
    }

    #[test]
    #[should_panic(expected: 'TR: Reverse is paused')]
    fn test_reverse_disabled_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        transmuter.toggle_reversibility();
        assert(!transmuter.get_reversibility(), 'sanity check');

        start_cheat_caller_address(transmuter.contract_address, common::NON_ZERO_ADDR);
        let transmute_amt: u128 = 1000 * WAD_ONE;
        transmuter.transmute(transmute_amt);

        transmuter.reverse(1_u128.into());
    }

    #[test]
    #[should_panic(expected: 'TR: Insufficient assets')]
    fn test_reverse_zero_assets_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        let user: ContractAddress = common::NON_ZERO_ADDR;
        let asset_amt: u128 = WAD_ONE;
        start_cheat_caller_address(transmuter.contract_address, user);
        transmuter.transmute(asset_amt.into());

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        transmuter.sweep(asset_amt);

        start_cheat_caller_address(transmuter.contract_address, user);
        transmuter.reverse(1_u128.into());
    }

    //
    // Tests - Sweep
    //

    #[test]
    fn test_sweep_parametrized_pass() {
        let shrine_class: ContractClass = shrine_utils::declare_shrine();
        let transmuter_class: ContractClass = transmuter_utils::declare_transmuter();
        let token_class = common::declare_token();

        let admin: ContractAddress = transmuter_utils::ADMIN;
        let receiver: ContractAddress = transmuter_utils::RECEIVER;
        let user: ContractAddress = common::NON_ZERO_ADDR;

        let mut transmuter_ids: Span<u32> = array![0, 1].span();

        for transmuter_id in transmuter_ids {
            // parametrize transmuter and asset
            let asset = if *transmuter_id == 0 {
                transmuter_utils::wad_usd_stable_deploy(Option::Some(token_class))
            } else {
                transmuter_utils::nonwad_usd_stable_deploy(Option::Some(token_class))
            };
            let asset_decimals: u8 = asset.decimals();

            let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::Some(shrine_class));

            let transmuter: ITransmuterDispatcher = transmuter_utils::transmuter_deploy(
                Option::Some(transmuter_class), shrine.contract_address, asset.contract_address, receiver,
            );

            let shrine_debt_ceiling: Wad = transmuter_utils::INITIAL_CEILING.into();
            let seed_amt: Wad = (100000 * WAD_ONE).into();

            transmuter_utils::setup_shrine_with_transmuter(
                shrine, transmuter, shrine_debt_ceiling, seed_amt, receiver, user,
            );

            let mut transmute_asset_amts: Span<u128> = array![0, 1000 * 10_u128.pow(asset_decimals.into())].span();

            for transmute_asset_amt in transmute_asset_amts {
                let mut spy = spy_events();

                // parametrize amount to sweep
                let mut sweep_amts: Array<u128> = array![0, 1, *transmute_asset_amt, *transmute_asset_amt + 1];

                if (*transmute_asset_amt).is_non_zero() {
                    sweep_amts.append(*transmute_asset_amt - 1);
                }

                for sweep_amt in sweep_amts.span() {
                    start_cheat_caller_address(transmuter.contract_address, user);
                    transmuter.transmute(*transmute_asset_amt);

                    let before_receiver_asset_bal: u256 = asset.balance_of(receiver);

                    start_cheat_caller_address(transmuter.contract_address, admin);
                    transmuter.sweep(*sweep_amt);

                    let adjusted_sweep_amt: u128 = min(*transmute_asset_amt, *sweep_amt);

                    assert(
                        asset.balance_of(receiver) == before_receiver_asset_bal + adjusted_sweep_amt.into(),
                        'wrong receiver asset bal',
                    );

                    if adjusted_sweep_amt.is_non_zero() {
                        let expected_events = array![
                            (
                                transmuter.contract_address,
                                transmuter_contract::Event::Sweep(
                                    transmuter_contract::Sweep { recipient: receiver, asset_amt: adjusted_sweep_amt },
                                ),
                            ),
                        ];
                        spy.assert_emitted(@expected_events);
                    }

                    // reset by sweeping all remaining amount
                    transmuter.sweep(Bounded::MAX);
                    assert(asset.balance_of(transmuter.contract_address).is_zero(), 'sanity check');

                    stop_cheat_caller_address(transmuter.contract_address);
                };
            };
        };
    }

    //
    // Tests - Withdraw secondary asset
    //

    #[test]
    fn test_withdraw_secondary_parametrized_pass() {
        let shrine_class: ContractClass = shrine_utils::declare_shrine();
        let transmuter_class: ContractClass = transmuter_utils::declare_transmuter();
        let token_class = common::declare_token();

        let admin: ContractAddress = transmuter_utils::ADMIN;
        let receiver: ContractAddress = transmuter_utils::RECEIVER;
        let user: ContractAddress = common::NON_ZERO_ADDR;

        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::Some(shrine_class));
        let asset = transmuter_utils::wad_usd_stable_deploy(Option::Some(token_class));

        let secondary_asset_decimals: Span<u8> = array![6, 18].span();
        let kill_transmuter_toggle: Span<bool> = array![true, false].span();

        for secondary_asset_decimal in secondary_asset_decimals {
            for kill_transmuter in kill_transmuter_toggle {
                let transmuter: ITransmuterDispatcher = transmuter_utils::transmuter_deploy(
                    Option::Some(transmuter_class), shrine.contract_address, asset.contract_address, receiver,
                );

                // parametrize transmuter and asset
                let secondary_asset: ContractAddress = common::deploy_token(
                    'Secondary Asset',
                    'sASSET',
                    (*secondary_asset_decimal).into(),
                    WAD_ONE.into(),
                    transmuter_utils::ADMIN,
                    Option::Some(token_class),
                );
                let secondary_asset_erc20 = IERC20Dispatcher { contract_address: secondary_asset };
                let secondary_asset_amt: u128 = 10_u128.pow((*secondary_asset_decimal).into());

                let shrine_debt_ceiling: Wad = transmuter_utils::INITIAL_CEILING.into();
                let seed_amt: Wad = (100000 * WAD_ONE).into();

                transmuter_utils::setup_shrine_with_transmuter(
                    shrine, transmuter, shrine_debt_ceiling, seed_amt, receiver, user,
                );

                let mut spy = spy_events();

                // parametrize amount to withdraw
                let withdraw_secondary_amts: Span<u128> = array![0, 1, secondary_asset_amt, secondary_asset_amt + 1]
                    .span();

                if *kill_transmuter {
                    start_cheat_caller_address(transmuter.contract_address, admin);
                    transmuter.kill();
                    stop_cheat_caller_address(transmuter.contract_address);
                }

                for withdraw_secondary_amt in withdraw_secondary_amts {
                    IMintableDispatcher { contract_address: secondary_asset }
                        .mint(transmuter.contract_address, secondary_asset_amt.into());

                    start_cheat_caller_address(transmuter.contract_address, user);

                    let before_receiver_asset_bal: u256 = secondary_asset_erc20.balance_of(receiver);

                    start_cheat_caller_address(transmuter.contract_address, admin);
                    transmuter.withdraw_secondary_asset(secondary_asset, *withdraw_secondary_amt);

                    let adjusted_secondary_amt: u128 = min(secondary_asset_amt, *withdraw_secondary_amt);

                    assert(
                        secondary_asset_erc20.balance_of(receiver) == before_receiver_asset_bal
                            + adjusted_secondary_amt.into(),
                        'wrong receiver asset bal',
                    );

                    if adjusted_secondary_amt.is_non_zero() {
                        let expected_events = array![
                            (
                                transmuter.contract_address,
                                transmuter_contract::Event::WithdrawSecondaryAsset(
                                    transmuter_contract::WithdrawSecondaryAsset {
                                        recipient: receiver, asset: secondary_asset, asset_amt: adjusted_secondary_amt,
                                    },
                                ),
                            ),
                        ];
                        spy.assert_emitted(@expected_events);
                    }

                    // reset by sweeping all remaining amount
                    transmuter.withdraw_secondary_asset(secondary_asset, Bounded::MAX);
                    assert(secondary_asset_erc20.balance_of(transmuter.contract_address).is_zero(), 'sanity check');

                    stop_cheat_caller_address(transmuter.contract_address);
                };
            };
        };
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_withdraw_secondary_asset_unauthorized() {
        let token_class = common::declare_token();
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::Some(token_class));

        let secondary_asset: ContractAddress = common::deploy_token(
            'Secondary Asset', 'sASSET', 18, WAD_ONE.into(), transmuter.contract_address, Option::Some(token_class),
        );

        start_cheat_caller_address(transmuter.contract_address, common::BAD_GUY);
        transmuter.withdraw_secondary_asset(secondary_asset, Bounded::MAX);
    }

    #[test]
    #[should_panic(expected: 'TR: Primary asset')]
    fn test_withdraw_primary_asset_as_secondary_asset_fail() {
        let token_class = common::declare_token();
        let TransmuterTestConfig {
            transmuter, wad_usd_stable, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::Some(token_class));

        let _secondary_asset: ContractAddress = common::deploy_token(
            'Secondary Asset', 'sASSET', 18, WAD_ONE.into(), transmuter.contract_address, Option::Some(token_class),
        );

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        transmuter.withdraw_secondary_asset(wad_usd_stable.contract_address, Bounded::MAX);
    }

    //
    // Tests - Settle
    //

    fn test_settle(transmuter_id: u32) {
        let shrine_class: ContractClass = shrine_utils::declare_shrine();
        let transmuter_class: ContractClass = transmuter_utils::declare_transmuter();
        let token_class = common::declare_token();

        let transmuter_admin: ContractAddress = transmuter_utils::ADMIN;
        let shrine_admin: ContractAddress = shrine_utils::ADMIN;
        let receiver: ContractAddress = transmuter_utils::RECEIVER;
        let user: ContractAddress = common::NON_ZERO_ADDR;

        // parametrize transmuter and asset
        let asset = if transmuter_id == 0 {
            transmuter_utils::wad_usd_stable_deploy(Option::Some(token_class))
        } else {
            transmuter_utils::nonwad_usd_stable_deploy(Option::Some(token_class))
        };
        let asset_decimals: u8 = asset.decimals();

        let transmute_asset_amts: Span<u128> = array![0, 1000 * 10_u128.pow(asset_decimals.into())].span();

        for transmute_asset_amt in transmute_asset_amts {
            // parametrize amount of yin in Transmuter at time of settlement
            let mut transmuter_yin_amts: Array<Wad> = array![
                Zero::zero(),
                1_u128.into(),
                fixed_point_to_wad(*transmute_asset_amt, asset_decimals),
                fixed_point_to_wad(*transmute_asset_amt + 1, asset_decimals),
            ];

            if (*transmute_asset_amt).is_non_zero() {
                transmuter_yin_amts.append(fixed_point_to_wad(*transmute_asset_amt - 1, asset_decimals));
            }

            let mut transmuter_yin_amts: Span<Wad> = transmuter_yin_amts.span();

            for transmuter_yin_amt in transmuter_yin_amts {
                let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::Some(shrine_class));

                let transmuter: ITransmuterDispatcher = transmuter_utils::transmuter_deploy(
                    Option::Some(transmuter_class), shrine.contract_address, asset.contract_address, receiver,
                );

                let mut spy = spy_events();

                let shrine_debt_ceiling: Wad = transmuter_utils::INITIAL_CEILING.into();
                let seed_amt: Wad = (100000 * WAD_ONE).into();

                transmuter_utils::setup_shrine_with_transmuter(
                    shrine, transmuter, shrine_debt_ceiling, seed_amt, receiver, user,
                );

                start_cheat_caller_address(transmuter.contract_address, user);

                // transmute some amount
                transmuter.transmute(*transmute_asset_amt);
                let transmuted_yin_amt: Wad = transmuter.get_total_transmuted();

                stop_cheat_caller_address(transmuter.contract_address);

                // set up the transmuter with the necessary yin amt
                start_cheat_caller_address(shrine.contract_address, shrine_admin);
                shrine.inject(transmuter.contract_address, *transmuter_yin_amt);
                stop_cheat_caller_address(shrine.contract_address);

                let before_receiver_asset_bal: u256 = asset.balance_of(receiver);
                let before_receiver_yin_bal: Wad = shrine.get_yin(receiver);
                let before_budget: SignedWad = shrine.get_budget();

                start_cheat_caller_address(transmuter.contract_address, transmuter_admin);
                transmuter.settle();

                let mut expected_budget_adjustment = Zero::zero();
                let mut leftover_yin_amt = Zero::zero();

                if *transmuter_yin_amt < transmuted_yin_amt {
                    expected_budget_adjustment = -((transmuted_yin_amt - *transmuter_yin_amt).into());
                } else {
                    leftover_yin_amt = *transmuter_yin_amt - transmuted_yin_amt;
                }

                assert(shrine.get_budget() == before_budget + expected_budget_adjustment, 'wrong budget');
                assert(shrine.get_yin(receiver) == before_receiver_yin_bal + leftover_yin_amt, 'wrong receiver yin');
                assert(shrine.get_yin(transmuter.contract_address).is_zero(), 'wrong transmuter yin');
                assert(
                    asset.balance_of(receiver) == before_receiver_asset_bal + (*transmute_asset_amt).into(),
                    'wrong receiver asset',
                );

                assert(transmuter.get_total_transmuted().is_zero(), 'wrong total transmuted');
                assert(!transmuter.get_live(), 'not killed');

                let deficit: Wad = if expected_budget_adjustment.is_negative() {
                    (-expected_budget_adjustment).try_into().unwrap()
                } else {
                    Zero::zero()
                };
                let expected_events = array![
                    (
                        transmuter.contract_address,
                        transmuter_contract::Event::Settle(transmuter_contract::Settle { deficit }),
                    ),
                ];
                spy.assert_emitted(@expected_events);

                stop_cheat_caller_address(transmuter.contract_address);
            };
        };
    }

    #[test]
    fn test_settle_parametrized_1() {
        test_settle(0);
    }

    #[test]
    fn test_settle_parametrized_2() {
        test_settle(1);
    }

    #[test]
    #[should_panic(expected: 'TR: Transmuter is not live')]
    fn test_transmute_after_settle_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        transmuter.settle();

        start_cheat_caller_address(transmuter.contract_address, common::NON_ZERO_ADDR);
        transmuter.transmute(1_u128);
    }

    #[test]
    #[should_panic(expected: 'TR: Transmuter is not live')]
    fn test_reverse_after_settle_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        transmuter.settle();

        start_cheat_caller_address(transmuter.contract_address, common::NON_ZERO_ADDR);
        transmuter.reverse(1_u128.into());
    }

    #[test]
    #[should_panic(expected: 'TR: Transmuter is not live')]
    fn test_sweep_after_settle_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        transmuter.settle();

        transmuter.sweep(Bounded::MAX);
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_sweep_unauthorized() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, common::BAD_GUY);
        transmuter.sweep(Bounded::MAX);
    }

    //
    // Tests - Shutdown
    //

    #[test]
    fn test_kill_and_reclaim_parametrized_pass() {
        let shrine_class: ContractClass = shrine_utils::declare_shrine();
        let transmuter_class: ContractClass = transmuter_utils::declare_transmuter();
        let token_class = common::declare_token();

        let admin: ContractAddress = transmuter_utils::ADMIN;
        let receiver: ContractAddress = transmuter_utils::RECEIVER;
        let user: ContractAddress = common::NON_ZERO_ADDR;

        let transmuter_ids: Span<u32> = array![0, 1].span();

        for transmuter_id in transmuter_ids {
            // parametrize transmuter and asset
            let asset = if *transmuter_id == 0 {
                transmuter_utils::wad_usd_stable_deploy(Option::Some(token_class))
            } else {
                transmuter_utils::nonwad_usd_stable_deploy(Option::Some(token_class))
            };
            let asset_decimals: u8 = asset.decimals();
            let asset_decimal_scale: u128 = 10_u128.pow(asset_decimals.into());
            let transmute_asset_amt: u128 = 1000 * asset_decimal_scale;

            let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::Some(shrine_class));

            let transmuter: ITransmuterDispatcher = transmuter_utils::transmuter_deploy(
                Option::Some(transmuter_class), shrine.contract_address, asset.contract_address, receiver,
            );

            let shrine_debt_ceiling: Wad = transmuter_utils::INITIAL_CEILING.into();
            let seed_amt: Wad = (100000 * WAD_ONE).into();

            transmuter_utils::setup_shrine_with_transmuter(
                shrine, transmuter, shrine_debt_ceiling, seed_amt, receiver, user,
            );

            let mut spy = spy_events();

            start_cheat_caller_address(transmuter.contract_address, user);

            // transmute some amount
            transmuter.transmute(transmute_asset_amt);
            let transmuted_yin_amt: Wad = transmuter.get_total_transmuted();

            start_cheat_caller_address(transmuter.contract_address, admin);
            transmuter.kill();

            assert(!transmuter.get_live(), 'not killed');

            let expected_events = array![
                (transmuter.contract_address, transmuter_contract::Event::Killed(transmuter_contract::Killed {})),
            ];
            spy.assert_emitted(@expected_events);

            transmuter.enable_reclaim();

            start_cheat_caller_address(transmuter.contract_address, user);

            let asset_error_margin: u128 = asset_decimal_scale / 100;
            let mut expected_events = ArrayTrait::new();

            // first reclaim for 10% of original transmuted amount
            let before_user_asset_bal: u256 = asset.balance_of(user);
            let before_user_yin_bal: Wad = shrine.get_yin(user);

            let first_reclaim_pct: Ray = (RAY_PERCENT * 10).into();
            let first_reclaim_yin_amt: Wad = wadray::rmul_wr(transmuted_yin_amt, first_reclaim_pct);
            let preview: u128 = transmuter.preview_reclaim(first_reclaim_yin_amt);
            let expected_first_reclaim_asset_amt: u128 = wadray::rmul_wr(transmute_asset_amt.into(), first_reclaim_pct)
                .into();
            common::assert_equalish(
                preview, expected_first_reclaim_asset_amt, asset_error_margin, 'wrong preview reclaim amt #1',
            );

            transmuter.reclaim(first_reclaim_yin_amt);
            let first_user_asset_bal: u256 = asset.balance_of(user);
            assert(first_user_asset_bal == before_user_asset_bal + preview.into(), 'wrong reclaim amt #1');

            let first_user_yin_bal: Wad = shrine.get_yin(user);
            assert(first_user_yin_bal == before_user_yin_bal - first_reclaim_yin_amt, 'wrong user yin #1');

            expected_events
                .append(
                    (
                        transmuter.contract_address,
                        transmuter_contract::Event::Reclaim(
                            transmuter_contract::Reclaim { user, asset_amt: preview, yin_amt: first_reclaim_yin_amt },
                        ),
                    ),
                );

            // second reclaim for 35% of original transmuted amount
            let second_reclaim_pct: Ray = (RAY_PERCENT * 35).into();
            let second_reclaim_yin_amt: Wad = wadray::rmul_wr(transmuted_yin_amt, second_reclaim_pct);
            let preview: u128 = transmuter.preview_reclaim(second_reclaim_yin_amt);
            let expected_second_reclaim_asset_amt: u128 = wadray::rmul_wr(
                transmute_asset_amt.into(), second_reclaim_pct,
            )
                .into();
            common::assert_equalish(
                preview, expected_second_reclaim_asset_amt, asset_error_margin, 'wrong preview reclaim amt #2',
            );

            transmuter.reclaim(second_reclaim_yin_amt);
            let second_user_asset_bal: u256 = asset.balance_of(user);
            assert(second_user_asset_bal == first_user_asset_bal + preview.into(), 'wrong reclaim amt #2');

            let second_user_yin_bal: Wad = shrine.get_yin(user);
            assert(second_user_yin_bal == first_user_yin_bal - second_reclaim_yin_amt, 'wrong user yin #2');

            expected_events
                .append(
                    (
                        transmuter.contract_address,
                        transmuter_contract::Event::Reclaim(
                            transmuter_contract::Reclaim { user, asset_amt: preview, yin_amt: second_reclaim_yin_amt },
                        ),
                    ),
                );

            // third reclaim for 100% of original transmuted amount, which should be capped
            // to what is remaining
            let third_reclaim_yin_amt: Wad = transmuted_yin_amt;
            let reclaimable_yin: Wad = transmuter.get_total_transmuted();
            let preview: u128 = transmuter.preview_reclaim(third_reclaim_yin_amt);
            let expected_third_reclaim_asset_amt: u128 = asset
                .balance_of(transmuter.contract_address)
                .try_into()
                .unwrap();
            common::assert_equalish(
                preview, expected_third_reclaim_asset_amt, asset_error_margin, 'wrong preview reclaim amt #3',
            );

            transmuter.reclaim(third_reclaim_yin_amt);
            let third_user_asset_bal: u256 = asset.balance_of(user);
            assert(third_user_asset_bal == second_user_asset_bal + preview.into(), 'wrong reclaim amt #3');

            let third_user_yin_bal: Wad = shrine.get_yin(user);
            assert(third_user_yin_bal == second_user_yin_bal - reclaimable_yin, 'wrong user yin #3');

            expected_events
                .append(
                    (
                        transmuter.contract_address,
                        transmuter_contract::Event::Reclaim(
                            transmuter_contract::Reclaim { user, asset_amt: preview, yin_amt: reclaimable_yin },
                        ),
                    ),
                );
            spy.assert_emitted(@expected_events);

            // preview reclaim when transmuter has no assets
            assert(transmuter.preview_reclaim(third_reclaim_yin_amt).is_zero(), 'preview should be zero');

            stop_cheat_caller_address(transmuter.contract_address);
        };
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_kill_unauthorized() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, common::BAD_GUY);
        transmuter.kill();
    }

    #[test]
    #[should_panic(expected: 'TR: Transmuter is not live')]
    fn test_transmute_after_kill_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        transmuter.kill();

        start_cheat_caller_address(transmuter.contract_address, common::NON_ZERO_ADDR);
        transmuter.transmute(1_u128);
    }

    #[test]
    #[should_panic(expected: 'TR: Transmuter is not live')]
    fn test_reverse_after_kill_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        transmuter.kill();

        start_cheat_caller_address(transmuter.contract_address, common::NON_ZERO_ADDR);
        transmuter.transmute(1_u128.into());
    }

    #[test]
    #[should_panic(expected: 'TR: Transmuter is not live')]
    fn test_sweep_after_kill_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        transmuter.kill();

        transmuter.sweep(Bounded::MAX);
    }

    #[test]
    #[should_panic(expected: 'TR: Reclaim unavailable')]
    fn test_reclaim_disabled_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        transmuter.kill();

        transmuter.reclaim(Bounded::MAX);
    }

    #[test]
    #[should_panic(expected: 'TR: Transmuter is live')]
    fn test_enable_reclaim_while_live_fail() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, transmuter_utils::ADMIN);
        transmuter.enable_reclaim();
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_enable_reclaim_unauthorized() {
        let TransmuterTestConfig {
            transmuter, ..,
        } = transmuter_utils::shrine_with_wad_usd_stable_transmuter(Option::None, Option::None);

        start_cheat_caller_address(transmuter.contract_address, common::BAD_GUY);
        transmuter.enable_reclaim();
    }
}
