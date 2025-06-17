mod test_tcr_allocator {
    use opus::core::allocators::tcr_allocator::tcr_allocator as tcr_allocator_contract;
    use opus::interfaces::IAllocator::IAllocatorDispatcherTrait;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::equalizer::utils::equalizer_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::Health;
    use snforge_std::{start_cheat_caller_address, stop_cheat_caller_address};
    use starknet::ContractAddress;
    use wadray::{RAY_PERCENT, Ray, WAD_ONE, Wad};

    const MOCK_ABSORBER: ContractAddress = 'mock absorber'.try_into().unwrap();
    const MOCK_STABILIZER: ContractAddress = 'mock stabilizer'.try_into().unwrap();

    fn initial_tcr_recipients() -> Span<ContractAddress> {
        array![shrine_utils::ADMIN, MOCK_ABSORBER, MOCK_STABILIZER].span()
    }

    #[test]
    fn test_tcr_allocator_recovery_mode() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let allocator = equalizer_utils::tcr_allocator_deploy(
            shrine.contract_address, MOCK_ABSORBER, MOCK_STABILIZER, Option::None,
        );

        // Trove 1 deposits 10,000 USD worth, and borrows 3,000 USD
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine_utils::trove1_forge(shrine, shrine_utils::TROVE1_FORGE_AMT.into());

        shrine_utils::recovery_mode_test_setup(
            shrine, shrine_utils::three_yang_addrs(), common::RecoveryModeSetupType::BufferLowerBound,
        );

        let expected_recipients = initial_tcr_recipients();

        let (recipients, percentages) = allocator.get_allocation();

        assert_eq!(recipients, expected_recipients, "wrong recipients");
        assert_eq!(recipients.len(), 3, "wrong array length");

        assert!(shrine.is_recovery_mode(), "not recovery mode");
        let expected_percentages: Span<Ray> = array![
            tcr_allocator_contract::ADMIN_FEE_RECIPIENT_PCT.into(),
            tcr_allocator_contract::MAX_ADJUSTABLE_PCT.into(),
            tcr_allocator_contract::MIN_ADJUSTABLE_PCT.into(),
        ]
            .span();

        assert_eq!(percentages, expected_percentages, "wrong percentages");

        equalizer_utils::sums_to_one(percentages);
    }

    #[test]
    fn test_tcr_allocator_above_adjustment_threshold() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let allocator = equalizer_utils::tcr_allocator_deploy(
            shrine.contract_address, MOCK_ABSORBER, MOCK_STABILIZER, Option::None,
        );

        shrine_utils::create_whale_trove(shrine);

        let expected_recipients = initial_tcr_recipients();

        let (recipients, percentages) = allocator.get_allocation();

        assert_eq!(recipients, expected_recipients, "wrong recipients");
        assert_eq!(recipients.len(), 3, "wrong array length");

        assert!(!shrine.is_recovery_mode(), "recovery mode");
        let expected_percentages: Span<Ray> = array![
            tcr_allocator_contract::ADMIN_FEE_RECIPIENT_PCT.into(),
            tcr_allocator_contract::MIN_ADJUSTABLE_PCT.into(),
            tcr_allocator_contract::MAX_ADJUSTABLE_PCT.into(),
        ]
            .span();

        assert_eq!(percentages, expected_percentages, "wrong percentages");

        equalizer_utils::sums_to_one(percentages);
    }

    #[test]
    fn test_tcr_allocator_adjustments() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let allocator = equalizer_utils::tcr_allocator_deploy(
            shrine.contract_address, MOCK_ABSORBER, MOCK_STABILIZER, Option::None,
        );

        // Trove 1 deposits 10,000 USD worth, and borrows 3,000 USD
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine_utils::trove1_forge(shrine, shrine_utils::TROVE1_FORGE_AMT.into());

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.set_recovery_mode_target_factor((80 * RAY_PERCENT).into());
        stop_cheat_caller_address(shrine.contract_address);

        // At 80% threshold, and a recovery mode target factor of 80%,
        //the recovery mode LTV is 64%, and the adjustment LTV is 48%.
        // Therefore, we check three different LTVs between 48% and 64%: 50%, 54.54..%, 60%
        let target_yang1_prices: Span<Wad> = array![
            (1200 * WAD_ONE).into(), (1091 * WAD_ONE).into(), (1000 * WAD_ONE).into(),
        ]
            .span();
        let mut target_ltvs: Span<Ray> = array![
            (50 * RAY_PERCENT).into(), (55 * RAY_PERCENT).into(), (60 * RAY_PERCENT).into(),
        ]
            .span();

        let mut expected_percentages_arrs: Span<Span<Ray>> = array![
            array![
                tcr_allocator_contract::ADMIN_FEE_RECIPIENT_PCT.into(),
                (25 * RAY_PERCENT).into(),
                (55 * RAY_PERCENT).into(),
            ]
                .span(),
            array![
                tcr_allocator_contract::ADMIN_FEE_RECIPIENT_PCT.into(),
                (37 * RAY_PERCENT + RAY_PERCENT / 2).into(),
                (42 * RAY_PERCENT + RAY_PERCENT / 2).into(),
            ]
                .span(),
            array![
                tcr_allocator_contract::ADMIN_FEE_RECIPIENT_PCT.into(),
                (50 * RAY_PERCENT).into(),
                (30 * RAY_PERCENT).into(),
            ]
                .span(),
        ]
            .span();

        let expected_recipients = initial_tcr_recipients();
        let error_margin: Ray = (RAY_PERCENT / 2).into();

        for target_yang1_price in target_yang1_prices {
            start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
            shrine.advance(shrine_utils::YANG1_ADDR, *target_yang1_price);
            stop_cheat_caller_address(shrine.contract_address);

            let shrine_health: Health = shrine.get_shrine_health();
            let target_ltv: Ray = *target_ltvs.pop_front().unwrap();
            common::assert_equalish(shrine_health.ltv, target_ltv, error_margin, 'wrong target ltv');

            let (recipients, percentages) = allocator.get_allocation();
            assert_eq!(recipients, expected_recipients, "wrong recipients");
            assert_eq!(recipients.len(), 3, "wrong array length");

            assert!(!shrine.is_recovery_mode(), "recovery mode");
            let expected_percentages: Span<Ray> = *expected_percentages_arrs.pop_front().unwrap();

            let absorber_pct = *percentages[1];
            let expected_absorber_pct = *expected_percentages[1];
            common::assert_equalish(absorber_pct, expected_absorber_pct, error_margin, 'wrong absorber pct');

            let stabilizer_pct = *percentages[2];
            let expected_stabilizer_pct = *expected_percentages[2];
            common::assert_equalish(stabilizer_pct, expected_stabilizer_pct, error_margin, 'wrong stabilizer pct');

            equalizer_utils::sums_to_one(percentages);
        }
    }
}
