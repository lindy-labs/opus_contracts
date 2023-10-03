mod TestEqualizer {
    use starknet::{ContractAddress, get_block_timestamp};
    use starknet::testing::{set_block_timestamp, set_contract_address};

    use opus::core::equalizer::Equalizer;
    use opus::core::roles::EqualizerRoles;
    use opus::core::shrine::Shrine;

    use opus::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use opus::interfaces::IEqualizer::{IEqualizerDispatcher, IEqualizerDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::utils::wadray;
    use opus::utils::wadray::{Ray, Wad, WadZeroable};

    use opus::tests::equalizer::utils::EqualizerUtils;
    use opus::tests::shrine::utils::ShrineUtils;
    use opus::tests::common;

    #[test]
    #[available_gas(20000000000)]
    fn test_equalizer_deploy() {
        let (shrine, equalizer, allocator) = EqualizerUtils::equalizer_deploy();

        assert(equalizer.get_allocator() == allocator.contract_address, 'wrong allocator address');

        let equalizer_ac = IAccessControlDispatcher {
            contract_address: equalizer.contract_address
        };
        let admin = ShrineUtils::admin();
        assert(equalizer_ac.get_admin() == admin, 'wrong admin');
        assert(equalizer_ac.get_roles(admin) == EqualizerRoles::SET_ALLOCATOR, 'wrong role');
        assert(equalizer_ac.has_role(EqualizerRoles::SET_ALLOCATOR, admin), 'role not granted');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_equalize_pass() {
        let (shrine, equalizer, allocator) = EqualizerUtils::equalizer_deploy();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        let before_total_yin = shrine.get_total_yin();

        // Advance by 365 days * 24 hours * 2 intervals per hour = 17520 intervals so that some
        // interest accrues
        let mut timestamp = get_block_timestamp();
        timestamp += (365 * 24 * 2) * Shrine::TIME_INTERVAL;
        set_block_timestamp(timestamp);

        // Set the price to make the interest calculation easier
        ShrineUtils::advance_prices_and_set_multiplier(
            shrine, 1, ShrineUtils::three_yang_addrs(), ShrineUtils::three_yang_start_prices(),
        );

        // Charge trove 1 and sanity check that some debt has accrued
        ShrineUtils::trove1_deposit(shrine, WadZeroable::zero());

        let surplus: Wad = equalizer.get_surplus();
        assert(surplus > WadZeroable::zero(), 'no surplus accrued');

        let recipients = EqualizerUtils::initial_recipients();
        let percentages = EqualizerUtils::initial_percentages();

        let mut tokens: Array<ContractAddress> = array![shrine.contract_address];
        let mut before_balances = common::get_token_balances(tokens.span(), recipients);
        let mut before_yin_balances = *before_balances.pop_front().unwrap();

        set_contract_address(ShrineUtils::admin());
        let minted_surplus = equalizer.equalize();

        let mut after_balances = common::get_token_balances(tokens.span(), recipients);
        let mut after_yin_balances = *after_balances.pop_front().unwrap();

        let mut tmp_minted_surplus = WadZeroable::zero();
        let mut percentages_copy = percentages;
        loop {
            match percentages_copy.pop_front() {
                Option::Some(percentage) => {
                    let expected_increment = wadray::rmul_rw(*percentage, surplus);
                    // sanity check
                    assert(expected_increment.is_non_zero(), 'increment is zero');

                    let before_yin_bal = *before_yin_balances.pop_front().unwrap();
                    let after_yin_bal = *after_yin_balances.pop_front().unwrap();
                    assert(
                        after_yin_bal == before_yin_bal + expected_increment.val,
                        'wrong recipient balance'
                    );

                    tmp_minted_surplus += expected_increment;
                },
                Option::None => { break; }
            };
        };
        assert(minted_surplus == tmp_minted_surplus, 'surplus mismatch');

        // Check remaining surplus due to precision loss
        let remaining_surplus = surplus - minted_surplus;
        assert(equalizer.get_surplus() == remaining_surplus, 'wrong remaining surplus');

        assert(shrine.get_total_yin() == before_total_yin + minted_surplus, 'wrong total yin');

        let yangs: Span<ContractAddress> = ShrineUtils::three_yang_addrs();
        ShrineUtils::assert_total_debt_invariant(shrine, yangs, 1);

        let mut expected_events: Span<Equalizer::Event> = array![
            Equalizer::Event::Equalize(
                Equalizer::Equalize { recipients, percentages, amount: minted_surplus }
            ),
        ]
            .span();
        common::assert_events_emitted(equalizer.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_allocator_pass() {
        let (shrine, equalizer, allocator) = EqualizerUtils::equalizer_deploy();
        let new_recipients = EqualizerUtils::new_recipients();
        let mut new_percentages = EqualizerUtils::new_percentages();
        let new_allocator = EqualizerUtils::allocator_deploy(new_recipients, new_percentages);

        set_contract_address(ShrineUtils::admin());
        equalizer.set_allocator(new_allocator.contract_address);

        // Check allocator is updated
        assert(
            equalizer.get_allocator() == new_allocator.contract_address, 'allocator not updated'
        );

        let mut expected_events: Span<Equalizer::Event> = array![
            Equalizer::Event::AllocatorUpdated(
                Equalizer::AllocatorUpdated {
                    old_address: allocator.contract_address,
                    new_address: new_allocator.contract_address
                }
            ),
        ]
            .span();
        common::assert_events_emitted(equalizer.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_allocator_fail() {
        let (_, equalizer, _) = EqualizerUtils::equalizer_deploy();
        let new_allocator = EqualizerUtils::allocator_deploy(
            EqualizerUtils::new_recipients(), EqualizerUtils::new_percentages()
        );

        set_contract_address(common::badguy());
        equalizer.set_allocator(new_allocator.contract_address);
    }
}
