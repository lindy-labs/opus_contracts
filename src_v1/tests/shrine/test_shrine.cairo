#[cfg(test)]
mod TestShrine {
    use array::{ArrayTrait, SpanTrait};
    use debug::PrintTrait;
    use integer::BoundedU256;
    use option::OptionTrait;
    use traits::{Default, Into};
    use starknet::{contract_address_const, ContractAddress};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};
    use zeroable::Zeroable;

    use aura::core::shrine::Shrine;
    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::serde;
    use aura::utils::types::YangSuspensionStatus;
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{
        Ray, RayZeroable, RAY_ONE, RAY_SCALE, Wad, WadZeroable, WAD_DECIMALS, WAD_PERCENT, WAD_ONE, WAD_SCALE
    };

    use aura::tests::shrine::utils::ShrineUtils;
    use aura::tests::common;

    //
    // Tests - Deployment and initial setup of Shrine
    //

    // Check constructor function
    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_deploy() {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();

        // Check ERC-20 getters
        let yin: IERC20Dispatcher = IERC20Dispatcher { contract_address: shrine_addr };
        assert(yin.name() == ShrineUtils::YIN_NAME, 'wrong name');
        assert(yin.symbol() == ShrineUtils::YIN_SYMBOL, 'wrong symbol');
        assert(yin.decimals() == WAD_DECIMALS, 'wrong decimals');

        // Check Shrine getters
        let shrine = ShrineUtils::shrine(shrine_addr);
        assert(shrine.get_live(), 'not live');
        let (multiplier, _, _) = shrine.get_current_multiplier();
        assert(multiplier == RAY_ONE.into(), 'wrong multiplier');

        let admin: ContractAddress = ShrineUtils::admin();
        let shrine_accesscontrol: IAccessControlDispatcher = IAccessControlDispatcher {
            contract_address: shrine_addr
        };
        assert(shrine_accesscontrol.get_admin() == admin, 'wrong admin');
    }

    // Checks the following functions
    // - `set_ShrineUtils::DEBT_CEILING`
    // - `add_yang`
    // - initial threshold and value of Shrine
    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_setup() {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();
        ShrineUtils::shrine_setup(shrine_addr);

        // Check debt ceiling
        let shrine = ShrineUtils::shrine(shrine_addr);
        assert(shrine.get_debt_ceiling() == ShrineUtils::DEBT_CEILING.into(), 'wrong debt ceiling');

        // Check yangs
        assert(shrine.get_yangs_count() == 3, 'wrong yangs count');

        let expected_era: u64 = 1;

        let yang1_addr: ContractAddress = ShrineUtils::yang1_addr();
        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        assert(yang1_price == ShrineUtils::YANG1_START_PRICE.into(), 'wrong yang1 start price');
        assert(
            shrine.get_yang_threshold(yang1_addr) == ShrineUtils::YANG1_THRESHOLD.into(),
            'wrong yang1 threshold'
        );
        assert(
            shrine.get_yang_rate(yang1_addr, expected_era) == ShrineUtils::YANG1_BASE_RATE.into(),
            'wrong yang1 base rate'
        );

        let yang2_addr: ContractAddress = ShrineUtils::yang2_addr();
        let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr);
        assert(yang2_price == ShrineUtils::YANG2_START_PRICE.into(), 'wrong yang2 start price');
        assert(
            shrine.get_yang_threshold(yang2_addr) == ShrineUtils::YANG2_THRESHOLD.into(),
            'wrong yang2 threshold'
        );
        assert(
            shrine.get_yang_rate(yang2_addr, expected_era) == ShrineUtils::YANG2_BASE_RATE.into(),
            'wrong yang2 base rate'
        );

        // Check shrine threshold and value
        let (threshold, value) = shrine.get_shrine_threshold_and_value();
        assert(threshold.is_zero(), 'wrong shrine threshold');
        assert(value.is_zero(), 'wrong shrine value');
    }

    // Checks `advance` and `set_multiplier`, and their cumulative values
    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_setup_with_feed() {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();
        ShrineUtils::shrine_setup(shrine_addr);
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine_addr };
        let (yang_addrs, yang_feeds) = ShrineUtils::advance_prices_and_set_multiplier(
            shrine,
            ShrineUtils::FEED_LEN,
            ShrineUtils::YANG1_START_PRICE.into(),
            ShrineUtils::YANG2_START_PRICE.into(),
            ShrineUtils::YANG3_START_PRICE.into()
        );
        let mut yang_addrs = yang_addrs;
        let mut yang_feeds = yang_feeds;

        let shrine = ShrineUtils::shrine(shrine_addr);

        let mut exp_start_cumulative_prices: Array<Wad> = Default::default();
        exp_start_cumulative_prices.append(ShrineUtils::YANG1_START_PRICE.into());
        exp_start_cumulative_prices.append(ShrineUtils::YANG2_START_PRICE.into());
        exp_start_cumulative_prices.append(ShrineUtils::YANG3_START_PRICE.into());
        let mut exp_start_cumulative_prices = exp_start_cumulative_prices.span();

        let start_interval: u64 = ShrineUtils::get_interval(ShrineUtils::DEPLOYMENT_TIMESTAMP);
        loop {
            match yang_addrs.pop_front() {
                Option::Some(yang_addr) => {
                    // `Shrine.add_yang` sets the initial price for `current_interval - 1`
                    let (_, start_cumulative_price) = shrine
                        .get_yang_price(*yang_addr, start_interval - 1);
                    assert(
                        start_cumulative_price == *exp_start_cumulative_prices.pop_front().unwrap(),
                        'wrong start cumulative price'
                    );

                    let (_, start_cumulative_multiplier) = shrine
                        .get_multiplier(start_interval - 1);
                    assert(
                        start_cumulative_multiplier == Ray { val: RAY_SCALE },
                        'wrong start cumulative mul'
                    );

                    let mut yang_feed: Span<Wad> = *yang_feeds.pop_front().unwrap();
                    let yang_feed_len: usize = yang_feed.len();

                    let mut idx: usize = 0;
                    let mut expected_cumulative_price = start_cumulative_price;
                    let mut expected_cumulative_multiplier = start_cumulative_multiplier;
                    loop {
                        if idx == yang_feed_len {
                            break ();
                        }

                        let interval = start_interval + idx.into();
                        let (price, cumulative_price) = shrine.get_yang_price(*yang_addr, interval);
                        assert(price == *yang_feed[idx], 'wrong price in feed');

                        expected_cumulative_price += price;
                        assert(
                            cumulative_price == expected_cumulative_price,
                            'wrong cumulative price in feed'
                        );

                        expected_cumulative_multiplier += RAY_SCALE.into();
                        let (multiplier, cumulative_multiplier) = shrine.get_multiplier(interval);
                        assert(multiplier == Ray { val: RAY_SCALE }, 'wrong multiplier in feed');
                        assert(
                            cumulative_multiplier == expected_cumulative_multiplier,
                            'wrong cumulative mul in feed'
                        );

                        idx += 1;
                    };
                },
                Option::None(_) => {
                    break ();
                }
            };
        };
    }

    //
    // Tests - Yang onboarding and parameters
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_add_yang() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        let current_rate_era: u64 = shrine.get_current_rate_era();
        let yangs_count: u32 = shrine.get_yangs_count();
        assert(yangs_count == 3, 'incorrect yangs count');

        let new_yang_address: ContractAddress = contract_address_const::<0x9870>();
        let new_yang_threshold: Ray = 600000000000000000000000000_u128.into(); // 60% (Ray)
        let new_yang_start_price: Wad = 5000000000000000000_u128.into(); // 5 (Wad)
        let new_yang_rate: Ray = 60000000000000000000000000_u128.into(); // 6% (Ray)

        let admin = ShrineUtils::admin();
        set_contract_address(admin);
        shrine
            .add_yang(
                new_yang_address,
                new_yang_threshold,
                new_yang_start_price,
                new_yang_rate,
                WadZeroable::zero()
            );

        assert(shrine.get_yangs_count() == yangs_count + 1, 'incorrect yangs count');
        assert(
            shrine.get_yang_total(new_yang_address).is_zero(), 'incorrect yang total'
        );

        let (current_yang_price, _, _) = shrine.get_current_yang_price(new_yang_address);
        assert(current_yang_price == new_yang_start_price, 'incorrect yang price');
        assert(
            shrine.get_yang_threshold(new_yang_address) == new_yang_threshold,
            'incorrect yang threshold'
        );

        assert(
            shrine.get_yang_rate(new_yang_address, current_rate_era) == new_yang_rate,
            'incorrect yang rate'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_duplicate_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        set_contract_address(ShrineUtils::admin());
        shrine
            .add_yang(
                ShrineUtils::yang1_addr(),
                ShrineUtils::YANG1_THRESHOLD.into(),
                ShrineUtils::YANG1_START_PRICE.into(),
                ShrineUtils::YANG1_BASE_RATE.into(),
                WadZeroable::zero()
            );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_unauthorized() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        set_contract_address(common::badguy());
        shrine
            .add_yang(
                ShrineUtils::yang1_addr(),
                ShrineUtils::YANG1_THRESHOLD.into(),
                ShrineUtils::YANG1_START_PRICE.into(),
                ShrineUtils::YANG1_BASE_RATE.into(),
                WadZeroable::zero()
            );
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_threshold() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        let yang1_addr = ShrineUtils::yang1_addr();
        let new_threshold: Ray = 900000000000000000000000000_u128.into();

        set_contract_address(ShrineUtils::admin());
        shrine.set_threshold(yang1_addr, new_threshold);
        assert(shrine.get_yang_threshold(yang1_addr) == new_threshold, 'threshold not updated');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Threshold > max', 'ENTRYPOINT_FAILED'))]
    fn test_set_threshold_exceeds_max() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        let invalid_threshold: Ray = (RAY_SCALE + 1).into();

        set_contract_address(ShrineUtils::admin());
        shrine.set_threshold(ShrineUtils::yang1_addr(), invalid_threshold);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_threshold_unauthorized() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        let new_threshold: Ray = 900000000000000000000000000_u128.into();

        set_contract_address(common::badguy());
        shrine.set_threshold(ShrineUtils::yang1_addr(), new_threshold);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang does not exist', 'ENTRYPOINT_FAILED'))]
    fn test_set_threshold_invalid_yang() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        set_contract_address(ShrineUtils::admin());
        shrine.set_threshold(ShrineUtils::invalid_yang_addr(), ShrineUtils::YANG1_THRESHOLD.into());
    }

    //
    // Tests - Shrine kill
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_kill() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        assert(shrine.get_live(), 'should be live');

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);

        set_contract_address(ShrineUtils::admin());
        shrine.kill();

        // Check eject pass
        shrine.eject(common::trove1_owner_addr(), 1_u128.into());

        assert(!shrine.get_live(), 'should not be live');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: System is not live', 'ENTRYPOINT_FAILED'))]
    fn test_killed_deposit_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        assert(shrine.get_live(), 'should be live');

        set_contract_address(ShrineUtils::admin());
        shrine.kill();
        assert(!shrine.get_live(), 'should not be live');

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: System is not live', 'ENTRYPOINT_FAILED'))]
    fn test_killed_withdraw_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        assert(shrine.get_live(), 'should be live');
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        set_contract_address(ShrineUtils::admin());
        shrine.kill();
        assert(!shrine.get_live(), 'should not be live');

        ShrineUtils::trove1_withdraw(shrine, 1_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: System is not live', 'ENTRYPOINT_FAILED'))]
    fn test_killed_forge_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        assert(shrine.get_live(), 'should be live');
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        set_contract_address(ShrineUtils::admin());
        shrine.kill();
        assert(!shrine.get_live(), 'should not be live');

        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: System is not live', 'ENTRYPOINT_FAILED'))]
    fn test_killed_melt_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        assert(shrine.get_live(), 'should be live');
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        set_contract_address(ShrineUtils::admin());
        shrine.kill();
        assert(!shrine.get_live(), 'should not be live');

        ShrineUtils::trove1_melt(shrine, 1_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: System is not live', 'ENTRYPOINT_FAILED'))]
    fn test_killed_inject_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        assert(shrine.get_live(), 'should be live');

        set_contract_address(ShrineUtils::admin());
        shrine.kill();
        assert(!shrine.get_live(), 'should not be live');

        shrine.inject(ShrineUtils::admin(), 1_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_kill_unauthorized() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        assert(shrine.get_live(), 'should be live');

        set_contract_address(common::badguy());
        shrine.kill();
    }

    //
    // Tests - trove deposit
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_deposit_pass() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        let yang1_addr = ShrineUtils::yang1_addr();
        assert(
            shrine.get_yang_total(yang1_addr) == ShrineUtils::TROVE1_YANG1_DEPOSIT.into(),
            'incorrect yang total'
        );
        assert(
            shrine
                .get_deposit(yang1_addr, common::TROVE_1) == ShrineUtils::TROVE1_YANG1_DEPOSIT
                .into(),
            'incorrect yang deposit'
        );

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let max_forge_amt: Wad = shrine.get_max_forge(common::TROVE_1);

        let mut yang_prices: Array<Wad> = Default::default();
        yang_prices.append(yang1_price);

        let mut yang_amts: Array<Wad> = Default::default();
        yang_amts.append(ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        let mut yang_thresholds: Array<Ray> = Default::default();
        yang_thresholds.append(ShrineUtils::YANG1_THRESHOLD.into());

        let expected_max_forge: Wad = ShrineUtils::calculate_max_forge(
            yang_prices.span(), yang_amts.span(), yang_thresholds.span()
        );
        assert(max_forge_amt == expected_max_forge, 'incorrect max forge amt');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang does not exist', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_deposit_invalid_yang_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        set_contract_address(ShrineUtils::admin());

        shrine
            .deposit(
                ShrineUtils::invalid_yang_addr(),
                common::TROVE_1,
                ShrineUtils::TROVE1_YANG1_DEPOSIT.into()
            );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_deposit_unauthorized() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        set_contract_address(common::badguy());

        shrine
            .deposit(
                ShrineUtils::yang1_addr(),
                common::TROVE_1,
                ShrineUtils::TROVE1_YANG1_DEPOSIT.into()
            );
    }

    //
    // Tests - Trove withdraw
    //

    #[test]
    #[available_gas(1000000000000)]
    fn test_shrine_withdraw_pass() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        set_contract_address(ShrineUtils::admin());

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let withdraw_amt: Wad = (ShrineUtils::TROVE1_YANG1_DEPOSIT / 3).into();
        ShrineUtils::trove1_withdraw(shrine, withdraw_amt);

        let yang1_addr = ShrineUtils::yang1_addr();
        let remaining_amt: Wad = ShrineUtils::TROVE1_YANG1_DEPOSIT.into() - withdraw_amt;
        assert(shrine.get_yang_total(yang1_addr) == remaining_amt, 'incorrect yang total');
        assert(
            shrine.get_deposit(yang1_addr, common::TROVE_1) == remaining_amt,
            'incorrect yang deposit'
        );

        let (_, ltv, _, _) = shrine.get_trove_info(common::TROVE_1);
        assert(ltv.is_zero(), 'LTV should be zero');

        assert(shrine.is_healthy(common::TROVE_1), 'trove should be healthy');

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let max_forge_amt: Wad = shrine.get_max_forge(common::TROVE_1);

        let mut yang_prices: Array<Wad> = Default::default();
        yang_prices.append(yang1_price);

        let mut yang_amts: Array<Wad> = Default::default();
        yang_amts.append(remaining_amt);

        let mut yang_thresholds: Array<Ray> = Default::default();
        yang_thresholds.append(ShrineUtils::YANG1_THRESHOLD.into());

        let expected_max_forge: Wad = ShrineUtils::calculate_max_forge(
            yang_prices.span(), yang_amts.span(), yang_thresholds.span()
        );
        assert(max_forge_amt == expected_max_forge, 'incorrect max forge amt');
    }

    #[test]
    #[available_gas(1000000000000)]
    fn test_shrine_forged_partial_withdraw_pass() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        set_contract_address(ShrineUtils::admin());
        let withdraw_amt: Wad = (ShrineUtils::TROVE1_YANG1_DEPOSIT / 3).into();
        ShrineUtils::trove1_withdraw(shrine, withdraw_amt);

        let yang1_addr = ShrineUtils::yang1_addr();
        let remaining_amt: Wad = ShrineUtils::TROVE1_YANG1_DEPOSIT.into() - withdraw_amt;
        assert(shrine.get_yang_total(yang1_addr) == remaining_amt, 'incorrect yang total');
        assert(
            shrine.get_deposit(yang1_addr, common::TROVE_1) == remaining_amt,
            'incorrect yang deposit'
        );

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let expected_ltv: Ray = wadray::rdiv_ww(
            ShrineUtils::TROVE1_FORGE_AMT.into(), (yang1_price * remaining_amt)
        );
        let (_, ltv, _, _) = shrine.get_trove_info(common::TROVE_1);
        assert(ltv == expected_ltv, 'incorrect LTV');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang does not exist', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_withdraw_invalid_yang_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        set_contract_address(ShrineUtils::admin());

        shrine
            .withdraw(
                ShrineUtils::invalid_yang_addr(),
                common::TROVE_1,
                ShrineUtils::TROVE1_YANG1_DEPOSIT.into()
            );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_withdraw_unauthorized() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        set_contract_address(common::badguy());

        shrine
            .withdraw(
                ShrineUtils::yang1_addr(),
                common::TROVE_1,
                ShrineUtils::TROVE1_YANG1_DEPOSIT.into()
            );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_withdraw_insufficient_yang_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        set_contract_address(ShrineUtils::admin());

        shrine
            .withdraw(
                ShrineUtils::yang1_addr(),
                common::TROVE_1,
                (ShrineUtils::TROVE1_YANG1_DEPOSIT + 1).into()
            );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_withdraw_zero_yang_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        set_contract_address(ShrineUtils::admin());

        shrine
            .withdraw(
                ShrineUtils::yang2_addr(),
                common::TROVE_1,
                (ShrineUtils::TROVE1_YANG1_DEPOSIT + 1).into()
            );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Trove LTV is too high', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_withdraw_unsafe_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        let (threshold, _, trove_value, debt) = shrine.get_trove_info(common::TROVE_1);
        let (yang1_price, _, _) = shrine.get_current_yang_price(ShrineUtils::yang1_addr());

        // Value of trove needed for existing forged amount to be safe
        let unsafe_trove_value: Wad = wadray::rdiv_wr(
            ShrineUtils::TROVE1_FORGE_AMT.into(), threshold
        );
        // Amount of yang to be withdrawn to decrease the trove's value to unsafe
        // `WAD_SCALE` is added to account for loss of precision from fixed point division
        let unsafe_withdraw_yang_amt: Wad = (trove_value - unsafe_trove_value) / yang1_price + WAD_SCALE.into();
        set_contract_address(ShrineUtils::admin());
        shrine.withdraw(ShrineUtils::yang1_addr(), common::TROVE_1, unsafe_withdraw_yang_amt);
    }

    //
    // Tests - Trove forge
    //

    #[test]
    #[available_gas(1000000000000)]
    fn test_shrine_forge_pass() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();

        let before_max_forge_amt: Wad = shrine.get_max_forge(common::TROVE_1);
        ShrineUtils::trove1_forge(shrine, forge_amt);

        assert(shrine.get_total_debt() == forge_amt, 'incorrect system debt');

        let (_, ltv, _, debt) = shrine.get_trove_info(common::TROVE_1);
        assert(debt == forge_amt, 'incorrect trove debt');

        let (yang1_price, _, _) = shrine.get_current_yang_price(ShrineUtils::yang1_addr());
        let expected_value: Wad = yang1_price * ShrineUtils::TROVE1_YANG1_DEPOSIT.into();
        let expected_ltv: Ray = wadray::rdiv_ww(forge_amt, expected_value);
        assert(ltv == expected_ltv, 'incorrect ltv');

        assert(shrine.is_healthy(common::TROVE_1), 'trove should be healthy');

        let after_max_forge_amt: Wad = shrine.get_max_forge(common::TROVE_1);
        assert(after_max_forge_amt == before_max_forge_amt - forge_amt, 'incorrect max forge amt');

        let yin = ShrineUtils::yin(shrine.contract_address);
        assert(
            yin.balance_of(common::trove1_owner_addr()) == forge_amt.into(),
            'incorrect ERC-20 balance'
        );
        assert(yin.total_supply() == forge_amt.val.into(), 'incorrect ERC-20 balance');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Trove LTV is too high', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_forge_zero_deposit_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        set_contract_address(ShrineUtils::admin());

        shrine.forge(ShrineUtils::common::trove3_owner_addr(), common::TROVE_3, 1_u128.into(), 0_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Trove LTV is too high', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_forge_unsafe_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        let max_forge_amt: Wad = shrine.get_max_forge(common::TROVE_1);
        let unsafe_forge_amt: Wad = (max_forge_amt.val + 1).into();

        set_contract_address(ShrineUtils::admin());
        shrine.forge(common::trove1_owner_addr(), common::TROVE_1, unsafe_forge_amt, 0_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Debt ceiling reached', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_forge_ceiling_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        set_contract_address(ShrineUtils::admin());

        // deposit more collateral
        let additional_yang1_amt: Wad = (ShrineUtils::TROVE1_YANG1_DEPOSIT * 10).into();
        shrine.deposit(ShrineUtils::yang1_addr(), common::TROVE_1, additional_yang1_amt);

        let unsafe_amt: Wad = (ShrineUtils::TROVE1_FORGE_AMT * 10).into();
        shrine.forge(common::trove1_owner_addr(), common::TROVE_1, unsafe_amt, 0_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_forge_unauthorized() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        set_contract_address(common::badguy());

        shrine
            .forge(
                common::trove1_owner_addr(),
                common::TROVE_1,
                ShrineUtils::TROVE1_FORGE_AMT.into(),
                0_u128.into(),
            );
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_forge_nonzero_forge_fee() {
        let yin_price1: Wad = 980000000000000000_u128.into(); // 0.98 (wad)
        let yin_price2: Wad = 985000000000000000_u128.into(); // 0.985 (wad)
        let forge_amt: Wad = 100000000000000000000_u128.into(); // 100 (wad)
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        let trove1_owner: ContractAddress = common::trove1_owner_addr();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        set_contract_address(ShrineUtils::admin());

        let before_max_forge_amt: Wad = shrine.get_max_forge(common::TROVE_1);
        shrine.update_yin_spot_price(yin_price1);
        let after_max_forge_amt: Wad = shrine.get_max_forge(common::TROVE_1);

        let fee_pct: Wad = shrine.get_forge_fee_pct();

        assert(after_max_forge_amt == before_max_forge_amt / (WAD_ONE.into() + fee_pct), 'incorrect max forge amt');

        shrine.forge(trove1_owner, common::TROVE_1, forge_amt, fee_pct);

        let (_, _, _, debt) = shrine.get_trove_info(common::TROVE_1);
        assert(debt - forge_amt == fee_pct * forge_amt, 'wrong forge fee charged #1');

        shrine.update_yin_spot_price(yin_price2);
        let fee_pct: Wad = shrine.get_forge_fee_pct();
        shrine.forge(trove1_owner, common::TROVE_1, forge_amt, fee_pct);

        let (_, _, _, new_debt) = shrine.get_trove_info(common::TROVE_1);
        assert(new_debt - debt - forge_amt == fee_pct * forge_amt, 'wrong forge fee charged #2');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: forge_fee% > max_forge_fee%', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_forge_fee_exceeds_max() {
        let yin_price1: Wad = 985000000000000000_u128.into(); // 0.985 (wad)
        let yin_price2: Wad = 970000000000000000_u128.into(); // 0.985 (wad)
        let trove1_owner: ContractAddress = common::trove1_owner_addr();

        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        set_contract_address(ShrineUtils::admin());

        shrine.update_yin_spot_price(yin_price1);
        // Front end fetches the forge fee for the user
        let stale_fee_pct: Wad = shrine.get_forge_fee_pct();

        // Oops! Whale dumps and yin price suddenly drops, causing the forge fee to increase
        shrine.update_yin_spot_price(yin_price2);

        // Should revert since the forge fee exceeds the maximum set by the frontend
        shrine.forge(trove1_owner, common::TROVE_1, ShrineUtils::TROVE1_FORGE_AMT.into(), stale_fee_pct);
    }

    //
    // Tests - Trove melt
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_melt_pass() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        let deposit_amt: Wad = ShrineUtils::TROVE1_YANG1_DEPOSIT.into();
        ShrineUtils::trove1_deposit(shrine, deposit_amt);

        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);

        let yin = ShrineUtils::yin(shrine.contract_address);
        let trove1_owner_addr = common::trove1_owner_addr();

        let before_total_debt: Wad = shrine.get_total_debt();
        let (_, _, _, before_trove_debt) = shrine.get_trove_info(common::TROVE_1);
        let before_yin_bal: u256 = yin.balance_of(trove1_owner_addr);
        let before_max_forge_amt: Wad = shrine.get_max_forge(common::TROVE_1);
        let melt_amt: Wad = (ShrineUtils::TROVE1_YANG1_DEPOSIT / 3_u128).into();

        let outstanding_amt: Wad = forge_amt - melt_amt;
        set_contract_address(ShrineUtils::admin());
        shrine.melt(trove1_owner_addr, common::TROVE_1, melt_amt);

        assert(shrine.get_total_debt() == before_total_debt - melt_amt, 'incorrect total debt');

        let (_, after_ltv, _, after_trove_debt) = shrine.get_trove_info(common::TROVE_1);
        assert(after_trove_debt == before_trove_debt - melt_amt, 'incorrect trove debt');

        let after_yin_bal: u256 = yin.balance_of(trove1_owner_addr);
        assert(after_yin_bal == before_yin_bal - melt_amt.into(), 'incorrect yin balance');

        let (yang1_price, _, _) = shrine.get_current_yang_price(ShrineUtils::yang1_addr());
        let expected_ltv: Ray = wadray::rdiv_ww(outstanding_amt, (yang1_price * deposit_amt));
        assert(after_ltv == expected_ltv, 'incorrect LTV');

        assert(shrine.is_healthy(common::TROVE_1), 'trove should be healthy');

        let after_max_forge_amt: Wad = shrine.get_max_forge(common::TROVE_1);
        assert(
            after_max_forge_amt == before_max_forge_amt + melt_amt, 'incorrect max forge amount'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_melt_unauthorized() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        set_contract_address(common::badguy());
        shrine.melt(common::trove1_owner_addr(), common::TROVE_1, 1_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_melt_insufficient_yin() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        set_contract_address(ShrineUtils::admin());
        shrine.melt(common::trove2_owner_addr(), common::TROVE_1, 1_u128.into());
    }

    //
    // Tests - Yin transfers
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_yin_transfer_pass() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();
        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        set_contract_address(trove1_owner);

        let success: bool = yin.transfer(yin_user, ShrineUtils::TROVE1_FORGE_AMT.into());

        yin.transfer(yin_user, 0_u256);
        assert(success, 'yin transfer fail');
        assert(yin.balance_of(trove1_owner).is_zero(), 'wrong transferor balance');
        assert(
            yin.balance_of(yin_user) == ShrineUtils::TROVE1_FORGE_AMT.into(),
            'wrong transferee balance'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_yin_transfer_fail_insufficient() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();
        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        set_contract_address(trove1_owner);

        yin.transfer(yin_user, (ShrineUtils::TROVE1_FORGE_AMT + 1).into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_yin_transfer_fail_zero_bal() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();
        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        set_contract_address(trove1_owner);

        yin.transfer(yin_user, 1_u256);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_yin_transfer_from_pass() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();

        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        set_contract_address(trove1_owner);
        yin.approve(yin_user, ShrineUtils::TROVE1_FORGE_AMT.into());

        set_contract_address(yin_user);
        let success: bool = yin
            .transfer_from(trove1_owner, yin_user, ShrineUtils::TROVE1_FORGE_AMT.into());

        assert(success, 'yin transfer fail');

        assert(yin.balance_of(trove1_owner).is_zero(), 'wrong transferor balance');
        assert(
            yin.balance_of(yin_user) == ShrineUtils::TROVE1_FORGE_AMT.into(),
            'wrong transferee balance'
        );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u256_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_yin_transfer_from_unapproved_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();
        set_contract_address(yin_user);
        yin.transfer_from(common::trove1_owner_addr(), yin_user, 1_u256);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u256_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_yin_transfer_from_insufficient_allowance_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        set_contract_address(ShrineUtils::admin());
        shrine.forge(trove1_owner, common::TROVE_1, ShrineUtils::TROVE1_FORGE_AMT.into(), 0_u128.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();

        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        set_contract_address(trove1_owner);
        let approve_amt: u256 = (ShrineUtils::TROVE1_FORGE_AMT / 2).into();
        yin.approve(yin_user, approve_amt);

        set_contract_address(yin_user);
        yin.transfer_from(trove1_owner, yin_user, approve_amt + 1_u256);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_yin_transfer_from_insufficient_balance_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        set_contract_address(ShrineUtils::admin());
        shrine.forge(trove1_owner, common::TROVE_1, ShrineUtils::TROVE1_FORGE_AMT.into(), 0_u128.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();

        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        set_contract_address(trove1_owner);
        yin.approve(yin_user, BoundedU256::max());

        set_contract_address(yin_user);
        yin.transfer_from(trove1_owner, yin_user, (ShrineUtils::TROVE1_FORGE_AMT + 1).into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: No transfer to 0 address', 'ENTRYPOINT_FAILED'))]
    fn test_yin_transfer_zero_address_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        set_contract_address(ShrineUtils::admin());
        shrine.forge(trove1_owner, common::TROVE_1, ShrineUtils::TROVE1_FORGE_AMT.into(), 0_u128.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();

        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        set_contract_address(trove1_owner);
        yin.approve(yin_user, BoundedU256::max());

        set_contract_address(yin_user);
        yin.transfer_from(trove1_owner, ContractAddressZeroable::zero(), 1_u256);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_yin_melt_after_transfer() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();

        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        set_contract_address(trove1_owner);

        let transfer_amt: Wad = (forge_amt.val / 2).into();
        yin.transfer(yin_user, transfer_amt.val.into());

        let melt_amt: Wad = forge_amt - transfer_amt;

        ShrineUtils::trove1_melt(shrine, melt_amt);

        let (_, _, _, debt) = shrine.get_trove_info(common::TROVE_1);
        let expected_debt: Wad = forge_amt - melt_amt;
        assert(debt == expected_debt, 'wrong debt after melt');

        assert(
            shrine.get_yin(trove1_owner) == forge_amt - melt_amt - transfer_amt, 'wrong balance'
        );
    }

    //
    // Tests - Access control
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_auth() {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();
        let shrine = ShrineUtils::shrine(shrine_addr);
        let shrine_accesscontrol: IAccessControlDispatcher = IAccessControlDispatcher {
            contract_address: shrine_addr
        };

        let admin: ContractAddress = ShrineUtils::admin();
        let new_admin: ContractAddress = contract_address_const::<0xdada>();

        assert(shrine_accesscontrol.get_admin() == admin, 'wrong admin');

        // Authorizing an address and testing that it can use authorized functions
        set_contract_address(admin);
        shrine_accesscontrol.grant_role(ShrineRoles::SET_DEBT_CEILING, new_admin);
        assert(shrine_accesscontrol.has_role(ShrineRoles::SET_DEBT_CEILING, new_admin), 'role not granted');
        assert(shrine_accesscontrol.get_roles(new_admin) == ShrineRoles::SET_DEBT_CEILING, 'role not granted');

        set_contract_address(new_admin);
        let new_ceiling: Wad = (WAD_SCALE + 1).into();
        shrine.set_debt_ceiling(new_ceiling);
        assert(shrine.get_debt_ceiling() == new_ceiling, 'wrong debt ceiling');

        // Revoking an address
        set_contract_address(admin);
        shrine_accesscontrol.revoke_role(ShrineRoles::SET_DEBT_CEILING, new_admin);
        assert(!shrine_accesscontrol.has_role(ShrineRoles::SET_DEBT_CEILING, new_admin), 'role not revoked');
        assert(shrine_accesscontrol.get_roles(new_admin) == 0, 'role not revoked');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_revoke_role() {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();
        let shrine = ShrineUtils::shrine(shrine_addr);
        let shrine_accesscontrol: IAccessControlDispatcher = IAccessControlDispatcher {
            contract_address: shrine_addr
        };

        let admin: ContractAddress = ShrineUtils::admin();
        let new_admin: ContractAddress = contract_address_const::<0xdada>();

        set_contract_address(admin);
        shrine_accesscontrol.grant_role(ShrineRoles::SET_DEBT_CEILING, new_admin);
        shrine_accesscontrol.revoke_role(ShrineRoles::SET_DEBT_CEILING, new_admin);

        set_contract_address(new_admin);
        let new_ceiling: Wad = (WAD_SCALE + 1).into();
        shrine.set_debt_ceiling(new_ceiling);
    }

    //
    // Tests - Price and multiplier updates
    // Note that core functionality is already tested in `test_shrine_setup_with_feed`
    //

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_advance_unauthorized() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(common::badguy());
        shrine.advance(ShrineUtils::yang1_addr(), ShrineUtils::YANG1_START_PRICE.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang does not exist', 'ENTRYPOINT_FAILED'))]
    fn test_advance_invalid_yang() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        shrine.advance(ShrineUtils::invalid_yang_addr(), ShrineUtils::YANG1_START_PRICE.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_multiplier_unauthorized() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(common::badguy());
        shrine.set_multiplier(RAY_SCALE.into());
    }

    //
    // Tests - Inject/eject
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_inject_and_eject() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        let yin = ShrineUtils::yin(shrine.contract_address);
        let trove1_owner = common::trove1_owner_addr();

        let before_total_supply: u256 = yin.total_supply();
        let before_user_bal: u256 = yin.balance_of(trove1_owner);
        let before_total_yin: Wad = shrine.get_total_yin();
        let before_user_yin: Wad = shrine.get_yin(trove1_owner);

        set_contract_address(ShrineUtils::admin());

        let inject_amt = ShrineUtils::TROVE1_FORGE_AMT.into();
        shrine.inject(trove1_owner, inject_amt);

        assert(
            yin.total_supply() == before_total_supply + inject_amt.into(),
            'incorrect total supply'
        );
        assert(
            yin.balance_of(trove1_owner) == before_user_bal + inject_amt.val.into(),
            'incorrect user balance'
        );
        assert(shrine.get_total_yin() == before_total_yin + inject_amt, 'incorrect total yin');
        assert(shrine.get_yin(trove1_owner) == before_user_yin + inject_amt, 'incorrect user yin');

        shrine.eject(trove1_owner, inject_amt);
        assert(yin.total_supply() == before_total_supply, 'incorrect total supply');
        assert(yin.balance_of(trove1_owner) == before_user_bal, 'incorrect user balance');
        assert(shrine.get_total_yin() == before_total_yin, 'incorrect total yin');
        assert(shrine.get_yin(trove1_owner) == before_user_yin, 'incorrect user yin');
    }


    //
    // Tests - Price and multiplier
    //

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Price cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_advance_zero_value_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        shrine.advance(ShrineUtils::yang1_addr(), WadZeroable::zero());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Multiplier cannot be 0', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_set_multiplier_zero_value_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        shrine.set_multiplier(RayZeroable::zero());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Multiplier exceeds maximum', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_set_multiplier_exceeds_max_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        shrine.set_multiplier((RAY_SCALE * 3 + 1).into());
    }

    //
    // Tests - Getters for trove information
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_trove_unhealthy() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        let deposit_amt: Wad = ShrineUtils::TROVE1_YANG1_DEPOSIT.into();
        ShrineUtils::trove1_deposit(shrine, deposit_amt);
        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);

        let (_, _, _, debt) = shrine.get_trove_info(common::TROVE_1);

        let unsafe_price: Wad = wadray::rdiv_wr(debt, ShrineUtils::YANG1_THRESHOLD.into())
            / deposit_amt;

        set_contract_address(ShrineUtils::admin());
        shrine.advance(ShrineUtils::yang1_addr(), unsafe_price);

        assert(shrine.is_healthy(common::TROVE_1), 'should be unhealthy');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_get_trove_info() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        let mut yangs: Array<ContractAddress> = Default::default();
        let yang1_addr: ContractAddress = ShrineUtils::yang1_addr();
        let yang2_addr: ContractAddress = ShrineUtils::yang2_addr();

        yangs.append(yang1_addr);
        yangs.append(yang2_addr);

        let mut yang_amts: Array<Wad> = Default::default();
        yang_amts.append(ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        yang_amts.append(ShrineUtils::TROVE1_YANG2_DEPOSIT.into());

        // Manually set the prices
        let mut yang_prices: Array<Wad> = Default::default();
        let yang1_price: Wad = 2500000000000000000000_u128.into(); // 2_500 (Wad)
        let yang2_price: Wad = 625000000000000000000_u128.into(); // 625 (Wad)
        yang_prices.append(yang1_price);
        yang_prices.append(yang2_price);

        let mut yang_amts_copy: Span<Wad> = yang_amts.span();
        let mut yangs_copy: Span<ContractAddress> = yangs.span();
        let mut yang_prices_copy: Span<Wad> = yang_prices.span();

        set_contract_address(ShrineUtils::admin());
        loop {
            match yang_amts_copy.pop_front() {
                Option::Some(yang_amt) => {
                    let yang: ContractAddress = *yangs_copy.pop_front().unwrap();
                    shrine.deposit(yang, common::TROVE_1, *yang_amt);

                    shrine.advance(yang, *yang_prices_copy.pop_front().unwrap());
                },
                Option::None(_) => {
                    break ();
                }
            };
        };
        let mut yang_thresholds: Array<Ray> = Default::default();
        yang_thresholds.append(ShrineUtils::YANG1_THRESHOLD.into());
        yang_thresholds.append(ShrineUtils::YANG2_THRESHOLD.into());

        let (expected_threshold, expected_value) = ShrineUtils::calculate_trove_threshold_and_value(
            yang_prices.span(), yang_amts.span(), yang_thresholds.span()
        );
        let (threshold, _, value, _) = shrine.get_trove_info(common::TROVE_1);
        assert(threshold == expected_threshold, 'wrong threshold');

        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);
        let (_, ltv, _, _) = shrine.get_trove_info(common::TROVE_1);
        let expected_ltv: Ray = wadray::rdiv_ww(forge_amt, expected_value);
        assert(ltv == expected_ltv, 'wrong LTV');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_zero_value_trove() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        let (threshold, ltv, value, debt) = shrine.get_trove_info(common::TROVE_3);
        assert(threshold.is_zero(), 'threshold should be 0');
        assert(ltv.is_zero(), 'LTV should be 0');
        assert(value.is_zero(), 'value should be 0');
        assert(debt.is_zero(), 'debt should be 0');
    }

    //
    // Tests - Getters for shrine threshold and value
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_get_shrine_info() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        let mut yangs: Array<ContractAddress> = Default::default();
        let yang1_addr: ContractAddress = ShrineUtils::yang1_addr();
        let yang2_addr: ContractAddress = ShrineUtils::yang2_addr();

        yangs.append(yang1_addr);
        yangs.append(yang2_addr);

        let mut yang_amts: Array<Wad> = Default::default();
        yang_amts.append(ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        yang_amts.append(ShrineUtils::TROVE1_YANG2_DEPOSIT.into());

        // Manually set the prices
        let mut yang_prices: Array<Wad> = Default::default();
        let yang1_price: Wad = 2500000000000000000000_u128.into(); // 2_500 (Wad)
        let yang2_price: Wad = 625000000000000000000_u128.into(); // 625 (Wad)
        yang_prices.append(yang1_price);
        yang_prices.append(yang2_price);

        let mut yang_amts_copy: Span<Wad> = yang_amts.span();
        let mut yangs_copy: Span<ContractAddress> = yangs.span();
        let mut yang_prices_copy: Span<Wad> = yang_prices.span();

        // Deposit into troves 1 and 2, with trove 2 getting twice
        // the amount of trove 1
        set_contract_address(ShrineUtils::admin());
        loop {
            match yang_amts_copy.pop_front() {
                Option::Some(yang_amt) => {
                    let yang: ContractAddress = *yangs_copy.pop_front().unwrap();
                    shrine.deposit(yang, common::TROVE_1, *yang_amt);
                    // Deposit twice the amount into trove 2
                    shrine.deposit(yang, common::TROVE_2, (*yang_amt.val * 2).into());

                    shrine.advance(yang, *yang_prices_copy.pop_front().unwrap());
                },
                Option::None(_) => {
                    break ();
                }
            };
        };

        // Update the amounts with the total amount deposited into troves 1 and 2
        let mut yang_amts: Array<Wad> = Default::default();
        yang_amts.append((ShrineUtils::TROVE1_YANG1_DEPOSIT * 3).into());
        yang_amts.append((ShrineUtils::TROVE1_YANG2_DEPOSIT * 3).into());

        let mut yang_thresholds: Array<Ray> = Default::default();
        yang_thresholds.append(ShrineUtils::YANG1_THRESHOLD.into());
        yang_thresholds.append(ShrineUtils::YANG2_THRESHOLD.into());

        let (expected_threshold, expected_value) = ShrineUtils::calculate_trove_threshold_and_value(
            yang_prices.span(), yang_amts.span(), yang_thresholds.span()
        );
        let (threshold, value) = shrine.get_shrine_threshold_and_value();
        assert(threshold == expected_threshold, 'wrong threshold');
        assert(value == expected_value, 'wrong value');
    }

    // Tests - Getter for forge fee
    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_get_forge_fee() {
        let error_margin: Wad = 5_u128.into(); // 5 * 10^-18 (wad)

        let first_yin_price: Wad = 995000000000000000_u128.into(); // 0.995 (wad)
        let second_yin_price: Wad = 994999999999999999_u128.into(); // 0.994999... (wad)
        let third_yin_price: Wad = 980000000000000000_u128.into(); // 0.98 (wad)
        let fourth_yin_price: Wad = (Shrine::FORGE_FEE_CAP_PRICE - 1).into();

        let third_forge_fee: Wad = 39810717055349725_u128.into(); // 0.039810717055349725 (wad)

        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());

        shrine.update_yin_spot_price(first_yin_price);
        assert(shrine.get_forge_fee_pct().is_zero(), 'wrong forge fee #1');

        shrine.update_yin_spot_price(second_yin_price);
        common::assert_equalish(shrine.get_forge_fee_pct(), WAD_PERCENT.into(), error_margin, 'wrong forge fee #2');

        // forge fee should be capped to `FORGE_FEE_CAP_PCT`
        shrine.update_yin_spot_price(third_yin_price);
        common::assert_equalish(shrine.get_forge_fee_pct(), third_forge_fee, error_margin, 'wrong forge fee #3');

        // forge fee should be `FORGE_FEE_CAP_PCT` for yin price <= `MIN_ZERO_FEE_YIN_PRICE`
        shrine.update_yin_spot_price(fourth_yin_price);
        assert(shrine.get_forge_fee_pct() == Shrine::FORGE_FEE_CAP_PCT.into(), 'wrong forge fee #4');

    }

    //
    // Tests - yang suspension
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_get_yang_suspension_status_basic() {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();
        ShrineUtils::shrine_setup(shrine_addr);
        let shrine = ShrineUtils::shrine(shrine_addr);

        let status_yang1 = shrine.get_yang_suspension_status(ShrineUtils::yang1_addr());
        assert(status_yang1 == YangSuspensionStatus::None(()), 'yang1');
        let status_yang2 = shrine.get_yang_suspension_status(ShrineUtils::yang2_addr());
        assert(status_yang2 == YangSuspensionStatus::None(()), 'yang2');
        let status_yang3 = shrine.get_yang_suspension_status(ShrineUtils::yang3_addr());
        assert(status_yang3 == YangSuspensionStatus::None(()), 'yang3');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang does not exist', 'ENTRYPOINT_FAILED'))]
    fn test_get_yang_suspension_status_nonexisting_yang() {
        let shrine = ShrineUtils::shrine(ShrineUtils::shrine_deploy());
        shrine.get_yang_suspension_status(ShrineUtils::invalid_yang_addr());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang does not exist', 'ENTRYPOINT_FAILED'))]
    fn test_set_yang_suspension_status_non_existing_yang() {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();
        ShrineUtils::shrine_setup(shrine_addr);
        let shrine = ShrineUtils::shrine(shrine_addr);
        set_contract_address(ShrineUtils::admin());
        shrine.update_yang_suspension(ShrineUtils::invalid_yang_addr(), 0);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_yang_suspension_set_and_unset() {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();
        ShrineUtils::shrine_setup(shrine_addr);
        let shrine = ShrineUtils::shrine(shrine_addr);
        let yang = ShrineUtils::yang1_addr();
        let start_ts = ShrineUtils::DEPLOYMENT_TIMESTAMP;

        set_block_timestamp(start_ts);
        set_contract_address(ShrineUtils::admin());

        // initiate yang's suspension, starting now
        shrine.update_yang_suspension(yang, start_ts);

        // check suspension status
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::Temporary(()), 'status 1');

        // setting block time to a second before the suspension would be permanent
        set_block_timestamp(start_ts + Shrine::SUSPENSION_GRACE_PERIOD - 1);

        // reset the suspension by setting yang's ts to 0
        shrine.update_yang_suspension(yang, 0);

        // check suspension status
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::None(()), 'status 2');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_suspension_status_not_authorized() {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();
        ShrineUtils::shrine_setup(shrine_addr);
        let shrine = ShrineUtils::shrine(shrine_addr);
        let yang = ShrineUtils::yang1_addr();
        set_contract_address(common::badguy());

        shrine.update_yang_suspension(yang, 42);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_yang_suspension_progress_temp_to_permanent() {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();
        ShrineUtils::shrine_setup(shrine_addr);
        let shrine = ShrineUtils::shrine(shrine_addr);

        let yang = ShrineUtils::yang1_addr();
        let start_ts = ShrineUtils::DEPLOYMENT_TIMESTAMP;

        set_block_timestamp(start_ts);
        set_contract_address(ShrineUtils::admin());

        // initiate yang's suspension, starting now
        shrine.update_yang_suspension(yang, start_ts);

        // check suspension status
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::Temporary(()), 'status 1');

        // check threshold (should be the same at the beginning)
        let threshold = shrine.get_yang_threshold(yang);
        assert(threshold == ShrineUtils::YANG1_THRESHOLD.into(), 'threshold 1');

        // the threshold should decrease by 1% in this amount of time
        let one_pct = Shrine::SUSPENSION_GRACE_PERIOD / 100;

        // move time forward
        set_block_timestamp(start_ts + one_pct);

        // check suspension status
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::Temporary(()), 'status 2');

        // check threshold
        let threshold = shrine.get_yang_threshold(yang);
        assert(threshold == (ShrineUtils::YANG1_THRESHOLD / 100 * 99).into(), 'threshold 2');

        // move time forward
        set_block_timestamp(start_ts + one_pct * 20);

        // check suspension status
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::Temporary(()), 'status 3');

        // check threshold
        let threshold = shrine.get_yang_threshold(yang);
        assert(threshold == (ShrineUtils::YANG1_THRESHOLD / 100 * 80).into(), 'threshold 3');

        // move time forward to a second before permanent suspension
        set_block_timestamp(start_ts + Shrine::SUSPENSION_GRACE_PERIOD - 1);

        // check suspension status
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::Temporary(()), 'status 4');

        // check threshold
        let threshold = shrine.get_yang_threshold(yang);
        // expected threshold is YANG1_THRESHOLD * (1 / SUSPENSION_GRACE_PERIOD)
        // that is about 0.0000050735 Ray, err margin is 10^-12 Ray
        common::assert_equalish(threshold, 50735000000000000000_u128.into(), 1000000000000000_u128.into(), 'threshold 4');

        // move time forward to end of temp suspension, start of permanent one
        set_block_timestamp(start_ts + Shrine::SUSPENSION_GRACE_PERIOD);

        // check suspension status
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::Permanent(()), 'status 5');

        // check threshold
        let threshold = shrine.get_yang_threshold(yang);
        assert(threshold == RayZeroable::zero(), 'threshold 5');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Permanent suspension', 'ENTRYPOINT_FAILED'))]
    fn test_yang_suspension_cannot_reset_after_permanent() {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();
        ShrineUtils::shrine_setup(shrine_addr);
        let shrine = ShrineUtils::shrine(shrine_addr);

        let yang = ShrineUtils::yang1_addr();
        let start_ts = ShrineUtils::DEPLOYMENT_TIMESTAMP;

        set_block_timestamp(start_ts);
        set_contract_address(ShrineUtils::admin());
        // mark permanent
        shrine.update_yang_suspension(yang, start_ts - Shrine::SUSPENSION_GRACE_PERIOD);
        // sanity check
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::Permanent(()), 'delisted');

        // trying to reset yang suspension status, should fail
        shrine.update_yang_suspension(yang, 0);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Invalid timestamp', 'ENTRYPOINT_FAILED'))]
    fn test_yang_set_suspension_ts_to_future() {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();
        ShrineUtils::shrine_setup(shrine_addr);
        let shrine = ShrineUtils::shrine(shrine_addr);
        let yang = ShrineUtils::yang1_addr();
        let ts = ShrineUtils::DEPLOYMENT_TIMESTAMP;

        set_block_timestamp(ts);
        set_contract_address(ShrineUtils::admin());

        shrine.update_yang_suspension(yang, ts + 1);
    }
}