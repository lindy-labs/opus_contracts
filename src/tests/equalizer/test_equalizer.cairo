mod test_equalizer {
    use cmp::min;
    use debug::PrintTrait;
    use integer::BoundedU128;
    use starknet::{ContractAddress, get_block_timestamp};
    use starknet::testing::{set_block_timestamp, set_contract_address};

    use opus::core::equalizer::equalizer as equalizer_contract;
    use opus::core::roles::equalizer_roles;
    use opus::core::shrine::shrine;

    use opus::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use opus::interfaces::IEqualizer::{IEqualizerDispatcher, IEqualizerDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::utils::wadray;
    use opus::utils::wadray::{Ray, Wad, WadZeroable, WAD_ONE};

    use opus::tests::equalizer::utils::equalizer_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::tests::common;

    #[test]
    #[available_gas(20000000000)]
    fn test_equalizer_deploy() {
        let (shrine, equalizer, allocator) = equalizer_utils::equalizer_deploy();

        assert(equalizer.get_allocator() == allocator.contract_address, 'wrong allocator address');

        let equalizer_ac = IAccessControlDispatcher {
            contract_address: equalizer.contract_address
        };
        let admin = shrine_utils::admin();
        assert(equalizer_ac.get_admin() == admin, 'wrong admin');
        assert(equalizer_ac.get_roles(admin) == equalizer_roles::SET_ALLOCATOR, 'wrong role');
        assert(equalizer_ac.has_role(equalizer_roles::SET_ALLOCATOR, admin), 'role not granted');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_equalize_pass() {
        let (shrine, equalizer, allocator) = equalizer_utils::equalizer_deploy();

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine_utils::trove1_forge(shrine, shrine_utils::TROVE1_FORGE_AMT.into());

        let before_total_yin = shrine.get_total_yin();

        // Advance by 365 days * 24 hours * 2 intervals per hour = 17520 intervals so that some
        // interest accrues
        let mut timestamp = get_block_timestamp();
        timestamp += (365 * 24 * 2) * shrine::TIME_INTERVAL;
        set_block_timestamp(timestamp);

        // Set the price to make the interest calculation easier
        shrine_utils::advance_prices_and_set_multiplier(
            shrine, 1, shrine_utils::three_yang_addrs(), shrine_utils::three_yang_start_prices(),
        );

        // Charge trove 1 and sanity check that some debt has accrued
        shrine_utils::trove1_deposit(shrine, WadZeroable::zero());

        let surplus: Wad = shrine.get_surplus_debt();
        assert(surplus > WadZeroable::zero(), 'no surplus accrued');

        let before_equalizer_yin: Wad = shrine.get_yin(equalizer.contract_address);

        let minted_surplus = equalizer.equalize();
        assert(surplus == minted_surplus, 'surplus mismatch');

        let after_equalizer_yin: Wad = shrine.get_yin(equalizer.contract_address);
        assert(after_equalizer_yin == before_equalizer_yin + surplus, 'surplus not received');

        // Check remaining surplus
        assert(shrine.get_surplus_debt().is_zero(), 'surplus should be zeroed');

        assert(shrine.get_total_yin() == before_total_yin + minted_surplus, 'wrong total yin');

        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs();
        shrine_utils::assert_total_debt_invariant(shrine, yangs, 1);

        let mut expected_events: Span<equalizer_contract::Event> = array![
            equalizer_contract::Event::Equalize(equalizer_contract::Equalize { yin_amt: surplus }),
        ]
            .span();
        common::assert_events_emitted(equalizer.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_allocate_pass() {
        let (shrine, equalizer, allocator) = equalizer_utils::equalizer_deploy();

        // Simulate minted surplus by injecting to Equalizer directly
        set_contract_address(shrine_utils::admin());
        let surplus: Wad = (1000 * WAD_ONE + 123).into();
        shrine.inject(equalizer.contract_address, surplus);

        let recipients = equalizer_utils::initial_recipients();
        let percentages = equalizer_utils::initial_percentages();

        let mut tokens: Array<ContractAddress> = array![shrine.contract_address];
        let mut before_balances = common::get_token_balances(tokens.span(), recipients);
        let mut before_yin_balances = *before_balances.pop_front().unwrap();

        equalizer.allocate();

        let mut after_balances = common::get_token_balances(tokens.span(), recipients);
        let mut after_yin_balances = *after_balances.pop_front().unwrap();

        let mut allocated = WadZeroable::zero();
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

                    allocated += expected_increment;
                },
                Option::None => { break; }
            };
        };
        assert(
            surplus == allocated + shrine.get_yin(equalizer.contract_address), 'allocated mismatch'
        );

        let mut expected_events: Span<equalizer_contract::Event> = array![
            equalizer_contract::Event::Allocate(
                equalizer_contract::Allocate { recipients, percentages, amount: allocated }
            ),
        ]
            .span();
        common::assert_events_emitted(equalizer.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_allocate_zero_amount_pass() {
        let (shrine, equalizer, _) = equalizer_utils::equalizer_deploy();

        assert(shrine.get_yin(equalizer.contract_address).is_zero(), 'sanity check');

        equalizer.allocate();
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_incur_pass() {
        let (_, equalizer, _) = equalizer_utils::equalizer_deploy();

        let before_deficit: Wad = equalizer.get_deficit();
        let deficit_increment: Wad = (5000 * WAD_ONE).into();

        common::drop_all_events(equalizer.contract_address);

        let admin: ContractAddress = shrine_utils::admin();
        set_contract_address(admin);
        equalizer.incur(deficit_increment);

        assert(equalizer.get_deficit() == before_deficit + deficit_increment, 'wrong deficit');

        let mut expected_events: Span<equalizer_contract::Event> = array![
            equalizer_contract::Event::Incur(
                equalizer_contract::Incur { defaulter: admin, deficit: deficit_increment }
            ),
        ]
            .span();
        common::assert_events_emitted(equalizer.contract_address, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_normalize_pass() {
        let (shrine, equalizer, _) = equalizer_utils::equalizer_deploy();

        let deficit: Wad = (5000 * WAD_ONE).into();
        let mut normalize_amts: Span<Wad> = array![
            WadZeroable::zero(),
            (deficit.val - 1).into(),
            deficit,
            (deficit.val + 1).into(), // exceeds deficit, but should be capped in `normalize`
        ]
            .span();

        let admin: ContractAddress = shrine_utils::admin();
        set_contract_address(admin);

        loop {
            match normalize_amts.pop_front() {
                Option::Some(normalize_amt) => {
                    // Create the deficit
                    equalizer.incur(deficit);
                    assert(equalizer.get_deficit() == deficit, 'sanity check #1');

                    // Mint the deficit amount to the admin
                    shrine.inject(admin, deficit);

                    common::drop_all_events(equalizer.contract_address);

                    equalizer.normalize(*normalize_amt);

                    let expected_normalized_amt: Wad = min(deficit, *normalize_amt);
                    assert(
                        equalizer.get_deficit() == deficit - expected_normalized_amt,
                        'wrong remaining deficit'
                    );

                    // Event is emitted only if non-zero amount of deficit was wiped
                    if expected_normalized_amt.is_non_zero() {
                        let mut expected_events: Span<equalizer_contract::Event> = array![
                            equalizer_contract::Event::Normalize(
                                equalizer_contract::Normalize {
                                    caller: admin, yin_amt: expected_normalized_amt
                                }
                            ),
                        ]
                            .span();
                        common::assert_events_emitted(
                            equalizer.contract_address, expected_events, Option::None
                        );
                    }

                    // Reset by normalizing all remaining deficit
                    equalizer.normalize(BoundedU128::max().into());

                    assert(equalizer.get_deficit().is_zero(), 'sanity check #2');
                },
                Option::None => { break; }
            };
        };
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_allocator_pass() {
        let (shrine, equalizer, allocator) = equalizer_utils::equalizer_deploy();
        let new_recipients = equalizer_utils::new_recipients();
        let mut new_percentages = equalizer_utils::new_percentages();
        let new_allocator = equalizer_utils::allocator_deploy(new_recipients, new_percentages);

        set_contract_address(shrine_utils::admin());
        equalizer.set_allocator(new_allocator.contract_address);

        // Check allocator is updated
        assert(
            equalizer.get_allocator() == new_allocator.contract_address, 'allocator not updated'
        );

        let mut expected_events: Span<equalizer_contract::Event> = array![
            equalizer_contract::Event::AllocatorUpdated(
                equalizer_contract::AllocatorUpdated {
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
        let (_, equalizer, _) = equalizer_utils::equalizer_deploy();
        let new_allocator = equalizer_utils::allocator_deploy(
            equalizer_utils::new_recipients(), equalizer_utils::new_percentages()
        );

        set_contract_address(common::badguy());
        equalizer.set_allocator(new_allocator.contract_address);
    }
}
