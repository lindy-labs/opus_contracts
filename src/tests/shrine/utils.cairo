mod ShrineUtils {
    use integer::{
        U128sFromFelt252Result, u128s_from_felt252, u128_safe_divmod, u128_try_as_non_zero
    };
    use starknet::{
        deploy_syscall, ClassHash, class_hash_try_from_felt252, ContractAddress,
        contract_address_to_felt252, contract_address_try_from_felt252, get_block_timestamp,
        SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};

    use aura::core::shrine::Shrine;
    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::exp::exp;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RayZeroable, RAY_ONE, Wad, WadZeroable, WAD_ONE};

    use aura::tests::common;

    use debug::PrintTrait;

    //
    // Constants
    //

    // Arbitrary timestamp set to approximately 18 May 2023, 7:55:28am UTC
    const DEPLOYMENT_TIMESTAMP: u64 = 1684390000_u64;

    // Number of seconds in an interval

    const FEED_LEN: u64 = 10;
    const PRICE_CHANGE: u128 = 25000000000000000000000000; // 2.5%

    // Shrine ERC-20 constants
    const YIN_NAME: felt252 = 'Cash';
    const YIN_SYMBOL: felt252 = 'CASH';

    // Shrine constants
    const DEBT_CEILING: u128 = 20000000000000000000000; // 20_000 (Wad)

    // Yang constants
    const YANG1_THRESHOLD: u128 = 800000000000000000000000000; // 80% (Ray)
    const YANG1_START_PRICE: u128 = 2000000000000000000000; // 2_000 (Wad)
    const YANG1_BASE_RATE: u128 = 20000000000000000000000000; // 2% (Ray)

    const YANG2_THRESHOLD: u128 = 750000000000000000000000000; // 75% (Ray)
    const YANG2_START_PRICE: u128 = 500000000000000000000; // 500 (Wad)
    const YANG2_BASE_RATE: u128 = 30000000000000000000000000; // 3% (Ray)

    const YANG3_THRESHOLD: u128 = 850000000000000000000000000; // 85% (Ray)
    const YANG3_START_PRICE: u128 = 1000000000000000000000; // 1_000 (Wad)
    const YANG3_BASE_RATE: u128 = 25000000000000000000000000; // 2.5% (Ray)

    const INITIAL_YANG_AMT: u128 = 0;

    const TROVE1_YANG1_DEPOSIT: u128 = 5000000000000000000; // 5 (Wad)
    const TROVE1_YANG2_DEPOSIT: u128 = 8000000000000000000; // 8 (Wad)
    const TROVE1_YANG3_DEPOSIT: u128 = 6000000000000000000; // 6 (Wad)
    const TROVE1_FORGE_AMT: u128 = 3000000000000000000000; // 3_000 (Wad)

    const WHALE_TROVE_YANG1_DEPOSIT: u128 = 1000000000000000000000; // 1000 (wad)
    const WHALE_TROVE_FORGE_AMT: u128 = 1000000000000000000000000; // 1,000,000 (wad)

    const RECOVERY_TESTS_TROVE1_FORGE_AMT: u128 = 7500000000000000000000; // 7500 (wad)

    //
    // Address constants
    //

    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('shrine admin').unwrap()
    }

    fn yin_user_addr() -> ContractAddress {
        contract_address_try_from_felt252('yin user').unwrap()
    }

    fn yang1_addr() -> ContractAddress {
        contract_address_try_from_felt252('yang 1').unwrap()
    }

    fn yang2_addr() -> ContractAddress {
        contract_address_try_from_felt252('yang 2').unwrap()
    }

    fn yang3_addr() -> ContractAddress {
        contract_address_try_from_felt252('yang 3').unwrap()
    }

    fn invalid_yang_addr() -> ContractAddress {
        contract_address_try_from_felt252('invalid yang').unwrap()
    }

    //
    // Convenience helpers
    //

    // Wrapper function for Shrine
    #[inline(always)]
    fn shrine(shrine_addr: ContractAddress) -> IShrineDispatcher {
        IShrineDispatcher { contract_address: shrine_addr }
    }

    #[inline(always)]
    fn yin(shrine_addr: ContractAddress) -> IERC20Dispatcher {
        IERC20Dispatcher { contract_address: shrine_addr }
    }

    // Returns the interval ID for the given timestamp
    #[inline(always)]
    fn get_interval(timestamp: u64) -> u64 {
        timestamp / Shrine::TIME_INTERVAL
    }

    #[inline(always)]
    fn deployment_interval() -> u64 {
        get_interval(DEPLOYMENT_TIMESTAMP)
    }

    #[inline(always)]
    fn current_interval() -> u64 {
        get_interval(get_block_timestamp())
    }

    //
    // Test setup helpers
    //

    // Helper function to advance timestamp by one interval
    #[inline(always)]
    fn advance_interval() {
        common::advance_intervals(1);
    }

    // Note that iteration of yangs (e.g. in redistribution) start from the latest yang ID
    // and terminates at yang ID 0. This affects which yang receives any rounding of
    // debt that falls below the rounding threshold.
    fn two_yang_addrs() -> Span<ContractAddress> {
        let mut yang_addrs: Array<ContractAddress> = array![yang2_addr(), yang1_addr(),];
        yang_addrs.span()
    }

    fn three_yang_addrs() -> Span<ContractAddress> {
        let mut yang_addrs: Array<ContractAddress> = array![
            yang3_addr(), yang2_addr(), yang1_addr(),
        ];
        yang_addrs.span()
    }

    fn shrine_deploy() -> ContractAddress {
        set_block_timestamp(DEPLOYMENT_TIMESTAMP);

        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(admin()), YIN_NAME, YIN_SYMBOL,
        ];

        let shrine_class_hash: ClassHash = class_hash_try_from_felt252(Shrine::TEST_CLASS_HASH)
            .unwrap();
        let (shrine_addr, _) = deploy_syscall(shrine_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        shrine_addr
    }

    fn make_root(shrine_addr: ContractAddress, user: ContractAddress) {
        set_contract_address(admin());
        IAccessControlDispatcher { contract_address: shrine_addr }
            .grant_role(ShrineRoles::all_roles(), user);
        set_contract_address(ContractAddressZeroable::zero());
    }

    fn setup_debt_ceiling(shrine_addr: ContractAddress) {
        make_root(shrine_addr, admin());
        // Set debt ceiling
        set_contract_address(admin());
        let shrine = shrine(shrine_addr);
        shrine.set_debt_ceiling(DEBT_CEILING.into());
        // Reset contract address
        set_contract_address(ContractAddressZeroable::zero());
    }

    fn shrine_setup(shrine_addr: ContractAddress) {
        setup_debt_ceiling(shrine_addr);
        let shrine = shrine(shrine_addr);
        set_contract_address(admin());

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

        // Reset contract address
        set_contract_address(ContractAddressZeroable::zero());
    }

    // Advance the prices for two yangs, starting from the current interval and up to current interval + `num_intervals` - 1
    fn advance_prices_and_set_multiplier(
        shrine: IShrineDispatcher,
        num_intervals: u64,
        yang1_start_price: Wad,
        yang2_start_price: Wad,
        yang3_start_price: Wad,
    ) -> (Span<ContractAddress>, Span<Span<Wad>>) {
        let yang1_addr: ContractAddress = yang1_addr();
        let yang1_feed: Span<Wad> = generate_yang_feed(yang1_start_price);

        let yang2_addr: ContractAddress = yang2_addr();
        let yang2_feed: Span<Wad> = generate_yang_feed(yang2_start_price);

        let yang3_addr: ContractAddress = yang3_addr();
        let yang3_feed: Span<Wad> = generate_yang_feed(yang3_start_price);

        let mut yang_addrs: Array<ContractAddress> = array![yang1_addr, yang2_addr, yang3_addr,];

        let mut yang_feeds: Array<Span<Wad>> = array![yang1_feed, yang2_feed, yang3_feed];

        let mut idx: u32 = 0;
        set_contract_address(admin());
        let feed_len: u32 = num_intervals.try_into().unwrap();
        let mut timestamp: u64 = get_block_timestamp();
        loop {
            if idx == feed_len {
                break ();
            }
            set_block_timestamp(timestamp);

            shrine.advance(yang1_addr, *yang1_feed[idx]);
            shrine.advance(yang2_addr, *yang2_feed[idx]);
            shrine.advance(yang3_addr, *yang3_feed[idx]);
            shrine.set_multiplier(RAY_ONE.into());

            timestamp += Shrine::TIME_INTERVAL;

            idx += 1;
        };

        // Reset contract address
        set_contract_address(ContractAddressZeroable::zero());

        (yang_addrs.span(), yang_feeds.span())
    }

    #[inline(always)]
    fn shrine_setup_with_feed() -> IShrineDispatcher {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);

        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine_addr };
        advance_prices_and_set_multiplier(
            shrine,
            FEED_LEN,
            YANG1_START_PRICE.into(),
            YANG2_START_PRICE.into(),
            YANG3_START_PRICE.into()
        );
        shrine
    }

    #[inline(always)]
    fn trove1_deposit(shrine: IShrineDispatcher, amt: Wad) {
        set_contract_address(admin());
        shrine.deposit(yang1_addr(), common::TROVE_1, amt);
        // Reset contract address
        set_contract_address(ContractAddressZeroable::zero());
    }

    #[inline(always)]
    fn trove1_withdraw(shrine: IShrineDispatcher, amt: Wad) {
        set_contract_address(admin());
        shrine.withdraw(yang1_addr(), common::TROVE_1, amt);
        // Reset contract address
        set_contract_address(ContractAddressZeroable::zero());
    }

    #[inline(always)]
    fn trove1_forge(shrine: IShrineDispatcher, amt: Wad) {
        set_contract_address(admin());
        shrine.forge(common::trove1_owner_addr(), common::TROVE_1, amt, WadZeroable::zero());
        // Reset contract address
        set_contract_address(ContractAddressZeroable::zero());
    }

    #[inline(always)]
    fn trove1_melt(shrine: IShrineDispatcher, amt: Wad) {
        set_contract_address(admin());
        shrine.melt(common::trove1_owner_addr(), common::TROVE_1, amt);
        // Reset contract address
        set_contract_address(ContractAddressZeroable::zero());
    }

    //
    // Test helpers
    //

    fn consume_first_bit(ref hash: u128) -> bool {
        let (reduced_hash, remainder) = u128_safe_divmod(
            hash, u128_try_as_non_zero(2_u128).unwrap()
        );
        hash = reduced_hash;
        remainder != 0_u128
    }

    // Helper function to generate a price feed for a yang given a starting price
    // Currently increases the price at a fixed percentage per step
    fn generate_yang_feed(price: Wad) -> Span<Wad> {
        let mut prices: Array<Wad> = Default::default();
        let mut price: Wad = price.into();
        let mut idx: u64 = 0;

        let price_hash: felt252 = pedersen::pedersen(price.val.into(), price.val.into());
        let mut price_hash = match u128s_from_felt252(price_hash) {
            U128sFromFelt252Result::Narrow(i) => {
                i
            },
            U128sFromFelt252Result::Wide((i, j)) => {
                i
            },
        };

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

    // Helper function to calculate the maximum forge amount given a tuple of three ordered arrays of
    // 1. yang prices
    // 2. yang amounts
    // 3. yang thresholds
    fn calculate_max_forge(
        mut yang_prices: Span<Wad>, mut yang_amts: Span<Wad>, mut yang_thresholds: Span<Ray>
    ) -> Wad {
        let (threshold, value) = calculate_trove_threshold_and_value(
            yang_prices, yang_amts, yang_thresholds
        );
        wadray::rmul_wr(value, threshold)
    }

    // Helper function to calculate the trove value and threshold given a tuple of three ordered arrays of
    // 1. yang prices
    // 2. yang amounts
    // 3. yang thresholds
    fn calculate_trove_threshold_and_value(
        mut yang_prices: Span<Wad>, mut yang_amts: Span<Wad>, mut yang_thresholds: Span<Ray>
    ) -> (Ray, Wad) {
        let mut cumulative_value = WadZeroable::zero();
        let mut cumulative_threshold = RayZeroable::zero();

        loop {
            match yang_prices.pop_front() {
                Option::Some(yang_price) => {
                    let amt: Wad = *yang_amts.pop_front().unwrap();
                    let threshold: Ray = *yang_thresholds.pop_front().unwrap();

                    let value = amt * *yang_price;
                    cumulative_value += value;
                    cumulative_threshold += wadray::wmul_wr(value, threshold);
                },
                Option::None => {
                    break (
                        wadray::wdiv_rw(cumulative_threshold, cumulative_value), cumulative_value
                    );
                },
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
    fn compound(
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
        assert(
            yang_base_rates_history.len() == yang_rate_update_intervals.len(),
            'array length mismatch'
        );
        assert(yang_base_rates_history.len() == yang_avg_prices.len(), 'array length mismatch');
        assert(yang_base_rates_history.len() == avg_multipliers.len(), 'array length mismatch');
        assert((*yang_base_rates_history.at(0)).len() == yang_amts.len(), 'array length mismatch');
        let mut yang_base_rates_history_copy = yang_base_rates_history;
        let mut yang_avg_prices_copy = yang_avg_prices;
        loop {
            match yang_base_rates_history_copy.pop_front() {
                Option::Some(base_rates_history) => {
                    assert(
                        (*base_rates_history)
                            .len() == (*yang_avg_prices_copy.pop_front().unwrap())
                            .len(),
                        'array length mismatch'
                    );
                },
                Option::None => {
                    break;
                }
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

            let mut weighted_rate_sum: Ray = RayZeroable::zero();
            let mut total_avg_yang_value: Wad = WadZeroable::zero();

            let mut j: usize = 0;
            loop {
                if j == yangs_count {
                    break ();
                }
                let yang_value: Wad = *yang_amts[j] * *yang_avg_prices.at(i)[j];
                total_avg_yang_value += yang_value;

                let weighted_rate: Ray = wadray::wmul_rw(
                    *yang_base_rates_history.at(i)[j], yang_value
                );
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

            let t: u128 = intervals_in_era.into() * Shrine::TIME_INTERVAL_DIV_YEAR;

            debt *= exp(wadray::rmul_rw(rate, t.into()));
            i += 1;
        }
    }

    // Compound function for a single yang, within a single era
    fn compound_for_single_yang(
        base_rate: Ray, avg_multiplier: Ray, start_interval: u64, end_interval: u64, debt: Wad,
    ) -> Wad {
        let intervals: u128 = (end_interval - start_interval).into();
        let t: Wad = (intervals * Shrine::TIME_INTERVAL_DIV_YEAR).into();
        debt * exp(wadray::rmul_rw(base_rate * avg_multiplier, t))
    }

    // Helper function to calculate average price of a yang over a period of intervals
    fn get_avg_yang_price(
        shrine: IShrineDispatcher,
        yang_addr: ContractAddress,
        start_interval: u64,
        end_interval: u64
    ) -> Wad {
        let feed_len: u128 = (end_interval - start_interval).into();
        let (_, start_cumulative_price) = shrine.get_yang_price(yang_addr, start_interval);
        let (_, end_cumulative_price) = shrine.get_yang_price(yang_addr, end_interval);

        ((end_cumulative_price - start_cumulative_price).val / feed_len).into()
    }

    // Helper function to calculate the average multiplier over a period of intervals
    // TODO: Do we need this? Maybe for when the controller is up
    fn get_avg_multiplier(
        shrine: IShrineDispatcher, start_interval: u64, end_interval: u64
    ) -> Ray {
        let feed_len: u128 = (end_interval - start_interval).into();

        let (_, start_cumulative_multiplier) = shrine.get_multiplier(start_interval);
        let (_, end_cumulative_multiplier) = shrine.get_multiplier(end_interval);

        ((end_cumulative_multiplier - start_cumulative_multiplier).val / feed_len).into()
    }

    fn create_whale_trove(shrine: IShrineDispatcher) {
        set_contract_address(admin());
        // Deposit 1000 of yang1
        shrine.deposit(yang1_addr(), common::WHALE_TROVE, WHALE_TROVE_YANG1_DEPOSIT.into());
        // Mint 1 million yin (50% LTV at yang1's start price)
        shrine
            .forge(
                common::trove1_owner_addr(),
                common::WHALE_TROVE,
                WHALE_TROVE_FORGE_AMT.into(),
                0_u128.into()
            );
        set_contract_address(ContractAddressZeroable::zero());
    }

    fn recovery_mode_test_setup() -> IShrineDispatcher {
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine_deploy() };
        shrine_setup(shrine.contract_address);

        // Setting the debt and collateral ceilings high enough to accomodate a very large trove
        set_contract_address(admin());
        shrine.set_debt_ceiling((2000000 * WAD_ONE).into());

        // This creates the larger trove
        create_whale_trove(shrine);

        // Next, we create a trove with a 75% LTV (yang1's liquidation threshold is 80%)
        let trove1_deposit: Wad = TROVE1_YANG1_DEPOSIT.into();
        trove1_deposit(shrine, trove1_deposit); // yang1 price is 2000 (wad)
        trove1_forge(shrine, RECOVERY_TESTS_TROVE1_FORGE_AMT.into());
        shrine
    }

    //
    // Invariant helpers
    //

    // Asserts that for each yang, the total yang amount is equal to the sum of all troves'
    // deposited amount, including any unpulled exceptional redistributions, and the initial 
    // yang amount.
    fn assert_total_yang_invariant(
        shrine: IShrineDispatcher, mut yangs: Span<ContractAddress>, troves_count: u64
    ) {
        let troves_loop_end: u64 = troves_count + 1;

        let mut yangs_copy = yangs;
        let mut yang_id: u32 = 1;
        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => {
                    let total: Wad = shrine.get_yang_total(*yang);

                    let initial_amt: Wad = shrine.get_initial_yang_amt(*yang);

                    let mut trove_id: u64 = 1;
                    let mut troves_cumulative_amt: Wad = WadZeroable::zero();
                    loop {
                        if trove_id == troves_loop_end {
                            break;
                        }

                        let mut trove_amt: Wad = shrine.get_deposit(*yang, trove_id);
                        let (mut redistributed_yangs, _) = shrine
                            .get_redistributions_attributed_to_trove(trove_id);

                        loop {
                            match redistributed_yangs.pop_front() {
                                Option::Some(redistributed_yang) => {
                                    if *redistributed_yang.yang_id == yang_id {
                                        trove_amt += *redistributed_yang.amount;
                                    }
                                },
                                Option::None => {
                                    break;
                                },
                            };
                        };
                        troves_cumulative_amt += trove_amt;

                        trove_id += 1;
                    };

                    assert(total == troves_cumulative_amt + initial_amt, 'yang invariant failed');

                    yang_id += 1;
                },
                Option::None => {
                    break;
                },
            };
        };
    }

    // Asserts that the total system debt is equal to the sum of all troves' debt, including
    // all unpulled redistributions.
    fn assert_total_debt_invariant(shrine: IShrineDispatcher, troves_count: u64) {
        let troves_loop_end: u64 = troves_count + 1;

        let mut total: Wad = WadZeroable::zero();
        let mut trove_id: u64 = 1;
        loop {
            if trove_id == troves_loop_end {
                break;
            }

            let (_, _, _, trove_debt) = shrine.get_trove_info(trove_id);
            total += trove_debt;
        };

        assert(shrine.get_total_debt() == total, 'debt invariant failed');
    }

    fn assert_shrine_invariants(
        shrine: IShrineDispatcher, mut yangs: Span<ContractAddress>, troves_count: u64
    ) {
        assert_total_yang_invariant(shrine, yangs, troves_count);
        assert_total_debt_invariant(shrine, troves_count);
    }
}
