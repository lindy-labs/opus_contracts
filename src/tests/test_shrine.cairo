#[cfg(test)]
mod TestShrine {
    use array::{ArrayTrait, SpanTrait};
    use debug::PrintTrait;
    use integer::downcast;
    use option::OptionTrait;
    use traits::{Into, TryInto};
    use starknet::{contract_address_const, deploy_syscall, ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_to_felt252, get_block_timestamp, SyscallResultTrait};
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
    const DEBT_CEILING: u128 = 20000000000000000000000;  // 20_000 (Wad)

    // Yang constants
    const YANG1_THRESHOLD: u128 = 800000000000000000000000000;  // 80% (Ray)
    const YANG1_START_PRICE: u128 = 2000000000000000000000;  // 2_000 (Wad)
    const YANG1_BASE_RATE: u128 = 20000000000000000000000000;  // 2% (Ray)

    const YANG2_THRESHOLD: u128 = 800000000000000000000000000;  // 80% (Ray)
    const YANG2_START_PRICE: u128 = 500000000000000000000;  // 500 (Wad)
    const YANG2_BASE_RATE: u128 = 30000000000000000000000000;  // 3% (Ray)

    const INITIAL_YANG_AMT: u128 = 0;

    // Trove constants
    const TROVE_1: u64 = 1;
    const TROVE_2: u64 = 2;
    const TROVE_3: u64 = 3;

    const TROVE1_YANG1_DEPOSIT: u128 = 5000000000000000000;  // 5 (Wad)
    const TROVE1_FORGE_AMT: u128 = 3000000000000000000000;  // 3_000 (Wad)

    //
    // Address constants
    //

    fn admin() -> ContractAddress {
        contract_address_const::<0x1337>()
    }

    fn badguy() -> ContractAddress {
        contract_address_const::<0x42069>()
    }

    fn trove1_owner_addr() -> ContractAddress {
        contract_address_const::<0x0001>()
    }
    
    fn trove2_owner_addr() -> ContractAddress {
        contract_address_const::<0x0002>()
    }

    fn trove3_owner_addr() -> ContractAddress {
        contract_address_const::<0x0003>()
    }

    fn yang1_addr() -> ContractAddress {
        contract_address_const::<0x1234>()
    }

    fn yang2_addr() -> ContractAddress {
        contract_address_const::<0x2345>()
    }

    fn invalid_yang_addr() -> ContractAddress {
        contract_address_const::<0xabcd>()
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
    fn now() -> u64 {
        get_interval(get_block_timestamp())
    }

    //
    // Test setup helpers
    //

    fn yang_addrs() -> Span<ContractAddress> {
        let mut yang_addrs: Array<ContractAddress> = ArrayTrait::new();
        yang_addrs.append(yang1_addr());
        yang_addrs.append(yang2_addr());
        yang_addrs.span()
    }

    fn shrine_deploy() -> ContractAddress {
        set_block_timestamp(DEPLOYMENT_TIMESTAMP);

        let mut calldata = ArrayTrait::new();
        calldata.append(contract_address_to_felt252(admin()));
        calldata.append(YIN_NAME);
        calldata.append(YIN_SYMBOL);

        let shrine_class_hash: ClassHash = class_hash_try_from_felt252(Shrine::TEST_CLASS_HASH).unwrap();
        let (shrine_addr, _) = deploy_syscall(
            shrine_class_hash, 0, calldata.span(), false
        ).unwrap_syscall();

        shrine_addr
    }

    fn shrine_setup(shrine_addr: ContractAddress) {
        // Grant admin role
        let shrine_accesscontrol: IAccessControlDispatcher = IAccessControlDispatcher { contract_address: shrine_addr };
        let admin: ContractAddress = admin();
        set_contract_address(admin);
        shrine_accesscontrol.grant_role(ShrineRoles::all_roles(), admin);
        
        // Set debt ceiling
        let shrine = shrine(shrine_addr);
        shrine.set_ceiling(DEBT_CEILING.into());

        // Add yangs
        shrine.add_yang(yang1_addr(), YANG1_THRESHOLD.into(), YANG1_START_PRICE.into(), YANG1_BASE_RATE.into(), INITIAL_YANG_AMT.into());
        shrine.add_yang(yang2_addr(), YANG2_THRESHOLD.into(), YANG2_START_PRICE.into(), YANG2_BASE_RATE.into(), INITIAL_YANG_AMT.into());
    }

    // Advance the prices for two yangs
    fn advance_prices_and_set_multiplier(
        shrine_addr: ContractAddress, 
        start_timestamp: u64,
        yang1_start_price: Wad,
        yang2_start_price: Wad,
    ) -> (Span<ContractAddress>, Span<Span<Wad>>){
        let shrine = shrine(shrine_addr);
        
        let yang1_addr: ContractAddress = yang1_addr();
        let yang1_feed: Span<Wad> = generate_yang_feed(yang1_start_price);

        let yang2_addr: ContractAddress = yang2_addr();
        let yang2_feed: Span<Wad> = generate_yang_feed(yang2_start_price);

        let mut yang_addrs: Array<ContractAddress> = ArrayTrait::new();
        yang_addrs.append(yang1_addr);
        yang_addrs.append(yang2_addr);

        let mut yang_feeds: Array<Span<Wad>> = ArrayTrait::new();
        yang_feeds.append(yang1_feed);
        yang_feeds.append(yang2_feed);
        
        let mut idx: u32 = 0;
        set_contract_address(admin());
        let feed_len: u32 = FEED_LEN.try_into().unwrap();
        let mut timestamp: u64 = start_timestamp;
        loop {
            if idx == feed_len {
                break ();
            }

            timestamp = start_timestamp + (idx.into() * Shrine::TIME_INTERVAL);
            set_block_timestamp(timestamp);

            shrine.advance(yang1_addr, *yang1_feed[idx]);
            shrine.advance(yang2_addr, *yang2_feed[idx]);
            shrine.set_multiplier(RAY_ONE.into());

            idx += 1;
        };

        // Advance timestamp by one interval so that the value of the last interval
        // is not overwritten when we call this function again.
        set_block_timestamp(timestamp + Shrine::TIME_INTERVAL);

        (yang_addrs.span(), yang_feeds.span())
    }

    fn trove1_deposit(shrine_addr: ContractAddress, amt: Wad) {
        set_contract_address(admin());
        shrine(shrine_addr).deposit(yang1_addr(), TROVE_1, amt);
    }

    fn trove1_withdraw(shrine_addr: ContractAddress, amt: Wad) {
        set_contract_address(admin());
        shrine(shrine_addr).withdraw(yang1_addr(), TROVE_1, amt);
    }

    fn trove1_forge(shrine_addr: ContractAddress, amt: Wad) {
        set_contract_address(admin());
        shrine(shrine_addr).forge(trove1_owner_addr(), TROVE_1, amt);
    }

    //
    // Test helpers
    //

    // Helper function to generate a price feed for a yang given a starting price
    // Currently increases the price at a fixed percentage per step
    fn generate_yang_feed(price: Wad) -> Span<Wad> {
        let mut prices: Array<Wad> = ArrayTrait::new();
        let mut price: Wad = price.into();
        let mut idx: u64 = 0;
        loop {
            if idx == FEED_LEN {
                break prices.span();
            }

            let price = price + wadray::rmul_wr(price, PRICE_CHANGE.into());
            prices.append(price);

            idx += 1;
        }
    }

    // Helper function to calculate the maximum forge amount given a tuple of three ordered arrays of
    // 1. yang prices
    // 2. yang amounts
    // 3. yang thresholds
    fn calculate_max_forge(mut yang_prices: Span<Wad>, mut yang_amts: Span<Wad>, mut yang_thresholds: Span<Ray>) -> Wad {
        let (threshold, value) = calculate_trove_threshold_and_value(yang_prices, yang_amts, yang_thresholds);
        wadray::rmul_wr(value, threshold)
    }
    
    // Helper function to calculate the trove value and threshold given a tuple of three ordered arrays of
    // 1. yang prices
    // 2. yang amounts
    // 3. yang thresholds
    fn calculate_trove_threshold_and_value(mut yang_prices: Span<Wad>, mut yang_amts: Span<Wad>, mut yang_thresholds: Span<Ray>) -> (Ray, Wad) {
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
                Option::None(_) => {
                    break (wadray::wdiv_rw(cumulative_threshold, cumulative_value), cumulative_value);
                },
            };
        }
    }

    //
    // Tests - Deployment and initial setup of Shrine
    //

    // Check constructor function
    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_deploy() {
        let shrine_addr: ContractAddress = shrine_deploy();

        // Check ERC-20 getters
        let yin: IERC20Dispatcher = IERC20Dispatcher { contract_address: shrine_addr };
        assert(yin.name() == YIN_NAME, 'wrong name');
        assert(yin.symbol() == YIN_SYMBOL, 'wrong symbol');
        assert(yin.decimals() == WAD_DECIMALS, 'wrong decimals');

        // Check Shrine getters
        let shrine = shrine(shrine_addr);
        assert(shrine.get_live(), 'not live');
        let (multiplier, _, _) = shrine.get_current_multiplier();
        assert(multiplier == RAY_ONE.into(), 'wrong multiplier');

        let admin: ContractAddress = admin();
        let shrine_accesscontrol: IAccessControlDispatcher = IAccessControlDispatcher { contract_address: shrine_addr };
        assert(shrine_accesscontrol.get_admin() == admin, 'wrong admin');
    }

    // Checks the following functions
    // - `set_debt_ceiling`
    // - `add_yang`
    // - initial threshold and value of Shrine
    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_setup() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);

        // Check debt ceiling
        let shrine = shrine(shrine_addr);
        assert(shrine.get_debt_ceiling() == DEBT_CEILING.into(), 'wrong debt ceiling');

        // Check yangs
        assert(shrine.get_yangs_count() == 2, 'wrong yangs count');

        let expected_era: u64 = 0;

        let yang1_addr: ContractAddress = yang1_addr();
        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        assert(yang1_price == YANG1_START_PRICE.into(), 'wrong yang1 start price');
        assert(shrine.get_yang_threshold(yang1_addr) == YANG1_THRESHOLD.into(), 'wrong yang1 threshold');
        assert(shrine.get_yang_rate(yang1_addr, expected_era) == YANG1_BASE_RATE.into(), 'wrong yang1 base rate');

        let yang2_addr: ContractAddress = yang2_addr();
        let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr);
        assert(yang2_price == YANG2_START_PRICE.into(), 'wrong yang2 start price');
        assert(shrine.get_yang_threshold(yang2_addr) == YANG2_THRESHOLD.into(), 'wrong yang2 threshold');
        assert(shrine.get_yang_rate(yang2_addr, expected_era) == YANG2_BASE_RATE.into(), 'wrong yang2 base rate');

        // Check shrine threshold and value
        let (threshold, value) = shrine.get_shrine_threshold_and_value();
        assert(threshold == RayZeroable::zero(), 'wrong shrine threshold');
        assert(value == WadZeroable::zero(), 'wrong shrine value');
    }

    // Checks `advance` and `set_multiplier`, and their cumulative values
    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_setup_with_feed() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        let (yang_addrs, yang_feeds) = advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());
        let mut yang_addrs = yang_addrs;
        let mut yang_feeds = yang_feeds;

        let shrine = shrine(shrine_addr);

        let mut exp_start_cumulative_prices: Array<Wad> = ArrayTrait::new();
        exp_start_cumulative_prices.append(YANG1_START_PRICE.into());
        exp_start_cumulative_prices.append(YANG2_START_PRICE.into());
        let mut exp_start_cumulative_prices = exp_start_cumulative_prices.span();

        let start_interval: u64 = get_interval(DEPLOYMENT_TIMESTAMP);
        loop {
            match yang_addrs.pop_front() {
                Option::Some(yang_addr) => {

                    // `Shrine.add_yang` sets the initial price for `current_interval - 1`
                    let (_, start_cumulative_price) = shrine.get_yang_price(*yang_addr, start_interval - 1);
                    assert(start_cumulative_price == *exp_start_cumulative_prices.pop_front().unwrap(), 'wrong start cumulative price');

                    let (_, start_cumulative_multiplier) = shrine.get_multiplier(start_interval - 1);
                    assert(start_cumulative_multiplier == Ray { val: RAY_SCALE }, 'wrong start cumulative mul');

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
                        assert(cumulative_price == expected_cumulative_price, 'wrong cumulative price in feed');

                        expected_cumulative_multiplier += RAY_SCALE.into();
                        let (multiplier, cumulative_multiplier) = shrine.get_multiplier(interval);
                        assert(multiplier == Ray { val: RAY_SCALE }, 'wrong multiplier in feed');
                        assert(cumulative_multiplier == expected_cumulative_multiplier, 'wrong cumulative mul in feed');

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
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);
        let yangs_count: u32 = shrine.get_yangs_count();
        assert(yangs_count == 2, 'incorrect yangs count');

        let new_yang_address: ContractAddress = contract_address_const::<0x9870>();
        let new_yang_threshold: Ray = 600000000000000000000000000_u128.into(); // 60% (Ray)
        let new_yang_start_price: Wad = 5000000000000000000_u128.into();  // 5 (Wad)
        let new_yang_rate: Ray = 60000000000000000000000000_u128.into();  // 6% (Ray)

        let admin = admin();
        set_contract_address(admin);
        shrine.add_yang(new_yang_address, new_yang_threshold, new_yang_start_price, new_yang_rate, WadZeroable::zero());

        assert(shrine.get_yangs_count() == yangs_count + 1, 'incorrect yangs count');
        assert(shrine.get_yang_total(new_yang_address) == WadZeroable::zero(), 'incorrect yang total');

        let (current_yang_price, _, _) = shrine.get_current_yang_price(new_yang_address);
        assert(current_yang_price == new_yang_start_price, 'incorrect yang price');
        assert(shrine.get_yang_threshold(new_yang_address) == new_yang_threshold, 'incorrect yang threshold');
        
        let expected_rate_era: u64 = 0_u64;
        assert(shrine.get_yang_rate(new_yang_address, expected_rate_era) == new_yang_rate, 'incorrect yang rate'); 
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Yang already exists', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_duplicate_fail() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);
        set_contract_address(admin());
        shrine.add_yang(yang1_addr(), YANG1_THRESHOLD.into(), YANG1_START_PRICE.into(), YANG1_BASE_RATE.into(), WadZeroable::zero());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_add_yang_unauthorized() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);
        set_contract_address(badguy());
        shrine.add_yang(yang1_addr(), YANG1_THRESHOLD.into(), YANG1_START_PRICE.into(), YANG1_BASE_RATE.into(), WadZeroable::zero());
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_threshold() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);
        let yang1_addr = yang1_addr();
        let new_threshold: Ray = 900000000000000000000000000_u128.into();

        set_contract_address(admin());
        shrine.set_threshold(yang1_addr, new_threshold);
        assert(shrine.get_yang_threshold(yang1_addr) == new_threshold, 'threshold not updated');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Threshold > max', 'ENTRYPOINT_FAILED'))]
    fn test_set_threshold_exceeds_max() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);
        let invalid_threshold: Ray = (RAY_SCALE + 1).into();

        set_contract_address(admin());
        shrine.set_threshold(yang1_addr(), invalid_threshold);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_threshold_unauthorized() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);
        let new_threshold: Ray = 900000000000000000000000000_u128.into();

        set_contract_address(badguy());
        shrine.set_threshold(yang1_addr(), new_threshold);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Yang does not exist', 'ENTRYPOINT_FAILED'))]
    fn test_set_threshold_invalid_yang() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);
        set_contract_address(admin());
        shrine.set_threshold(invalid_yang_addr(), YANG1_THRESHOLD.into());
    }

    //
    // Tests - Shrine kill
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_kill() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);
        assert(shrine.get_live(), 'should be live');

        set_contract_address(admin());
        shrine.kill();

        // TODO: test deposit, forge, withdraw and melt

        assert(!shrine.get_live(), 'should not be live');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_kill_unauthorized() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);
        assert(shrine.get_live(), 'should be live');

        set_contract_address(badguy());
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
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);

        set_contract_address(badguy());
        shrine.advance(yang1_addr(), YANG1_START_PRICE.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Yang does not exist', 'ENTRYPOINT_FAILED'))]
    fn test_advance_invalid_yang() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);

        set_contract_address(admin());
        shrine.advance(invalid_yang_addr(), YANG1_START_PRICE.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_set_multiplier_unauthorized() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);

        set_contract_address(badguy());
        shrine.set_multiplier(RAY_SCALE.into());
    }

    //
    // Tests - trove deposit
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_deposit_pass() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());
        trove1_deposit(shrine_addr, TROVE1_YANG1_DEPOSIT.into());

        let shrine = shrine(shrine_addr);
        
        let yang1_addr = yang1_addr();
        assert(shrine.get_yang_total(yang1_addr) == TROVE1_YANG1_DEPOSIT.into(), 'incorrect yang total');
        assert(shrine.get_deposit(yang1_addr, TROVE_1) == TROVE1_YANG1_DEPOSIT.into(), 'incorrect yang deposit');

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let max_forge_amt: Wad = shrine.get_max_forge(TROVE_1);

        let mut yang_prices: Array<Wad> = ArrayTrait::new();
        yang_prices.append(yang1_price);

        let mut yang_amts: Array<Wad> = ArrayTrait::new();
        yang_amts.append(TROVE1_YANG1_DEPOSIT.into());

        let mut yang_thresholds: Array<Ray> = ArrayTrait::new();
        yang_thresholds.append(YANG1_THRESHOLD.into());

        let expected_max_forge: Wad = calculate_max_forge(yang_prices.span(), yang_amts.span(), yang_thresholds.span());
        assert(max_forge_amt == expected_max_forge, 'incorrect max forge amt');
    }
    
    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Yang does not exist', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_deposit_invalid_yang_fail() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);
        set_contract_address(admin());

        shrine.deposit(invalid_yang_addr(), TROVE_1, TROVE1_YANG1_DEPOSIT.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_deposit_unauthorized() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);
        set_contract_address(badguy());

        shrine.deposit(yang1_addr(), TROVE_1, TROVE1_YANG1_DEPOSIT.into());
    }

    //
    // Tests - Trove withdraw
    //

    #[test]
    #[available_gas(1000000000000)]
    fn test_shrine_withdraw_pass() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());
        trove1_deposit(shrine_addr, TROVE1_YANG1_DEPOSIT.into());

        let shrine = shrine(shrine_addr);
        set_contract_address(admin());
        let withdraw_amt: Wad = (TROVE1_YANG1_DEPOSIT / 3).into();
        trove1_withdraw(shrine_addr, withdraw_amt);

        let yang1_addr = yang1_addr();
        let remaining_amt: Wad = TROVE1_YANG1_DEPOSIT.into() - withdraw_amt;
        assert(shrine.get_yang_total(yang1_addr) == remaining_amt, 'incorrect yang total');
        assert(shrine.get_deposit(yang1_addr, TROVE_1) == remaining_amt, 'incorrect yang deposit');
        
        let (_, ltv, _, _) = shrine.get_trove_info(TROVE_1);
        assert(ltv == RayZeroable::zero(), 'LTV should be zero');

        assert(shrine.is_healthy(TROVE_1), 'trove should be healthy');

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let max_forge_amt: Wad = shrine.get_max_forge(TROVE_1);

        let mut yang_prices: Array<Wad> = ArrayTrait::new();
        yang_prices.append(yang1_price);

        let mut yang_amts: Array<Wad> = ArrayTrait::new();
        yang_amts.append(remaining_amt);

        let mut yang_thresholds: Array<Ray> = ArrayTrait::new();
        yang_thresholds.append(YANG1_THRESHOLD.into());

        let expected_max_forge: Wad = calculate_max_forge(yang_prices.span(), yang_amts.span(), yang_thresholds.span());
        assert(max_forge_amt == expected_max_forge, 'incorrect max forge amt');
    }

    #[test]
    #[available_gas(1000000000000)]
    fn test_shrine_forged_partial_withdraw_pass() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());
        trove1_deposit(shrine_addr, TROVE1_YANG1_DEPOSIT.into());
        trove1_forge(shrine_addr, TROVE1_FORGE_AMT.into());

        let shrine = shrine(shrine_addr);
        set_contract_address(admin());
        let withdraw_amt: Wad = (TROVE1_YANG1_DEPOSIT / 3).into();
        trove1_withdraw(shrine_addr, withdraw_amt);

        let yang1_addr = yang1_addr();
        let remaining_amt: Wad = TROVE1_YANG1_DEPOSIT.into() - withdraw_amt;
        assert(shrine.get_yang_total(yang1_addr) == remaining_amt, 'incorrect yang total');
        assert(shrine.get_deposit(yang1_addr, TROVE_1) == remaining_amt, 'incorrect yang deposit');
        
        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let expected_ltv: Ray = wadray::rdiv_ww(TROVE1_FORGE_AMT.into(), (yang1_price * remaining_amt));
        let (_, ltv, _, _) = shrine.get_trove_info(TROVE_1);
        assert(ltv == expected_ltv, 'incorrect LTV');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Yang does not exist', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_withdraw_invalid_yang_fail() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);
        set_contract_address(admin());

        shrine.withdraw(invalid_yang_addr(), TROVE_1, TROVE1_YANG1_DEPOSIT.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_withdraw_unauthorized() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());
        trove1_deposit(shrine_addr, TROVE1_YANG1_DEPOSIT.into());

        let shrine = shrine(shrine_addr);
        set_contract_address(badguy());

        shrine.withdraw(yang1_addr(), TROVE_1, TROVE1_YANG1_DEPOSIT.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_withdraw_insufficient_yang_fail() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());
        trove1_deposit(shrine_addr, TROVE1_YANG1_DEPOSIT.into());

        let shrine = shrine(shrine_addr);
        set_contract_address(admin());

        shrine.withdraw(yang1_addr(), TROVE_1, (TROVE1_YANG1_DEPOSIT + 1).into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_withdraw_zero_yang_fail() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);
        set_contract_address(admin());

        shrine.withdraw(yang2_addr(), TROVE_1, (TROVE1_YANG1_DEPOSIT + 1).into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Trove LTV is too high', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_withdraw_unsafe_fail() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());
        trove1_deposit(shrine_addr, TROVE1_YANG1_DEPOSIT.into());
        trove1_forge(shrine_addr, TROVE1_FORGE_AMT.into());

        let shrine = shrine(shrine_addr);

        let (threshold, ltv, trove_value, debt) = shrine.get_trove_info(TROVE_1);
        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr());

        // Value of trove needed for existing forged amount to be safe
        let unsafe_trove_value: Wad = wadray::rmul_wr(TROVE1_FORGE_AMT.into(), threshold);
        // Amount of yang to be withdrawn to decrease the trove's value to unsafe
        let unsafe_withdraw_yang_amt: Wad = (trove_value - unsafe_trove_value) / yang1_price;
        set_contract_address(admin());
        shrine.withdraw(yang1_addr(), TROVE_1, unsafe_withdraw_yang_amt);
    }

    //
    // Tests - Trove forge
    //

    #[test]
    #[available_gas(1000000000000)]
    fn test_shrine_forge_pass() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());
        trove1_deposit(shrine_addr, TROVE1_YANG1_DEPOSIT.into());

        let shrine = shrine(shrine_addr);
        let forge_amt: Wad = TROVE1_FORGE_AMT.into();

        let before_max_forge_amt: Wad = shrine.get_max_forge(TROVE_1);
        trove1_forge(shrine_addr, forge_amt);
        
        let shrine = shrine(shrine_addr);
        assert(shrine.get_total_debt() == forge_amt, 'incorrect system debt');

        let (_, ltv, trove_value, debt) = shrine.get_trove_info(TROVE_1);
        assert(debt == forge_amt, 'incorrect trove debt');
        
        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr());
        let expected_value: Wad = yang1_price * TROVE1_YANG1_DEPOSIT.into();
        let expected_ltv: Ray = wadray::rdiv_ww(forge_amt, expected_value);
        assert(ltv == expected_ltv, 'incorrect ltv');

        assert(shrine.is_healthy(TROVE_1), 'trove should be healthy');

        let after_max_forge_amt: Wad = shrine.get_max_forge(TROVE_1);
        assert(after_max_forge_amt == before_max_forge_amt - forge_amt, 'incorrect max forge amt');

        let yin = yin(shrine_addr);
        // TODO: replace with WadIntoU256 from Absorber PR
        assert(yin.balance_of(trove1_owner_addr()) == forge_amt.val.into(), 'incorrect ERC-20 balance');
        assert(yin.total_supply() == forge_amt.val.into(), 'incorrect ERC-20 balance');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Trove LTV is too high', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_forge_zero_deposit_fail() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);
        let forge_amt: Wad = TROVE1_FORGE_AMT.into();
        set_contract_address(admin());

        shrine.forge(trove3_owner_addr(), TROVE_3, 1_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Trove LTV is too high', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_forge_unsafe_fail() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());
        trove1_deposit(shrine_addr, TROVE1_YANG1_DEPOSIT.into());

        let shrine = shrine(shrine_addr);
        let forge_amt: Wad = TROVE1_FORGE_AMT.into();
        set_contract_address(admin());

        let unsafe_amt: Wad = (TROVE1_FORGE_AMT * 3).into();
        shrine.forge(trove1_owner_addr(), TROVE_1, unsafe_amt);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Debt ceiling reached', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_forge_ceiling_fail() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());
        trove1_deposit(shrine_addr, TROVE1_YANG1_DEPOSIT.into());

        let shrine = shrine(shrine_addr);
        let forge_amt: Wad = TROVE1_FORGE_AMT.into();
        set_contract_address(admin());

        // deposit more collateral
        let additional_yang1_amt: Wad = (TROVE1_YANG1_DEPOSIT * 10).into();
        shrine.deposit(yang1_addr(), TROVE_1, additional_yang1_amt);

        let unsafe_amt: Wad = (TROVE1_FORGE_AMT * 10).into();
        shrine.forge(trove1_owner_addr(), TROVE_1, unsafe_amt);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_forge_unauthorized() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());
        trove1_deposit(shrine_addr, TROVE1_YANG1_DEPOSIT.into());

        let shrine = shrine(shrine_addr);
        set_contract_address(badguy());

        shrine.forge(trove1_owner_addr(), TROVE_1, TROVE1_FORGE_AMT.into());
    }

    //
    // Tests - Trove melt
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_melt_pass() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());
        let deposit_amt: Wad = TROVE1_YANG1_DEPOSIT.into();
        trove1_deposit(shrine_addr, deposit_amt);

        let forge_amt: Wad = TROVE1_FORGE_AMT.into();
        trove1_forge(shrine_addr, forge_amt);

        let shrine = shrine(shrine_addr);
        let yin = yin(shrine_addr);
        let trove1_owner_addr = trove1_owner_addr();

        let before_total_debt: Wad = shrine.get_total_debt();
        let (_, _, _, before_trove_debt) = shrine.get_trove_info(TROVE_1);
        let before_yin_bal: u256 = yin.balance_of(trove1_owner_addr);
        let before_max_forge_amt: Wad = shrine.get_max_forge(TROVE_1);
        let melt_amt: Wad = (TROVE1_YANG1_DEPOSIT / 3_u128).into();

        let outstanding_amt: Wad = forge_amt - melt_amt;
        set_contract_address(admin());
        shrine.melt(trove1_owner_addr, TROVE_1, melt_amt);

        assert(shrine.get_total_debt() == before_total_debt - melt_amt, 'incorrect total debt');

        let (_, after_ltv, _, after_trove_debt) = shrine.get_trove_info(TROVE_1);
        assert(after_trove_debt == before_trove_debt - melt_amt, 'incorrect trove debt');

        let after_yin_bal: u256 = yin.balance_of(trove1_owner_addr);
        // TODO: replace with WadIntoU256 from Absorber PR
        assert(after_yin_bal == before_yin_bal - melt_amt.val.into(), 'incorrect yin balance');

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr());
        let expected_ltv: Ray = wadray::rdiv_ww(outstanding_amt, (yang1_price * deposit_amt));
        assert(after_ltv == expected_ltv, 'incorrect LTV');

        assert(shrine.is_healthy(TROVE_1), 'trove should be healthy');

        let after_max_forge_amt: Wad = shrine.get_max_forge(TROVE_1);
        assert(after_max_forge_amt == before_max_forge_amt + melt_amt, 'incorrect max forge amount');
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_melt_unauthorized() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());
        trove1_deposit(shrine_addr, TROVE1_YANG1_DEPOSIT.into());
        trove1_forge(shrine_addr, TROVE1_YANG1_DEPOSIT.into());

        let shrine = shrine(shrine_addr);
        set_contract_address(badguy());
        shrine.melt(trove1_owner_addr(), TROVE_1, 1_u128.into());
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
    fn test_shrine_melt_insufficient_yin() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());
        trove1_deposit(shrine_addr, TROVE1_YANG1_DEPOSIT.into());
        trove1_forge(shrine_addr, TROVE1_FORGE_AMT.into());

        let shrine = shrine(shrine_addr);
        set_contract_address(admin());
        shrine.melt(trove2_owner_addr(), TROVE_1, 1_u128.into());
    }

    //
    // Tests - Inject/eject
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_inject_and_eject() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());

        let shrine = shrine(shrine_addr);
        let yin = yin(shrine_addr);
        let trove1_owner = trove1_owner_addr();

        let before_total_supply: u256 = yin.total_supply();
        let before_user_bal: u256 = yin.balance_of(trove1_owner);
        let before_total_yin: Wad = shrine.get_total_yin();
        let before_user_yin: Wad = shrine.get_yin(trove1_owner);

        set_contract_address(admin());

        let inject_amt = TROVE1_FORGE_AMT.into();
        shrine.inject(trove1_owner, inject_amt);

        // TODO: replace with WadIntoU256 from Absorber PR
        assert(yin.total_supply() == before_total_supply + inject_amt.val.into(), 'incorrect total supply');
        assert(yin.balance_of(trove1_owner) == before_user_bal + inject_amt.val.into(), 'incorrect user balance');
        assert(shrine.get_total_yin() == before_total_yin + inject_amt, 'incorrect total yin');
        assert(shrine.get_yin(trove1_owner) == before_user_yin + inject_amt, 'incorrect user yin');

        shrine.eject(trove1_owner, inject_amt);
        assert(yin.total_supply() == before_total_supply, 'incorrect total supply');
        assert(yin.balance_of(trove1_owner) == before_user_bal, 'incorrect user balance');
        assert(shrine.get_total_yin() == before_total_yin, 'incorrect total yin');
        assert(shrine.get_yin(trove1_owner) == before_user_yin, 'incorrect user yin');        
    }

    //
    // Tests - Trove estimate and charge
    // 


    /// Helper function to calculate the compounded debt over a given set of intervals.
    ///
    /// # Arguments
    ///
    /// * `yang_base_rates_history` - Ordered list of the lists of base rates of each yang at each rate update interval
    ///    over the time period `end_interval - start_interval`.
    ///    e.g. [[rate at update interval 1 for yang 1, ..., rate at update interval n for yang 1],
    ///          [rate at update interval 1 for yang 2, ..., rate at update interval n for yang 2]]`
    /// * `yang_rate_update_intervals` - Ordered list of the intervals at which each of the updates to the base rates were made.
    ///    The first interval in this list should be <= `start_interval`.
    /// * `yang_amts` - Ordered list of the amounts of each Yang over the given time period
    /// * `yang_avg_prices` - Ordered list of the average prices of each yang over each
    ///    base rate "era" (time period over which the base rate doesn't change).
    ///    The first average price of each yang should be from `start_interval` to `yang_rate_update_intervals[1]`,
    ///    and from `yang_rate_update_intervals[i]` to `[i+1]` for the rest
    /// * `avg_multipliers` - List of average multipliers over each base rate "era"
    ///    (time period over which the base rate doesn't change).
    ///    The first average multiplier should be from `start_interval` to `yang_rate_update_intervals[1]`,
    ///    and from `yang_rate_update_intervals[i]` to `[i+1]` for the rest
    /// * `start_interval` - Start interval for the compounding period
    /// * `end_interval` - End interval for the compounding period
    /// * `debt`` - Amount of debt at `start_interval`
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
        // TODO: it will be helpful to validatethe input arrays

        let eras_count: usize = (*yang_base_rates_history.at(0)).len();
        let yangs_count: usize = yang_amts.len();

        let mut i: usize = 0;
        loop {
            if i == eras_count {
                break debt;
            }

            let mut weighted_rate_sum: Ray = RayZeroable::zero();
            let mut total_yang_value: Wad = WadZeroable::zero();

            let mut j: usize = 0;
            loop {
                if j == yangs_count {
                    break ();
                }

                let yang_value: Wad = *yang_amts[j] * *yang_avg_prices[j][i];
                total_yang_value += yang_value;

                let weighted_rate: Ray = wadray::wmul_rw(*yang_base_rates_history[j][i], yang_value);
                weighted_rate_sum += weighted_rate;

                j += 1;
            };

            let base_rate: Ray = wadray::wdiv_rw(weighted_rate_sum, total_yang_value);
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

            // Add an offset of 1 to get the actual number of intervals between start and end
            intervals_in_era += 1;

            let t: u128 = intervals_in_era.into() * Shrine::TIME_INTERVAL_DIV_YEAR;
            debt *= exp(wadray::rmul_rw(rate, t.into()));
            i += 1;
        }
    }

    // Test for `charge` with all intervals between start and end inclusive updated.
    //
    // T+START--------------T+END
    #[test]
    #[available_gas(20000000000)]
    fn test_compound_and_charge_scenario_1() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        advance_prices_and_set_multiplier(shrine_addr, DEPLOYMENT_TIMESTAMP, YANG1_START_PRICE.into(), YANG2_START_PRICE.into());
        trove1_deposit(shrine_addr, TROVE1_YANG1_DEPOSIT.into());
        trove1_forge(shrine_addr, TROVE1_FORGE_AMT.into());

        let shrine = shrine(shrine_addr);

        let start_interval: u64 = deployment_interval() + FEED_LEN;
        assert(now() == start_interval, 'wrong start interval');  // sanity check

        let yang1_addr = yang1_addr();
        // Note that this is the price at `start_interval - 1` since `advance_prices_and_set_multiplier`
        // advances by one interval at the end.
        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        // technically not needed since we only use yang1 here but we do so to simplify the helper
        let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr());
        let (_, _, _, debt) = shrine.get_trove_info(TROVE_1);

        advance_prices_and_set_multiplier(shrine_addr, get_block_timestamp(), yang1_price, yang2_price);

        let end_interval: u64 = start_interval + FEED_LEN - 1;
        assert(now() == end_interval + 1, 'wrong end interval');  // sanity check

        let (_, start_cumulative_price) = shrine.get_yang_price(yang1_addr, start_interval);
        let (_, start_cumulative_multiplier) = shrine.get_multiplier(start_interval);
        let (_, end_cumulative_price) = shrine.get_yang_price(yang1_addr, end_interval);
        let (_, end_cumulative_multiplier) = shrine.get_multiplier(end_interval);
        let feed_len: u128 = FEED_LEN.into();

        let expected_avg_price: Wad = ((end_cumulative_price - start_cumulative_price).val / feed_len).into();
        let expected_avg_multiplier: Ray = ((end_cumulative_multiplier - start_cumulative_multiplier).val / feed_len).into();

        // set up arrays for `compound` helper function
        let mut yang_base_rates_history: Array<Span<Ray>> = ArrayTrait::new();
        let mut yang1_base_rate_history: Array<Ray> = ArrayTrait::new();
        yang1_base_rate_history.append(YANG1_BASE_RATE.into());
        yang_base_rates_history.append(yang1_base_rate_history.span());

        let mut yang_rate_update_intervals: Array<u64> = ArrayTrait::new();
        yang_rate_update_intervals.append(deployment_interval());

        let mut yang_amts: Array<Wad> = ArrayTrait::new();
        yang_amts.append(TROVE1_YANG1_DEPOSIT.into());

        let mut yang_avg_prices: Array<Span<Wad>> = ArrayTrait::new();
        let mut yang1_avg_prices: Array<Wad> = ArrayTrait::new();
        yang1_avg_prices.append(expected_avg_price);
        yang_avg_prices.append(yang1_avg_prices.span());

        let mut avg_multipliers: Array<Ray> = ArrayTrait::new();
        avg_multipliers.append(RAY_SCALE.into());

        let expected_debt: Wad = compound(
            yang_base_rates_history.span(),
            yang_rate_update_intervals.span(),
            yang_amts.span(),
            yang_avg_prices.span(),
            avg_multipliers.span(),
            start_interval,
            end_interval,
            debt,
        );
        let (_, _, _, estimated_debt) = shrine.get_trove_info(TROVE_1);
        assert(estimated_debt == expected_debt, 'wrong compounded debt');

        // Trigger charge and check interest is accrued
        shrine.melt(trove1_owner_addr(), TROVE_1, WadZeroable::zero());
        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');
    }

    //
    // Tests - Yin transfers
    //

    //
    // Tests - Price and multiplier
    //

    //
    // Tests - Getters for trove information
    //

    //
    // Tests - Getters for shrine threshold and value
    //
}
