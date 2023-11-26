mod test_transmuter {
    use debug::PrintTrait;
    use integer::BoundedInt;
    use opus::core::roles::transmuter_roles;
    use opus::core::transmuter::transmuter as transmuter_contract;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::ITransmuter::{ITransmuterDispatcher, ITransmuterDispatcherTrait};
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::tests::transmuter::utils::transmuter_utils;
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::utils::math::pow;
    use opus::utils::wadray::{Ray, RayZeroable, Wad, WadZeroable, WAD_ONE};
    use opus::utils::wadray;
    use opus::utils::wadray_signed::SignedWad;
    use opus::utils::wadray_signed;
    use starknet::ContractAddress;
    use starknet::contract_address::{contract_address_try_from_felt252, ContractAddressZeroable};
    use starknet::testing::set_contract_address;

    //
    // Tests - Deployment 
    //

    // Check constructor function
    #[test]
    #[available_gas(20000000000)]
    fn test_transmuter_deploy() {
        let (shrine, transmuter, mock_usd_stable) =
            transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();

        // Check Transmuter getters
        let ceiling: Wad = transmuter_utils::INITIAL_CEILING.into();
        let receiver: ContractAddress = transmuter_utils::receiver();

        assert(transmuter.get_asset() == mock_usd_stable.contract_address, 'wrong asset');
        assert(transmuter.get_total_transmuted().is_zero(), 'wrong total transmuted');
        assert(transmuter.get_ceiling() == ceiling, 'wrong ceiling');
        assert(
            transmuter
                .get_percentage_cap() == transmuter_contract::PERCENTAGE_CAP_UPPER_BOUND
                .into(),
            'wrong percentage cap'
        );
        assert(transmuter.get_receiver() == receiver, 'wrong receiver');
        assert(transmuter.get_reversibility(), 'not reversible');
        assert(transmuter.get_transmute_fee().is_zero(), 'non-zero transmute fee');
        assert(transmuter.get_reverse_fee().is_zero(), 'non-zero reverse fee');
        assert(transmuter.get_live(), 'not live');
        assert(!transmuter.get_reclaimable(), 'reclaimable');

        let transmuter_ac: IAccessControlDispatcher = IAccessControlDispatcher {
            contract_address: transmuter.contract_address
        };
        let admin: ContractAddress = shrine_utils::admin();
        assert(transmuter_ac.get_admin() == admin, 'wrong admin');
        assert(
            transmuter_ac.get_roles(admin) == transmuter_roles::default_admin_role(),
            'wrong admin roles'
        );

        let mut expected_events: Span<transmuter_contract::Event> = array![
            transmuter_contract::Event::CeilingUpdated(
                transmuter_contract::CeilingUpdated {
                    old_ceiling: WadZeroable::zero(), new_ceiling: ceiling,
                }
            ),
            transmuter_contract::Event::ReceiverUpdated(
                transmuter_contract::ReceiverUpdated {
                    old_receiver: ContractAddressZeroable::zero(), new_receiver: receiver
                }
            ),
            transmuter_contract::Event::PercentageCapUpdated(
                transmuter_contract::PercentageCapUpdated {
                    cap: transmuter_contract::PERCENTAGE_CAP_UPPER_BOUND.into(),
                }
            ),
        ]
            .span();
        common::assert_events_emitted(transmuter.contract_address, expected_events, Option::None);
    }

    //
    // Tests - Setters
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_set_ceiling() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();

        set_contract_address(shrine_utils::admin());
        // 2_000_000 (Wad)
        let new_ceiling: Wad = 2000000000000000000000000_u128.into();
        transmuter.set_ceiling(new_ceiling);

        assert(transmuter.get_ceiling() == new_ceiling, 'wrong ceiling');

        let expected_events: Span<transmuter_contract::Event> = array![
            transmuter_contract::Event::CeilingUpdated(
                transmuter_contract::CeilingUpdated {
                    old_ceiling: transmuter_utils::INITIAL_CEILING.into(), new_ceiling
                }
            ),
        ]
            .span();
        common::assert_events_emitted(transmuter.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_ceiling_unauthorized() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();

        set_contract_address(common::badguy());
        // 2_000_000 (Wad)
        let new_ceiling: Wad = 2000000000000000000000000_u128.into();
        transmuter.set_ceiling(new_ceiling);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_percentage_cap() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();

        set_contract_address(shrine_utils::admin());
        // 5% (Ray)
        let cap: Ray = 50000000000000000000000000_u128.into();
        transmuter.set_percentage_cap(cap);

        assert(transmuter.get_percentage_cap() == cap, 'wrong percentage cap');

        let expected_events: Span<transmuter_contract::Event> = array![
            transmuter_contract::Event::PercentageCapUpdated(
                transmuter_contract::PercentageCapUpdated { cap }
            ),
        ]
            .span();
        common::assert_events_emitted(transmuter.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('TR: Exceeds upper bound', 'ENTRYPOINT_FAILED'))]
    fn test_set_percentage_cap_too_high_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();

        set_contract_address(shrine_utils::admin());
        // 10% + 1E-27 (Ray)
        let cap: Ray = 100000000000000000000000001_u128.into();
        transmuter.set_percentage_cap(cap);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_percentage_cap_unauthorized() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();

        set_contract_address(common::badguy());
        // 5% (Ray)
        let cap: Ray = 50000000000000000000000000_u128.into();
        transmuter.set_percentage_cap(cap);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_receiver() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();

        set_contract_address(shrine_utils::admin());
        let new_receiver: ContractAddress = contract_address_try_from_felt252('new receiver')
            .unwrap();
        transmuter.set_receiver(new_receiver);

        assert(transmuter.get_receiver() == new_receiver, 'wrong receiver');

        let expected_events: Span<transmuter_contract::Event> = array![
            transmuter_contract::Event::ReceiverUpdated(
                transmuter_contract::ReceiverUpdated {
                    old_receiver: transmuter_utils::receiver(), new_receiver
                }
            ),
        ]
            .span();
        common::assert_events_emitted(transmuter.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('TR: Zero address', 'ENTRYPOINT_FAILED'))]
    fn test_set_receiver_zero_addr_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();

        set_contract_address(shrine_utils::admin());
        transmuter.set_receiver(ContractAddressZeroable::zero());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_receiver_authorized() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();

        set_contract_address(common::badguy());
        let new_receiver: ContractAddress = contract_address_try_from_felt252('new receiver')
            .unwrap();
        transmuter.set_receiver(new_receiver);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_transmute_and_reverse_fee() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();

        set_contract_address(shrine_utils::admin());
        // 0.5% (Ray)
        let new_fee: Ray = 5000000000000000000000000_u128.into();

        // transmute
        transmuter.set_transmute_fee(new_fee);

        assert(transmuter.get_transmute_fee() == new_fee, 'wrong transmute fee');

        let expected_events: Span<transmuter_contract::Event> = array![
            transmuter_contract::Event::TransmuteFeeUpdated(
                transmuter_contract::TransmuteFeeUpdated { old_fee: RayZeroable::zero(), new_fee }
            ),
        ]
            .span();
        common::assert_events_emitted(transmuter.contract_address, expected_events, Option::None);

        // reverse
        transmuter.set_reverse_fee(new_fee);

        assert(transmuter.get_reverse_fee() == new_fee, 'wrong reverse fee');

        let expected_events: Span<transmuter_contract::Event> = array![
            transmuter_contract::Event::ReverseFeeUpdated(
                transmuter_contract::ReverseFeeUpdated { old_fee: RayZeroable::zero(), new_fee }
            ),
        ]
            .span();
        common::assert_events_emitted(transmuter.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('TR: Exceeds max fee', 'ENTRYPOINT_FAILED'))]
    fn test_set_transmute_fee_exceeds_max_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();

        set_contract_address(shrine_utils::admin());
        // 1% + 1E-27 (Ray)
        let new_fee: Ray = 10000000000000000000000001_u128.into();
        transmuter.set_transmute_fee(new_fee);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_transmute_fee_authorized() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();

        set_contract_address(common::badguy());
        // 0.5% (Ray)
        let new_fee: Ray = 5000000000000000000000000_u128.into();
        transmuter.set_transmute_fee(new_fee);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('TR: Exceeds max fee', 'ENTRYPOINT_FAILED'))]
    fn test_set_reverse_fee_exceeds_max_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();

        set_contract_address(shrine_utils::admin());
        // 1% + 1E-27 (Ray)
        let new_fee: Ray = 10000000000000000000000001_u128.into();
        transmuter.set_reverse_fee(new_fee);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_reverse_fee_authorized() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();

        set_contract_address(common::badguy());
        // 0.5% (Ray)
        let new_fee: Ray = 5000000000000000000000000_u128.into();
        transmuter.set_reverse_fee(new_fee);
    }

    //
    // Tests - Transmute
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_transmute_with_preview_parametrized() {
        let (shrine, wad_transmuter, _) =
            transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();
        let mock_nonwad_usd_stable = transmuter_utils::mock_nonwad_usd_stable_deploy();
        let nonwad_transmuter = transmuter_utils::transmuter_deploy(
            shrine.contract_address,
            mock_nonwad_usd_stable.contract_address,
            transmuter_utils::receiver(),
        );

        let mut transmuters: Span<ITransmuterDispatcher> = array![wad_transmuter, nonwad_transmuter]
            .span();

        let transmute_fees: Span<Ray> = array![
            RayZeroable::zero(), // 0%
            1_u128.into(), // 1E-27 %
            1000000000000000000000000_u128.into(), // 0.1%
            2345000000000000000000000_u128.into(), // 0.2345
            10000000000000000000000000_u128.into(), // 1% 
        ]
            .span();

        let real_transmute_amt: u128 = 1000;
        let transmute_amt_wad: Wad = (real_transmute_amt * WAD_ONE).into();
        let expected_wad_transmuted_amts: Span<Wad> = array![
            transmute_amt_wad.into(), // 0% fee, 1000
            transmute_amt_wad.into(), // 1E-27% fee (loss of precision), 1000
            999000000000000000000_u128.into(), // 0.1% fee, 999.00
            997655000000000000137_u128.into(), // 0.2345% fee, 997.655...
            990000000000000000000_u128.into(), // 1% fee, 990.00
        ]
            .span();

        let user: ContractAddress = transmuter_utils::user();

        loop {
            match transmuters.pop_front() {
                Option::Some(transmuter) => {
                    let transmuter = *transmuter;
                    let asset = IERC20Dispatcher { contract_address: transmuter.get_asset() };

                    // approve Transmuter to transfer user's mock USD stable
                    set_contract_address(user);
                    asset.approve(transmuter.contract_address, BoundedInt::max());

                    // Set up transmute amount to be equivalent to 1_000 (Wad) yin
                    let asset_decimals: u8 = asset.decimals();
                    let transmute_amt: u128 = real_transmute_amt * pow(10, asset_decimals);

                    let mut transmute_fees_copy = transmute_fees;
                    let mut expected_wad_transmuted_amts_copy = expected_wad_transmuted_amts;

                    loop {
                        match transmute_fees_copy.pop_front() {
                            Option::Some(transmute_fee) => {
                                set_contract_address(shrine_utils::admin());
                                transmuter.set_transmute_fee(*transmute_fee);

                                set_contract_address(user);

                                // check preview
                                let preview: Wad = transmuter.preview_transmute(transmute_amt);
                                let expected: Wad = *expected_wad_transmuted_amts_copy
                                    .pop_front()
                                    .unwrap();
                                common::assert_equalish(
                                    preview,
                                    expected,
                                    (WAD_ONE / 100).into(), // error margin
                                    'wrong preview transmute amt'
                                );

                                // transmute
                                let expected_fee: Wad = transmute_amt_wad - preview;

                                let before_user_yin_bal: Wad = shrine.get_yin(user);
                                let before_total_yin: Wad = shrine.get_total_yin();
                                let before_total_transmuted: Wad = transmuter
                                    .get_total_transmuted();
                                let before_shrine_budget: SignedWad = shrine.get_budget();
                                let before_transmuter_asset_bal: u256 = asset
                                    .balance_of(transmuter.contract_address);

                                let expected_budget: SignedWad = before_shrine_budget
                                    + expected_fee.into();

                                transmuter.transmute(transmute_amt);
                                assert(
                                    shrine.get_yin(user) == before_user_yin_bal + preview,
                                    'wrong user yin'
                                );
                                assert(
                                    shrine.get_total_yin() == before_total_yin + preview,
                                    'wrong total yin'
                                );
                                assert(shrine.get_budget() == expected_budget, 'wrong budget');
                                assert(
                                    transmuter.get_total_transmuted() == before_total_transmuted
                                        + transmute_amt_wad,
                                    'wrong total transmuted'
                                );
                                assert(
                                    asset
                                        .balance_of(
                                            transmuter.contract_address
                                        ) == before_transmuter_asset_bal
                                        + transmute_amt.into(),
                                    'wrong transmuter asset bal'
                                );

                                let mut expected_events: Span<transmuter_contract::Event> = array![
                                    transmuter_contract::Event::Transmute(
                                        transmuter_contract::Transmute {
                                            user,
                                            asset_amt: transmute_amt,
                                            yin_amt: preview,
                                            fee: expected_fee
                                        }
                                    ),
                                ]
                                    .span();
                                common::assert_events_emitted(
                                    transmuter.contract_address, expected_events, Option::None
                                );
                            },
                            Option::None => { break; }
                        };
                    };
                },
                Option::None => { break; },
            };
        };
    }

    //
    // Tests - Reverse
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_reverse_with_preview_parametrized() {
        let (shrine, wad_transmuter, _) =
            transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter();
        let mock_nonwad_usd_stable = transmuter_utils::mock_nonwad_usd_stable_deploy();
        let nonwad_transmuter = transmuter_utils::transmuter_deploy(
            shrine.contract_address,
            mock_nonwad_usd_stable.contract_address,
            transmuter_utils::receiver(),
        );

        let mut transmuters: Span<ITransmuterDispatcher> = array![wad_transmuter, nonwad_transmuter]
            .span();

        let reverse_fees: Span<Ray> = array![
            RayZeroable::zero(), // 0%
            1_u128.into(), // 1E-27 %
            1000000000000000000000000_u128.into(), // 0.1%
            2345000000000000000000000_u128.into(), // 0.2345
            10000000000000000000000000_u128.into(), // 1% 
        ]
            .span();

        let real_reverse_amt: u128 = 1000;
        let reverse_yin_amt: Wad = (real_reverse_amt * WAD_ONE).into();

        let user: ContractAddress = transmuter_utils::user();

        loop {
            match transmuters.pop_front() {
                Option::Some(transmuter) => {
                    let transmuter = *transmuter;
                    let asset = IERC20Dispatcher { contract_address: transmuter.get_asset() };

                    // approve Transmuter to transfer user's mock USD stable
                    set_contract_address(user);
                    asset.approve(transmuter.contract_address, BoundedInt::max());

                    // Transmute an amount of yin to set up Transmuter for reverse
                    let asset_decimals: u8 = asset.decimals();
                    let real_transmute_amt: u128 = reverse_fees.len().into() * real_reverse_amt;
                    let asset_decimal_scale: u128 = pow(10, asset_decimals);
                    let transmute_amt: u128 = real_transmute_amt * asset_decimal_scale;
                    transmuter.transmute(transmute_amt);

                    let mut expected_reversed_asset_amts: Span<u128> = array![
                        wadray::wad_to_fixed_point(reverse_yin_amt, asset_decimals)
                            .into(), // 0% fee, 1000
                        wadray::wad_to_fixed_point(reverse_yin_amt, asset_decimals)
                            .into(), // 1E-27% fee (loss of precision), 1000
                        wadray::wad_to_fixed_point(
                            reverse_yin_amt - WAD_ONE.into(), asset_decimals
                        ), // 0.1% fee, 999.00
                        wadray::wad_to_fixed_point(
                            reverse_yin_amt - 2345000000000000000_u128.into(), asset_decimals
                        ), // 0.2345% fee, 997.655...
                        wadray::wad_to_fixed_point(
                            reverse_yin_amt - (10 * WAD_ONE).into(), asset_decimals
                        ), // 1% fee, 990.00
                    ]
                        .span();

                    let mut cumulative_asset_fees: u128 = 0;
                    let mut reverse_fees_copy = reverse_fees;
                    loop {
                        match reverse_fees_copy.pop_front() {
                            Option::Some(reverse_fee) => {
                                set_contract_address(shrine_utils::admin());
                                transmuter.set_reverse_fee(*reverse_fee);

                                set_contract_address(user);

                                // check preview
                                let preview: u128 = transmuter.preview_reverse(reverse_yin_amt);
                                let expected: u128 = *expected_reversed_asset_amts
                                    .pop_front()
                                    .unwrap();
                                common::assert_equalish(
                                    preview,
                                    expected,
                                    (asset_decimal_scale / 100), // error margin
                                    'wrong preview reverse amt'
                                );

                                // transmute
                                let expected_fee: Wad = wadray::rmul_rw(
                                    *reverse_fee, reverse_yin_amt
                                );

                                let before_user_yin_bal: Wad = shrine.get_yin(user);
                                let before_total_yin: Wad = shrine.get_total_yin();
                                let before_total_transmuted: Wad = transmuter
                                    .get_total_transmuted();
                                let before_shrine_budget: SignedWad = shrine.get_budget();
                                let before_transmuter_asset_bal: u256 = asset
                                    .balance_of(transmuter.contract_address);

                                let expected_budget: SignedWad = before_shrine_budget
                                    + expected_fee.into();

                                transmuter.reverse(reverse_yin_amt);
                                assert(
                                    shrine.get_yin(user) == before_user_yin_bal - reverse_yin_amt,
                                    'wrong user yin'
                                );
                                assert(
                                    shrine.get_total_yin() == before_total_yin - reverse_yin_amt,
                                    'wrong total yin'
                                );
                                assert(shrine.get_budget() == expected_budget, 'wrong budget');
                                assert(
                                    transmuter.get_total_transmuted() == before_total_transmuted
                                        - reverse_yin_amt,
                                    'wrong total transmuted'
                                );
                                assert(
                                    asset
                                        .balance_of(
                                            transmuter.contract_address
                                        ) == before_transmuter_asset_bal
                                        - preview.into(),
                                    'wrong transmuter asset bal'
                                );

                                let mut expected_events: Span<transmuter_contract::Event> = array![
                                    transmuter_contract::Event::Reverse(
                                        transmuter_contract::Reverse {
                                            user,
                                            asset_amt: preview,
                                            yin_amt: reverse_yin_amt,
                                            fee: expected_fee
                                        }
                                    ),
                                ]
                                    .span();
                                common::assert_events_emitted(
                                    transmuter.contract_address, expected_events, Option::None
                                );

                                cumulative_asset_fees += (real_reverse_amt * asset_decimal_scale)
                                    - preview;
                            },
                            Option::None => { break; }
                        };
                    };

                    assert(
                        asset
                            .balance_of(transmuter.contract_address) == cumulative_asset_fees
                            .into(),
                        'wrong cumulative asset fees'
                    );
                },
                Option::None => { break; },
            };
        };
    }
// Transmute fails when debt ceiling in shrine is reached
// Transmute fails when transmuter ceiling is reached
// Transmute fails when percentage cap is reached.

// Reverse fails when transmuter has no assets
// Reverse fails when reversibility is disallowed
}
