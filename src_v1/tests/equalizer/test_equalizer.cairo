#[cfg(test)]
mod TestEqualizer {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::{ContractAddress, get_block_timestamp};
    use starknet::testing::{set_block_timestamp, set_contract_address};
    use traits::{Default, Into};
    use zeroable::Zeroable;

    use aura::core::roles::EqualizerRoles;
    use aura::core::shrine::Shrine;

    use aura::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use aura::interfaces::IEqualizer::{IEqualizerDispatcher, IEqualizerDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, Wad, WadZeroable};

    use aura::tests::equalizer::utils::EqualizerUtils;
    use aura::tests::shrine::utils::ShrineUtils;
    use aura::tests::common;

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
            shrine, 1, ShrineUtils::YANG1_START_PRICE.into(), ShrineUtils::YANG2_START_PRICE.into(), ShrineUtils::YANG3_START_PRICE.into()
        );

        // Charge trove 1 and sanity check that some debt has accrued
        ShrineUtils::trove1_deposit(shrine, WadZeroable::zero());

        let surplus: Wad = equalizer.get_surplus();
        assert(surplus > WadZeroable::zero(), 'no surplus accrued');

        let recipients = EqualizerUtils::initial_recipients();
        let mut percentages = EqualizerUtils::initial_percentages();

        let mut tokens: Array<ContractAddress> = Default::default();
        tokens.append(shrine.contract_address);
        let mut before_balances = common::get_token_balances(tokens.span(), recipients);
        let mut before_yin_balances = *before_balances.pop_front().unwrap();

        set_contract_address(ShrineUtils::admin());
        equalizer.equalize();

        let mut after_balances = common::get_token_balances(tokens.span(), recipients);
        let mut after_yin_balances = *after_balances.pop_front().unwrap();

        let mut minted_surplus = WadZeroable::zero();
        loop {
            match percentages.pop_front() {
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

                    minted_surplus += expected_increment;
                },
                Option::None(_) => {
                    break;
                }
            };
        };

        // Check remaining surplus due to precision loss
        let remaining_surplus = surplus - minted_surplus;
        assert(equalizer.get_surplus() == remaining_surplus, 'wrong remaining surplus');

        assert(shrine.get_total_yin() == before_total_yin + minted_surplus, 'wrong total yin');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_allocator_pass() {
        let (shrine, equalizer, _) = EqualizerUtils::equalizer_deploy();
        let new_recipients = EqualizerUtils::new_recipients();
        let mut new_percentages = EqualizerUtils::new_percentages();
        let new_allocator = EqualizerUtils::allocator_deploy(new_recipients, new_percentages);

        set_contract_address(ShrineUtils::admin());
        equalizer.set_allocator(new_allocator.contract_address);

        // Check allocator is updated
        assert(
            equalizer.get_allocator() == new_allocator.contract_address, 'allocator not updated'
        );
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
