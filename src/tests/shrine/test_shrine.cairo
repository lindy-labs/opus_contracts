#[cfg(test)]
mod TestShrine {
    use array::{ArrayTrait, SpanTrait};
    use debug::PrintTrait;
    use integer::BoundedU256;
    use option::OptionTrait;
    use traits::{Into, TryInto};
    use starknet::{
        contract_address_const, deploy_syscall, ClassHash, class_hash_try_from_felt252,
        ContractAddress, contract_address_to_felt252, get_block_timestamp, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};

    use aura::core::shrine::Shrine;
    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::exp::exp;
    use aura::utils::serde;
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RayZeroable, RAY_ONE, RAY_SCALE, Wad, WadZeroable, WAD_DECIMALS};

    use aura::tests::shrine::shrine_utils::ShrineUtils;

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
        assert(yin.decimals() == ShrineUtils::WAD_DECIMALS, 'wrong decimals');

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
        assert(shrine.get_yangs_count() == 2, 'wrong yangs count');

        let expected_era: u64 = 0;

        let yang1_addr: ContractAddress = ShrineUtils::yang1_addr();
        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        assert(yang1_price == ShrineUtils::YANG1_START_PRICE.into(), 'wrong yang1 start price');
        assert(
            shrine.get_yang_threshold(yang1_addr) == ShrineUtils::YANG1_THRESHOLD.into(), 'wrong yang1 threshold'
        );
        assert(
            shrine.get_yang_rate(yang1_addr, expected_era) == ShrineUtils::YANG1_BASE_RATE.into(),
            'wrong yang1 base rate'
        );

        let yang2_addr: ContractAddress = ShrineUtils::yang2_addr();
        let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr);
        assert(yang2_price == ShrineUtils::YANG2_START_PRICE.into(), 'wrong yang2 start price');
        assert(
            shrine.get_yang_threshold(yang2_addr) == ShrineUtils::YANG2_THRESHOLD.into(), 'wrong yang2 threshold'
        );
        assert(
            shrine.get_yang_rate(yang2_addr, expected_era) == ShrineUtils::YANG2_BASE_RATE.into(),
            'wrong yang2 base rate'
        );

        // Check shrine threshold and value
        let (threshold, value) = shrine.get_shrine_threshold_and_value();
        assert(threshold == RayZeroable::zero(), 'wrong shrine threshold');
        assert(value == WadZeroable::zero(), 'wrong shrine value');
    }

    // Checks `advance` and `set_multiplier`, and their cumulative values
    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_setup_with_feed() {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();
        ShrineUtils::shrine_setup(shrine_addr);
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine_addr };
        let (yang_addrs, yang_feeds) = ShrineUtils::advance_prices_and_set_multiplier(
            shrine, ShrineUtils::FEED_LEN, ShrineUtils::YANG1_START_PRICE.into(), ShrineUtils::YANG2_START_PRICE.into()
        );
        let mut yang_addrs = yang_addrs;
        let mut yang_feeds = yang_feeds;

        let shrine = ShrineUtils::shrine(shrine_addr);

        let mut exp_start_cumulative_prices: Array<Wad> = ArrayTrait::new();
        exp_start_cumulative_prices.append(ShrineUtils::YANG1_START_PRICE.into());
        exp_start_cumulative_prices.append(ShrineUtils::YANG2_START_PRICE.into());
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
        let yangs_count: u32 = shrine.get_yangs_count();
        assert(yangs_count == 2, 'incorrect yangs count');

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
            shrine.get_yang_total(new_yang_address) == WadZeroable::zero(), 'incorrect yang total'
        );

        let (current_yang_price, _, _) = shrine.get_current_yang_price(new_yang_address);
        assert(current_yang_price == new_yang_start_price, 'incorrect yang price');
        assert(
            shrine.get_yang_threshold(new_yang_address) == new_yang_threshold,
            'incorrect yang threshold'
        );

        let expected_rate_era: u64 = 0_u64;
        assert(
            shrine.get_yang_rate(new_yang_address, expected_rate_era) == new_yang_rate,
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
        set_contract_address(ShrineUtils::badguy());
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

        set_contract_address(ShrineUtils::badguy());
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

        set_contract_address(ShrineUtils::admin());
        shrine.kill();

        // TODO: test deposit, forge, withdraw and melt

        assert(!shrine.get_live(), 'should not be live');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_kill_unauthorized() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        assert(shrine.get_live(), 'should be live');

        set_contract_address(ShrineUtils::badguy());
        shrine.kill();
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

        set_contract_address(ShrineUtils::badguy());
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

        set_contract_address(ShrineUtils::badguy());
        shrine.set_multiplier(RAY_SCALE.into());
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
            shrine.get_yang_total(yang1_addr) == ShrineUtils::TROVE1_YANG1_DEPOSIT.into(), 'incorrect yang total'
        );
        assert(
            shrine.get_deposit(yang1_addr, ShrineUtils::TROVE_1) == ShrineUtils::TROVE1_YANG1_DEPOSIT.into(),
            'incorrect yang deposit'
        );

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let max_forge_amt: Wad = shrine.get_max_forge(ShrineUtils::TROVE_1);

        let mut yang_prices: Array<Wad> = ArrayTrait::new();
        yang_prices.append(yang1_price);

        let mut yang_amts: Array<Wad> = ArrayTrait::new();
        yang_amts.append(ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        let mut yang_thresholds: Array<Ray> = ArrayTrait::new();
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

        shrine.deposit(ShrineUtils::invalid_yang_addr(), ShrineUtils::TROVE_1, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_deposit_unauthorized() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        set_contract_address(ShrineUtils::badguy());

        shrine.deposit(ShrineUtils::yang1_addr(), ShrineUtils::TROVE_1, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
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
        assert(shrine.get_deposit(yang1_addr, ShrineUtils::TROVE_1) == remaining_amt, 'incorrect yang deposit');

        let (_, ltv, _, _) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        assert(ltv == RayZeroable::zero(), 'LTV should be zero');

        assert(shrine.is_healthy(ShrineUtils::TROVE_1), 'trove should be healthy');

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let max_forge_amt: Wad = shrine.get_max_forge(ShrineUtils::TROVE_1);

        let mut yang_prices: Array<Wad> = ArrayTrait::new();
        yang_prices.append(yang1_price);

        let mut yang_amts: Array<Wad> = ArrayTrait::new();
        yang_amts.append(remaining_amt);

        let mut yang_thresholds: Array<Ray> = ArrayTrait::new();
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
        assert(shrine.get_deposit(yang1_addr, ShrineUtils::TROVE_1) == remaining_amt, 'incorrect yang deposit');

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let expected_ltv: Ray = wadray::rdiv_ww(
            ShrineUtils::TROVE1_FORGE_AMT.into(), (yang1_price * remaining_amt)
        );
        let (_, ltv, _, _) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        assert(ltv == expected_ltv, 'incorrect LTV');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Yang does not exist', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_withdraw_invalid_yang_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        set_contract_address(ShrineUtils::admin());

        shrine.withdraw(ShrineUtils::invalid_yang_addr(), ShrineUtils::TROVE_1, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_withdraw_unauthorized() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        set_contract_address(ShrineUtils::badguy());

        shrine.withdraw(ShrineUtils::yang1_addr(), ShrineUtils::TROVE_1, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_withdraw_insufficient_yang_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        set_contract_address(ShrineUtils::admin());

        shrine.withdraw(ShrineUtils::yang1_addr(), ShrineUtils::TROVE_1, (ShrineUtils::TROVE1_YANG1_DEPOSIT + 1).into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_withdraw_zero_yang_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        set_contract_address(ShrineUtils::admin());

        shrine.withdraw(ShrineUtils::yang2_addr(), ShrineUtils::TROVE_1, (ShrineUtils::TROVE1_YANG1_DEPOSIT + 1).into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Trove LTV is too high', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_withdraw_unsafe_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        let (threshold, ltv, trove_value, debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        let (yang1_price, _, _) = shrine.get_current_yang_price(ShrineUtils::yang1_addr());

        // Value of trove needed for existing forged amount to be safe
        let unsafe_trove_value: Wad = wadray::rmul_wr(ShrineUtils::TROVE1_FORGE_AMT.into(), threshold);
        // Amount of yang to be withdrawn to decrease the trove's value to unsafe
        let unsafe_withdraw_yang_amt: Wad = (trove_value - unsafe_trove_value) / yang1_price;
        set_contract_address(ShrineUtils::admin());
        shrine.withdraw(ShrineUtils::yang1_addr(), ShrineUtils::TROVE_1, unsafe_withdraw_yang_amt);
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

        let before_max_forge_amt: Wad = shrine.get_max_forge(ShrineUtils::TROVE_1);
        ShrineUtils::trove1_forge(shrine, forge_amt);

        assert(shrine.get_total_debt() == forge_amt, 'incorrect system debt');

        let (_, ltv, trove_value, debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        assert(debt == forge_amt, 'incorrect trove debt');

        let (yang1_price, _, _) = shrine.get_current_yang_price(ShrineUtils::yang1_addr());
        let expected_value: Wad = yang1_price * ShrineUtils::TROVE1_YANG1_DEPOSIT.into();
        let expected_ltv: Ray = wadray::rdiv_ww(forge_amt, expected_value);
        assert(ltv == expected_ltv, 'incorrect ltv');

        assert(shrine.is_healthy(ShrineUtils::TROVE_1), 'trove should be healthy');

        let after_max_forge_amt: Wad = shrine.get_max_forge(ShrineUtils::TROVE_1);
        assert(after_max_forge_amt == before_max_forge_amt - forge_amt, 'incorrect max forge amt');

        let yin = ShrineUtils::yin(shrine.contract_address);
        // TODO: replace with WadIntoU256 from Absorber PR
        assert(
            yin.balance_of(ShrineUtils::trove1_owner_addr()) == forge_amt.val.into(), 'incorrect ERC-20 balance'
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

        shrine.forge(ShrineUtils::trove3_owner_addr(), ShrineUtils::TROVE_3, 1_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('SH: Trove LTV is too high', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_forge_unsafe_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        set_contract_address(ShrineUtils::admin());

        let unsafe_amt: Wad = (ShrineUtils::TROVE1_FORGE_AMT * 3).into();
        shrine.forge(ShrineUtils::trove1_owner_addr(), ShrineUtils::TROVE_1, unsafe_amt);
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
        shrine.deposit(ShrineUtils::yang1_addr(), ShrineUtils::TROVE_1, additional_yang1_amt);

        let unsafe_amt: Wad = (ShrineUtils::TROVE1_FORGE_AMT * 10).into();
        shrine.forge(ShrineUtils::trove1_owner_addr(), ShrineUtils::TROVE_1, unsafe_amt);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_forge_unauthorized() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());

        set_contract_address(ShrineUtils::badguy());

        shrine.forge(ShrineUtils::trove1_owner_addr(), ShrineUtils::TROVE_1, ShrineUtils::TROVE1_FORGE_AMT.into());
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
        let trove1_owner_addr = ShrineUtils::trove1_owner_addr();

        let before_total_debt: Wad = shrine.get_total_debt();
        let (_, _, _, before_trove_debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        let before_yin_bal: u256 = yin.balance_of(trove1_owner_addr);
        let before_max_forge_amt: Wad = shrine.get_max_forge(ShrineUtils::TROVE_1);
        let melt_amt: Wad = (ShrineUtils::TROVE1_YANG1_DEPOSIT / 3_u128).into();

        let outstanding_amt: Wad = forge_amt - melt_amt;
        set_contract_address(ShrineUtils::admin());
        shrine.melt(trove1_owner_addr, ShrineUtils::TROVE_1, melt_amt);

        assert(shrine.get_total_debt() == before_total_debt - melt_amt, 'incorrect total debt');

        let (_, after_ltv, _, after_trove_debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        assert(after_trove_debt == before_trove_debt - melt_amt, 'incorrect trove debt');

        let after_yin_bal: u256 = yin.balance_of(trove1_owner_addr);
        // TODO: replace with WadIntoU256 from Absorber PR
        assert(after_yin_bal == before_yin_bal - melt_amt.val.into(), 'incorrect yin balance');

        let (yang1_price, _, _) = shrine.get_current_yang_price(ShrineUtils::yang1_addr());
        let expected_ltv: Ray = wadray::rdiv_ww(outstanding_amt, (yang1_price * deposit_amt));
        assert(after_ltv == expected_ltv, 'incorrect LTV');

        assert(shrine.is_healthy(ShrineUtils::TROVE_1), 'trove should be healthy');

        let after_max_forge_amt: Wad = shrine.get_max_forge(ShrineUtils::TROVE_1);
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

        set_contract_address(ShrineUtils::badguy());
        shrine.melt(ShrineUtils::trove1_owner_addr(), ShrineUtils::TROVE_1, 1_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_melt_insufficient_yin() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        set_contract_address(ShrineUtils::admin());
        shrine.melt(ShrineUtils::trove2_owner_addr(), ShrineUtils::TROVE_1, 1_u128.into());
    }

    //
    // Tests - Inject/eject
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_inject_and_eject() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        let yin = ShrineUtils::yin(shrine.contract_address);
        let trove1_owner = ShrineUtils::trove1_owner_addr();

        let before_total_supply: u256 = yin.total_supply();
        let before_user_bal: u256 = yin.balance_of(trove1_owner);
        let before_total_yin: Wad = shrine.get_total_yin();
        let before_user_yin: Wad = shrine.get_yin(trove1_owner);

        set_contract_address(ShrineUtils::admin());

        let inject_amt = ShrineUtils::TROVE1_FORGE_AMT.into();
        shrine.inject(trove1_owner, inject_amt);

        // TODO: replace with WadIntoU256 from Absorber PR
        assert(
            yin.total_supply() == before_total_supply + inject_amt.val.into(),
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

    #[test]
    #[available_gas(20000000000)]
    fn test_yin_transfer_pass() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        set_contract_address(trove1_owner);

        let success: bool = yin.transfer(yin_user, ShrineUtils::TROVE1_FORGE_AMT.into());

        // TODO: Moving this call up here prevents the assert from triggering failed calculating gas
        yin.transfer(yin_user, 0_u256);
        assert(success, 'yin transfer fail');

        assert(yin.balance_of(trove1_owner) == 0_u256, 'wrong transferor balance');

        // TODO: Adding this call prevents failed calculating gas error
        yin.transfer(yin_user, 0_u256);

        assert(yin.balance_of(yin_user) == ShrineUtils::TROVE1_FORGE_AMT.into(), 'wrong transferee balance');

        // TODO: Adding all these calls prevents failed calculating gas error
        yin.transfer(yin_user, 0_u256);
        yin.transfer(yin_user, 0_u256);
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
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
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
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        set_contract_address(trove1_owner);

        yin.transfer(yin_user, 1_u256);
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_yin_transfer_from_pass() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        set_contract_address(trove1_owner);

        yin.approve(yin_user, ShrineUtils::TROVE1_FORGE_AMT.into());

        set_contract_address(yin_user);
        let success: bool = yin.transfer_from(trove1_owner, yin_user, ShrineUtils::TROVE1_FORGE_AMT.into());

        assert(success, 'yin transfer fail');

        assert(yin.balance_of(trove1_owner) == 0_u256, 'wrong transferor balance');
        assert(yin.balance_of(yin_user) == ShrineUtils::TROVE1_FORGE_AMT.into(), 'wrong transferee balance');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u256_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_yin_transfer_from_unapproved_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        set_contract_address(ShrineUtils::admin());
        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();
        set_contract_address(yin_user);
        yin.transfer_from(ShrineUtils::trove1_owner_addr(), yin_user, 1_u256);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u256_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_yin_transfer_from_insufficient_allowance_fail() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        shrine.forge(trove1_owner, ShrineUtils::TROVE_1, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();

        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
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
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        shrine.forge(trove1_owner, ShrineUtils::TROVE_1, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();

        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
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
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        shrine.forge(trove1_owner, ShrineUtils::TROVE_1, ShrineUtils::TROVE1_FORGE_AMT.into());

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();

        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
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
        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);

        let yin = ShrineUtils::yin(shrine.contract_address);
        let yin_user: ContractAddress = ShrineUtils::yin_user_addr();

        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        set_contract_address(trove1_owner);

        let transfer_amt: Wad = (forge_amt.val / 2).into();
        yin.transfer(yin_user, transfer_amt.val.into());

        let melt_amt: Wad = forge_amt - transfer_amt;

        ShrineUtils::trove1_melt(shrine, melt_amt);

        let (_, _, _, debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        let expected_debt: Wad = forge_amt - melt_amt;
        assert(debt == expected_debt, 'wrong debt after melt');

        assert(shrine.get_yin(trove1_owner) == forge_amt - melt_amt - transfer_amt, 'wrong balance');
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

//
// Tests - Getters for shrine threshold and value
//
}
