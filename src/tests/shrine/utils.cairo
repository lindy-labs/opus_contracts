pub mod shrine_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::hash::LegacyHash;
    use core::num::traits::Zero;
    use core::traits::DivRem;
    use opus::core::roles::shrine_roles;
    use opus::core::shrine::shrine as shrine_contract;
    use opus::interfaces::IERC20::{IERC20Dispatcher};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::types::Health;
    use opus::utils::exp::exp;
    use snforge_std::{declare, DeclareResultTrait, ContractClass, ContractClassTrait, start_cheat_caller_address, stop_cheat_caller_address, start_cheat_block_timestamp_global};
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::{Ray, RAY_ONE, Wad};

    //
    // Constants
    //

    // Arbitrary timestamp set to approximately 18 May 2023, 7:55:28am UTC
    pub const DEPLOYMENT_TIMESTAMP: u64 = 1684390000_u64;

    // Number of seconds in an interval

    pub const FEED_LEN: u64 = 10;
    pub const PRICE_CHANGE: u128 = 25000000000000000000000000; // 2.5%

    // Shrine ERC-20 constants
    pub const YIN_NAME: felt252 = 'Cash';
    pub const YIN_SYMBOL: felt252 = 'CASH';

    // Shrine constants
    pub const MINIMUM_TROVE_VALUE: u128 = 50000000000000000000; // 50 (Wad)
    pub const DEBT_CEILING: u128 = 20000000000000000000000; // 20_000 (Wad)

    // Yang constants
    pub const YANG1_THRESHOLD: u128 = 800000000000000000000000000; // 80% (Ray)
    pub const YANG1_START_PRICE: u128 = 2000000000000000000000; // 2_000 (Wad)
    pub const YANG1_BASE_RATE: u128 = 20000000000000000000000000; // 2% (Ray)

    pub const YANG2_THRESHOLD: u128 = 750000000000000000000000000; // 75% (Ray)
    pub const YANG2_START_PRICE: u128 = 500000000000000000000; // 500 (Wad)
    pub const YANG2_BASE_RATE: u128 = 30000000000000000000000000; // 3% (Ray)

    pub const YANG3_THRESHOLD: u128 = 850000000000000000000000000; // 85% (Ray)
    pub const YANG3_START_PRICE: u128 = 1000000000000000000000; // 1_000 (Wad)
    pub const YANG3_BASE_RATE: u128 = 25000000000000000000000000; // 2.5% (Ray)

    pub const INITIAL_YANG_AMT: u128 = 0;

    pub const TROVE1_YANG1_DEPOSIT: u128 = 5000000000000000000; // 5 (Wad)
    pub const TROVE1_YANG2_DEPOSIT: u128 = 8000000000000000000; // 8 (Wad)
    pub const TROVE1_YANG3_DEPOSIT: u128 = 6000000000000000000; // 6 (Wad)
    pub const TROVE1_FORGE_AMT: u128 = 3000000000000000000000; // 3_000 (Wad)

    pub const WHALE_TROVE_YANG1_DEPOSIT: u128 = 100000000000000000000; // 100 (wad)
    pub const WHALE_TROVE_FORGE_AMT: u128 = 10000000000000000000000; // 10,000 (wad)

    pub const RECOVERY_TESTS_TROVE1_FORGE_AMT: u128 = 7500000000000000000000; // 7500 (wad)

    //
    // Address constants
    //

    pub fn admin() -> ContractAddress {
        'shrine admin'.try_into().unwrap()
    }

    pub fn yin_user_addr() -> ContractAddress {
        'yin user'.try_into().unwrap()
    }

    pub fn yang1_addr() -> ContractAddress {
        'yang 1'.try_into().unwrap()
    }

    pub fn yang2_addr() -> ContractAddress {
        'yang 2'.try_into().unwrap()
    }

    pub fn yang3_addr() -> ContractAddress {
        'yang 3'.try_into().unwrap()
    }

    pub fn invalid_yang_addr() -> ContractAddress {
        'invalid yang'.try_into().unwrap()
    }

    //
    // Convenience helpers
    //

    // Wrapper function for Shrine
    #[inline(always)]
    pub fn shrine(shrine_addr: ContractAddress) -> IShrineDispatcher {
        IShrineDispatcher { contract_address: shrine_addr }
    }

    #[inline(always)]
    pub fn yin(shrine_addr: ContractAddress) -> IERC20Dispatcher {
        IERC20Dispatcher { contract_address: shrine_addr }
    }

    // Returns the interval ID for the given timestamp
    #[inline(always)]
    pub fn get_interval(timestamp: u64) -> u64 {
        timestamp / shrine_contract::TIME_INTERVAL
    }

    #[inline(always)]
    pub fn current_interval() -> u64 {
        get_interval(get_block_timestamp())
    }

    //
    // Test setup helpers
    //

    // Helper function to advance timestamp by one interval
    #[inline(always)]
    pub fn advance_interval() {
        common::advance_intervals(1);
    }

    pub fn two_yang_addrs() -> Span<ContractAddress> {
        let mut yang_addrs: Array<ContractAddress> = array![yang1_addr(), yang2_addr()];
        yang_addrs.span()
    }

    pub fn three_yang_addrs() -> Span<ContractAddress> {
        let mut yang_addrs: Array<ContractAddress> = array![yang1_addr(), yang2_addr(), yang3_addr()];
        yang_addrs.span()
    }

    // Note that iteration of yangs (e.g. in redistribution) start from the latest yang ID
    // and terminates at yang ID 0. This affects which yang receives any rounding of
    // debt that falls below the rounding threshold.
    pub fn two_yang_addrs_reversed() -> Span<ContractAddress> {
        let mut yang_addrs: Array<ContractAddress> = array![yang2_addr(), yang1_addr()];
        yang_addrs.span()
    }

    pub fn three_yang_addrs_reversed() -> Span<ContractAddress> {
        let mut yang_addrs: Array<ContractAddress> = array![yang3_addr(), yang2_addr(), yang1_addr()];
        yang_addrs.span()
    }

    pub fn three_yang_start_prices() -> Span<Wad> {
        array![YANG1_START_PRICE.into(), YANG2_START_PRICE.into(), YANG3_START_PRICE.into()].span()
    }

    pub fn declare_shrine() -> ContractClass {
        *declare("shrine").unwrap().contract_class()
    }

    pub fn shrine_deploy(shrine_class: Option<ContractClass>) -> ContractAddress {
        let shrine_class = match shrine_class {
            Option::Some(class) => class,
            Option::None => declare_shrine()
        };

        let calldata: Array<felt252> = array![admin().into(), YIN_NAME, YIN_SYMBOL,];

        start_cheat_block_timestamp_global(DEPLOYMENT_TIMESTAMP);

        let (shrine_addr, _) = shrine_class.deploy(@calldata).expect('shrine deploy failed');

        shrine_addr
    }

    pub fn make_root(shrine_addr: ContractAddress, user: ContractAddress) {
        start_cheat_caller_address(shrine_addr, admin());
        IAccessControlDispatcher { contract_address: shrine_addr }.grant_role(shrine_roles::all_roles(), user);
        stop_cheat_caller_address(shrine_addr);
    }

    pub fn setup_debt_ceiling(shrine_addr: ContractAddress) {
        make_root(shrine_addr, admin());
        // Set debt ceiling
        start_cheat_caller_address(shrine_addr, admin());
        let shrine = shrine(shrine_addr);
        shrine.set_debt_ceiling(DEBT_CEILING.into());
        // Reset contract address
        stop_cheat_caller_address(shrine_addr);
    }

    pub fn shrine_setup(shrine_addr: ContractAddress) {
        setup_debt_ceiling(shrine_addr);
        let shrine = shrine(shrine_addr);
        start_cheat_caller_address(shrine_addr, admin());

        // Add yangs
        shrine
            .add_yang(
                yang1_addr(),
                YANG1_THRESHOLD.into(),
                YANG1_START_PRICE.into(),
                YANG1_BASE_RATE.into(),
                INITIAL_YANG_AMT.into()
            );
        shrine
            .add_yang(
                yang2_addr(),
                YANG2_THRESHOLD.into(),
                YANG2_START_PRICE.into(),
                YANG2_BASE_RATE.into(),
                INITIAL_YANG_AMT.into()
            );
        shrine
            .add_yang(
                yang3_addr(),
                YANG3_THRESHOLD.into(),
                YANG3_START_PRICE.into(),
                YANG3_BASE_RATE.into(),
                INITIAL_YANG_AMT.into()
            );

        // Set minimum trove value
        shrine.set_minimum_trove_value(MINIMUM_TROVE_VALUE.into());

        // Reset contract address
        stop_cheat_caller_address(shrine_addr);
    }

    // Advance the prices for two yangs, starting from the current interval and up to current interval + `num_intervals` - 1
    pub fn advance_prices_and_set_multiplier(
        shrine: IShrineDispatcher, num_intervals: u64, yangs: Span<ContractAddress>, yang_prices: Span<Wad>,
    ) -> Span<Span<Wad>> {
        assert(yangs.len() == yang_prices.len(), 'Array lengths mismatch');

        let mut yang_feeds: Array<Span<Wad>> = ArrayTrait::new();

        let mut yangs_copy = yangs;
        let mut yang_prices_copy = yang_prices;
        loop {
            match yangs_copy.pop_front() {
                Option::Some(_) => { yang_feeds.append(generate_yang_feed(*yang_prices_copy.pop_front().unwrap())); },
                Option::None => { break; },
            };
        };
        let yang_feeds = yang_feeds.span();

        let mut idx: u32 = 0;
        let feed_len: u32 = num_intervals.try_into().unwrap();
        let mut timestamp: u64 = get_block_timestamp();

        start_cheat_caller_address(shrine.contract_address, admin());
        loop {
            if idx == feed_len {
                break;
            }

            start_cheat_block_timestamp_global(timestamp);

            let mut yangs_copy = yangs;
            let mut yang_feeds_copy = yang_feeds;
            loop {
                match yangs_copy.pop_front() {
                    Option::Some(yang) => { shrine.advance(*yang, *(*yang_feeds_copy.pop_front().unwrap()).at(idx)); },
                    Option::None => { break; },
                };
            };

            shrine.set_multiplier(RAY_ONE.into());

            timestamp += shrine_contract::TIME_INTERVAL;

            idx += 1;
        };

        // Reset contract address
        stop_cheat_caller_address(shrine.contract_address);

        yang_feeds
    }

    #[inline(always)]
    pub fn shrine_deploy_and_setup(shrine_class: Option<ContractClass>) -> IShrineDispatcher {
        let shrine_addr: ContractAddress = shrine_deploy(shrine_class);
        shrine_setup(shrine_addr);

        IShrineDispatcher { contract_address: shrine_addr }
    }

    #[inline(always)]
    pub fn shrine_setup_with_feed(shrine_class: Option<ContractClass>) -> IShrineDispatcher {
        let shrine: IShrineDispatcher = shrine_deploy_and_setup(shrine_class);
        advance_prices_and_set_multiplier(shrine, FEED_LEN, three_yang_addrs(), three_yang_start_prices());
        shrine
    }

    #[inline(always)]
    pub fn trove1_deposit(shrine: IShrineDispatcher, amt: Wad) {
        start_cheat_caller_address(shrine.contract_address, admin());
        shrine.deposit(yang1_addr(), common::TROVE_1, amt);
        // Reset contract address
        stop_cheat_caller_address(shrine.contract_address);
    }

    #[inline(always)]
    pub fn trove1_withdraw(shrine: IShrineDispatcher, amt: Wad) {
        start_cheat_caller_address(shrine.contract_address, admin());
        shrine.withdraw(yang1_addr(), common::TROVE_1, amt);
        // Reset contract address
        stop_cheat_caller_address(shrine.contract_address);
    }

    #[inline(always)]
    pub fn trove1_forge(shrine: IShrineDispatcher, amt: Wad) {
        start_cheat_caller_address(shrine.contract_address, admin());
        shrine.forge(common::trove1_owner_addr(), common::TROVE_1, amt, Zero::zero());
        // Reset contract address
        stop_cheat_caller_address(shrine.contract_address);
    }

    #[inline(always)]
    pub fn trove1_melt(shrine: IShrineDispatcher, amt: Wad) {
        start_cheat_caller_address(shrine.contract_address, admin());
        shrine.melt(common::trove1_owner_addr(), common::TROVE_1, amt);
        // Reset contract address
        stop_cheat_caller_address(shrine.contract_address);
    }

    // Helper function to advance prices and multiplier values for a given time by splitting
    // it into multiple periods to avoid hitting the iteration limit when trying to retrieve 
    // the latest prices and multiplier after a prolonged period without updates
    pub fn advance_prices_periodically(shrine: IShrineDispatcher, yangs: Span<ContractAddress>, total_time: u64) {
        let mut num_periods: u64 = 4;
        let (time_per_period, rem_time) = DivRem::div_rem(total_time, num_periods.try_into().unwrap());
        let mut next_ts: u64 = get_block_timestamp();

        start_cheat_caller_address(shrine.contract_address, admin());
        loop {
            if num_periods.is_zero() {
                break;
            }
            next_ts += time_per_period;
            start_cheat_block_timestamp_global(next_ts);

            let mut yangs_copy = yangs;
            loop {
                match yangs_copy.pop_front() {
                    Option::Some(yang) => {
                        let (yang_price, _, _) = shrine.get_current_yang_price(*yang);
                        shrine.advance(*yang, yang_price);
                    },
                    Option::None => { break; }
                }
            };

            shrine.set_multiplier(RAY_ONE.into());

            num_periods -= 1;
        };
        next_ts += rem_time;
        start_cheat_block_timestamp_global(next_ts);
        stop_cheat_caller_address(shrine.contract_address);
    }

    //
    // Test helpers
    //

    pub fn consume_first_bit(ref hash: u256) -> bool {
        let (reduced_hash, remainder) = DivRem::div_rem(hash, 2_u256.try_into().unwrap());
        hash = reduced_hash;
        remainder != 0_u256
    }

    // Helper function to generate a price feed for a yang given a starting price
    // Currently increases the price at a fixed percentage per step
    pub fn generate_yang_feed(mut price: Wad) -> Span<Wad> {
        let mut prices: Array<Wad> = ArrayTrait::new();
        let mut idx: u64 = 0;
        
        let price_u128: u128 = price.into();
        let price_hash: felt252 = LegacyHash::hash(price_u128.into(), price_u128);
        let mut price_hash: u256 = price_hash.into();

        loop {
            if idx == FEED_LEN {
                break prices.span();
            }

            let price_change: Wad = wadray::rmul_wr(price, PRICE_CHANGE.into());
            let increase_price: bool = consume_first_bit(ref price_hash);
            if increase_price {
                price += price_change;
            } else {
                price -= price_change;
            }
            prices.append(price);

            idx += 1;
        }
    }

    // Helper function to get the prices for an array of yangs
    pub fn get_yang_prices(shrine: IShrineDispatcher, mut yangs: Span<ContractAddress>) -> Span<Wad> {
        let mut yang_prices: Array<Wad> = ArrayTrait::new();
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let (yang_price, _, _) = shrine.get_current_yang_price(*yang);
                    yang_prices.append(yang_price);
                },
                Option::None => { break; },
            };
        };
        yang_prices.span()
    }

    // Helper function to calculate the maximum forge amount given a tuple of three ordered arrays of
    // 1. yang prices
    // 2. yang amounts
    // 3. yang thresholds
    pub fn calculate_max_forge(
        mut yang_prices: Span<Wad>, mut yang_amts: Span<Wad>, mut yang_thresholds: Span<Ray>
    ) -> Wad {
        let (threshold, value) = calculate_trove_threshold_and_value(yang_prices, yang_amts, yang_thresholds);
        wadray::rmul_wr(value, threshold)
    }

    // Helper function to calculate the trove value and threshold given a tuple of three ordered arrays of
    // 1. yang prices
    // 2. yang amounts
    // 3. yang thresholds
    pub fn calculate_trove_threshold_and_value(
        mut yang_prices: Span<Wad>, mut yang_amts: Span<Wad>, mut yang_thresholds: Span<Ray>
    ) -> (Ray, Wad) {
        let mut cumulative_value = Zero::zero();
        let mut cumulative_threshold = Zero::zero();

        loop {
            match yang_prices.pop_front() {
                Option::Some(yang_price) => {
                    let amt: Wad = *yang_amts.pop_front().unwrap();
                    let threshold: Ray = *yang_thresholds.pop_front().unwrap();

                    let value = amt * *yang_price;
                    cumulative_value += value;
                    cumulative_threshold += wadray::wmul_wr(value, threshold);
                },
                Option::None => { break (wadray::wdiv_rw(cumulative_threshold, cumulative_value), cumulative_value); },
            };
        }
    }

    /// Helper function to calculate the compounded debt over a given set of intervals.
    ///
    /// Arguments
    ///
    /// * `yang_base_rates_history` - Ordered list of the lists of base rates of each yang at each rate update interval
    ///    over the time period `end_interval - start_interval`.
    ///    e.g. [[rate at update interval 1 for yang 1, ..., rate at update interval 1 for yang 2],
    ///          [rate at update interval n for yang 1, ..., rate at update interval n for yang 2]]`
    ///
    /// * `yang_rate_update_intervals` - Ordered list of the intervals at which each of the updates to the base rates were made.
    ///    The first interval in this list should be <= `start_interval`.
    ///
    /// * `yang_amts` - Ordered list of the amounts of each Yang over the given time period
    ///
    /// * `yang_avg_prices` - Ordered list of the average prices of each yang over each
    ///    base rate "era" (time period over which the base rate doesn't change).
    ///    [[yang1_price_era1, yang2_price_era1], [yang1_price_era2, yang2_price_era2]]
    ///    The first average price of each yang should be from `start_interval` to `yang_rate_update_intervals[1]`,
    ///    and from `yang_rate_update_intervals[i]` to `[i+1]` for the rest
    ///
    /// * `avg_multipliers` - List of average multipliers over each base rate "era"
    ///    (time period over which the base rate doesn't change).
    ///    The first average multiplier should be from `start_interval` to `yang_rate_update_intervals[1]`,
    ///    and from `yang_rate_update_intervals[i]` to `[i+1]` for the rest
    ///
    /// * `start_interval` - Start interval for the compounding period. This should be greater than or equal to the first interval
    ///    in `yang_rate_update_intervals`.
    ///
    /// * `end_interval` - End interval for the compounding period. This should be greater than or equal to the last interval
    ///    in  `yang_rate_update_intervals`.
    ///
    /// * `debt` - Amount of debt at `start_interval`
    pub fn compound(
        mut yang_base_rates_history: Span<Span<Ray>>,
        mut yang_rate_update_intervals: Span<u64>,
        mut yang_amts: Span<Wad>,
        mut yang_avg_prices: Span<Span<Wad>>,
        mut avg_multipliers: Span<Ray>,
        start_interval: u64,
        end_interval: u64,
        mut debt: Wad
    ) -> Wad {
        // Sanity check on input array lengths
        assert(yang_base_rates_history.len() == yang_rate_update_intervals.len(), 'array length mismatch');
        assert(yang_base_rates_history.len() == yang_avg_prices.len(), 'array length mismatch');
        assert(yang_base_rates_history.len() == avg_multipliers.len(), 'array length mismatch');
        assert((*yang_base_rates_history.at(0)).len() == yang_amts.len(), 'array length mismatch');
        let mut yang_base_rates_history_copy = yang_base_rates_history;
        let mut yang_avg_prices_copy = yang_avg_prices;
        loop {
            match yang_base_rates_history_copy.pop_front() {
                Option::Some(base_rates_history) => {
                    assert(
                        (*base_rates_history).len() == (*yang_avg_prices_copy.pop_front().unwrap()).len(),
                        'array length mismatch'
                    );
                },
                Option::None => { break; }
            };
        };

        // Start of tests

        let eras_count: usize = yang_base_rates_history.len();
        let yangs_count: usize = yang_amts.len();

        let mut i: usize = 0;
        loop {
            if i == eras_count {
                break debt;
            }

            let mut weighted_rate_sum: Ray = Zero::zero();
            let mut total_avg_yang_value: Wad = Zero::zero();

            let mut j: usize = 0;
            loop {
                if j == yangs_count {
                    break;
                }
                let yang_value: Wad = *yang_amts[j] * *yang_avg_prices.at(i)[j];
                total_avg_yang_value += yang_value;

                let weighted_rate: Ray = wadray::wmul_rw(*yang_base_rates_history.at(i)[j], yang_value);
                weighted_rate_sum += weighted_rate;

                j += 1;
            };
            let base_rate: Ray = wadray::wdiv_rw(weighted_rate_sum, total_avg_yang_value);
            let rate: Ray = base_rate * *avg_multipliers[i];

            // By default, the start interval for the current era is read from the provided array.
            // However, if it is the first era, we set the start interval to the start interval
            // for the entire compound operation.
            let mut era_start_interval: u64 = *yang_rate_update_intervals[i];
            if i == 0 {
                era_start_interval = start_interval;
            }

            // For any era other than the latest era, the length for a given era to compound for is the
            // difference between the start interval of the next era and the start interval of the current era.
            // For the latest era, then it is the difference between the end interval and the start interval
            // of the current era.
            let mut intervals_in_era: u64 = 0;
            if i == eras_count - 1 {
                intervals_in_era = end_interval - era_start_interval;
            } else {
                intervals_in_era = *yang_rate_update_intervals[i + 1] - era_start_interval;
            }

            let t: u128 = intervals_in_era.into() * shrine_contract::TIME_INTERVAL_DIV_YEAR;

            debt *= exp(wadray::rmul_rw(rate, t.into()));
            i += 1;
        }
    }

    // Compound function for a single yang, within a single era
    pub fn compound_for_single_yang(
        base_rate: Ray, avg_multiplier: Ray, start_interval: u64, end_interval: u64, debt: Wad,
    ) -> Wad {
        let intervals: u128 = (end_interval - start_interval).into();
        let t: Wad = (intervals * shrine_contract::TIME_INTERVAL_DIV_YEAR).into();
        debt * exp(wadray::rmul_rw(base_rate * avg_multiplier, t))
    }

    // Helper function to calculate average price of a yang over a period of intervals
    pub fn get_avg_yang_price(
        shrine: IShrineDispatcher, yang_addr: ContractAddress, start_interval: u64, end_interval: u64
    ) -> Wad {
        let feed_len: u128 = (end_interval - start_interval).into();
        let (_, start_cumulative_price) = shrine.get_yang_price(yang_addr, start_interval);
        let (_, end_cumulative_price) = shrine.get_yang_price(yang_addr, end_interval);

        ((end_cumulative_price - start_cumulative_price).into() / feed_len).into()
    }

    // Helper function to calculate the average multiplier over a period of intervals
    // TODO: Do we need this? Maybe for when the controller is up
    pub fn get_avg_multiplier(shrine: IShrineDispatcher, start_interval: u64, end_interval: u64) -> Ray {
        let feed_len: u128 = (end_interval - start_interval).into();

        let (_, start_cumulative_multiplier) = shrine.get_multiplier(start_interval);
        let (_, end_cumulative_multiplier) = shrine.get_multiplier(end_interval);

        ((end_cumulative_multiplier - start_cumulative_multiplier).into() / feed_len).into()
    }

    pub fn create_whale_trove(shrine: IShrineDispatcher) {
        start_cheat_caller_address(shrine.contract_address, admin());
        // Deposit 100 of yang1
        shrine.deposit(yang1_addr(), common::WHALE_TROVE, WHALE_TROVE_YANG1_DEPOSIT.into());
        // Mint 10,000 yin (5% LTV at yang1's start price)
        shrine.forge(common::trove1_owner_addr(), common::WHALE_TROVE, WHALE_TROVE_FORGE_AMT.into(), Zero::zero());
        stop_cheat_caller_address(shrine.contract_address);
    }

    // Helper function to calculate the factor to be applied to the Shrine's threshold
    // in order to get the LTV that the Shrine should be at for the given test.
    // Since we are interested in testing the Shrine's behaviour when its LTV is at the boundaries
    // of these different modes, an additional offset is used to adjust the factor to guarantee 
    // that we are on the right side of the boundary even if there is some precision loss.
    pub fn get_recovery_mode_test_setup_threshold_factor(
        rm_setup_type: common::RecoveryModeSetupType, offset: Ray
    ) -> Ray {
        match rm_setup_type {
            common::RecoveryModeSetupType::BeforeRecoveryMode => {
                shrine_contract::INITIAL_RECOVERY_MODE_TARGET_FACTOR.into() - offset
            },
            common::RecoveryModeSetupType::BufferLowerBound => {
                shrine_contract::INITIAL_RECOVERY_MODE_TARGET_FACTOR.into() + offset
            },
            common::RecoveryModeSetupType::BufferUpperBound => {
                shrine_contract::INITIAL_RECOVERY_MODE_TARGET_FACTOR.into()
                    + shrine_contract::INITIAL_RECOVERY_MODE_BUFFER_FACTOR.into()
                    - offset
            },
            common::RecoveryModeSetupType::ExceedsBuffer => {
                shrine_contract::INITIAL_RECOVERY_MODE_TARGET_FACTOR.into()
                    + shrine_contract::INITIAL_RECOVERY_MODE_BUFFER_FACTOR.into()
                    + offset
            }
        }
    }

    pub fn get_price_decrease_pct_for_target_ltv(shrine_health: Health, target_ltv: Ray) -> Ray {
        let unhealthy_value: Wad = wadray::rmul_wr(shrine_health.debt, (RAY_ONE.into() / target_ltv));

        if unhealthy_value >= shrine_health.value {
            Zero::zero()
        } else {
            wadray::rdiv_ww((shrine_health.value - unhealthy_value), shrine_health.value)
        }
    }

    pub fn recovery_mode_test_setup(
        shrine: IShrineDispatcher, mut yangs: Span<ContractAddress>, rm_setup_type: common::RecoveryModeSetupType
    ) {
        let shrine_health: Health = shrine.get_shrine_health();
        let offset: Ray = 100000000_u128.into();
        let threshold_factor: Ray = get_recovery_mode_test_setup_threshold_factor(rm_setup_type, offset);
        let target_ltv: Ray = shrine_health.threshold * threshold_factor;
        let decrease_pct: Ray = get_price_decrease_pct_for_target_ltv(shrine_health, target_ltv);

        start_cheat_caller_address(shrine.contract_address, admin());

        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let (yang_price, _, _) = shrine.get_current_yang_price(*yang);
                    let new_price: Wad = wadray::rmul_wr(yang_price, (RAY_ONE.into() - decrease_pct));
                    shrine.advance(*yang, new_price);
                },
                Option::None => { break; }
            };
        };

        stop_cheat_caller_address(shrine.contract_address);

        let shrine_health: Health = shrine.get_shrine_health();
        let error_margin: Ray = offset;
        match rm_setup_type {
            common::RecoveryModeSetupType::BeforeRecoveryMode => {
                common::assert_equalish(shrine_health.ltv, target_ltv, error_margin, 'recovery mode test setup #1');
            },
            common::RecoveryModeSetupType::BufferLowerBound => {
                common::assert_equalish(shrine_health.ltv, target_ltv, error_margin, 'recovery mode test setup #2');
            },
            common::RecoveryModeSetupType::BufferUpperBound => {
                common::assert_equalish(shrine_health.ltv, target_ltv, error_margin, 'recovery mode test setup #3');
            },
            common::RecoveryModeSetupType::ExceedsBuffer => {
                common::assert_equalish(shrine_health.ltv, target_ltv, error_margin, 'recovery mode test setup #4');
            }
        };
    }

    // Helper to return a whether a trove's LTV is at or greater than its target recovery mode 
    // LTV when setting up recovery mode
    pub fn trove_ltv_ge_recovery_mode_target(shrine: IShrineDispatcher, trove_id: u64) -> bool {
        let trove_health: Health = shrine.get_trove_health(trove_id);
        let target_rm_ltv: Ray = shrine_contract::INITIAL_RECOVERY_MODE_TARGET_FACTOR.into() * trove_health.threshold;
        trove_health.ltv >= target_rm_ltv
    }

    //
    // Invariant helpers
    //

    // Asserts that for each yang, the total yang amount is less than or equal to the sum of
    // all troves' deposited amount, and the initial yang amount.
    pub fn assert_total_yang_invariant(shrine: IShrineDispatcher, mut yangs: Span<ContractAddress>, troves_count: u64) {
        let troves_loop_end: u64 = troves_count + 1;

        let mut yang_id: u32 = 1;
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let initial_amt: Wad = shrine.get_protocol_owned_yang_amt(*yang);

                    let mut trove_id: u64 = 1;
                    let mut troves_cumulative_amt: Wad = Zero::zero();
                    loop {
                        if trove_id == troves_loop_end {
                            break;
                        }

                        let trove_amt: Wad = shrine.get_deposit(*yang, trove_id);
                        troves_cumulative_amt += trove_amt;

                        trove_id += 1;
                    };

                    let derived_yang_amt: Wad = troves_cumulative_amt + initial_amt;
                    let actual_yang_amt: Wad = shrine.get_yang_total(*yang);
                    assert_eq!(derived_yang_amt, actual_yang_amt, "yang invariant failed");

                    yang_id += 1;
                },
                Option::None => { break; },
            };
        };
    }

    // Asserts that the total troves debt is less than the sum of all troves' debt, 
    // including all unpulled redistributions.
    pub fn assert_total_troves_debt_invariant(
        shrine: IShrineDispatcher, mut yangs: Span<ContractAddress>, troves_count: u64,
    ) {
        let troves_loop_end: u64 = troves_count + 1;

        let mut cumulative_troves_debt: Wad = Zero::zero();
        let mut trove_id: u64 = 1;

        start_cheat_caller_address(shrine.contract_address, admin());
        loop {
            if trove_id == troves_loop_end {
                break;
            }

            // Accrue interest on trove
            shrine.melt(admin(), trove_id, Zero::zero());

            let trove_health: Health = shrine.get_trove_health(trove_id);
            cumulative_troves_debt += trove_health.debt;

            trove_id += 1;
        };
        stop_cheat_caller_address(shrine.contract_address);

        let shrine_health: Health = shrine.get_shrine_health();
        let protocol_owned_troves_debt: Wad = shrine.get_protocol_owned_troves_debt();
        let cumulative_troves_debt_with_protocol_owned: Wad = cumulative_troves_debt + protocol_owned_troves_debt;

        assert(cumulative_troves_debt_with_protocol_owned <= shrine_health.debt, 'debt invariant failed #1');

        // there may be some precision loss when pulling redistributed debt
        let error_margin: Wad = 10_u128.into();
        common::assert_equalish(
            cumulative_troves_debt_with_protocol_owned, shrine_health.debt, error_margin, 'debt invariant failed #2'
        );
    }

    pub fn assert_shrine_invariants(shrine: IShrineDispatcher, yangs: Span<ContractAddress>, troves_count: u64) {
        assert_total_yang_invariant(shrine, yangs, troves_count);
        assert_total_troves_debt_invariant(shrine, yangs, troves_count);
    }
}
