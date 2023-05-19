#[cfg(test)]
mod TestShrine {
    use array::{ArrayTrait, SpanTrait};
    use integer::downcast;
    use option::OptionTrait;
    use traits::{Into, TryInto};
    use starknet::{contract_address_const, deploy_syscall, ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_to_felt252, SyscallResultTrait};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_caller_address, set_contract_address, set_block_timestamp};

    use aura::core::shrine::Shrine;
    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::serde;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RAY_ONE, RAY_SCALE, U128IntoRay, U128IntoWad, Wad, WAD_DECIMALS};

    // Arbitrary timestamp set to approximately 18 May 2023, 7:55:28am UTC
    const DEPLOYMENT_TIMESTAMP: u64 = 1684390000_u64;

    // Number of seconds in an interval
    // 30 minutes * 60 seconds
    const TIME_INTERVAL: u64 = 1800;

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

    //
    // Helpers
    // 

    // Returns the interval ID for the given timestamp
    #[inline(always)]
    fn get_interval(timestamp: u64) -> u64 {
        timestamp / TIME_INTERVAL
    }

    fn generate_yang_feed(price: Wad) -> Span<Wad> {
        let mut prices: Array<Wad> = ArrayTrait::new();
        let mut price: Wad = price.into();
        let mut idx: u64 = 0;
        loop {
            if idx == FEED_LEN {
                break prices.span();
            }

            let price = wadray::rmul_wr(price, PRICE_CHANGE.into());
            prices.append(price);

            idx += 1;
        }
    }

    //
    // Test setup
    //

    fn admin() -> ContractAddress {
        contract_address_const::<0x1337>()
    }

    fn mock_multiplier() -> ContractAddress {
        contract_address_const::<0x1111>()
    }

    fn mock_oracle() -> ContractAddress {
        contract_address_const::<0x2222>()
    }

    fn yang1_addr() -> ContractAddress {
        contract_address_const::<0x1234>()
    }

    fn yang2_addr() -> ContractAddress {
        contract_address_const::<0x2345>()
    }

    fn yang1_feed() -> Span<Wad> {
        generate_yang_feed(YANG1_START_PRICE.into())
    }

    fn yang2_feed() -> Span<Wad> {
        generate_yang_feed(YANG2_START_PRICE.into())
    }

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
        let admin_role: u128 = ShrineRoles::default_admin_role();
        set_contract_address(admin);
        shrine_accesscontrol.grant_role(admin_role, admin);
        
        // Set debt ceiling
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine_addr };
        shrine.set_ceiling(DEBT_CEILING.into());

        // Add yangs
        shrine.add_yang(yang1_addr(), YANG1_THRESHOLD.into(), YANG1_START_PRICE.into(), YANG1_BASE_RATE.into(), INITIAL_YANG_AMT.into());
        shrine.add_yang(yang2_addr(), YANG2_THRESHOLD.into(), YANG2_START_PRICE.into(), YANG2_BASE_RATE.into(), INITIAL_YANG_AMT.into());
    }

    fn shrine_with_feeds(shrine_addr: ContractAddress) -> (Span<ContractAddress>, Span<Span<Wad>>){
        let shrine_accesscontrol: IAccessControlDispatcher = IAccessControlDispatcher { contract_address: shrine_addr };

        let admin: ContractAddress = admin();
        let mock_oracle: ContractAddress = mock_oracle();
        set_contract_address(admin);
        shrine_accesscontrol.grant_role(ShrineRoles::ADVANCE, mock_oracle);

        let mock_multiplier: ContractAddress = mock_multiplier();
        shrine_accesscontrol.grant_role(ShrineRoles::SET_MULTIPLIER, mock_multiplier);


        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine_addr };
        
        let yang1_addr: ContractAddress = yang1_addr();
        let yang1_feed: Span<Wad> = yang1_feed();

        let yang2_addr: ContractAddress = yang2_addr();
        let yang2_feed: Span<Wad> = yang2_feed();

        let mut yang_addrs: Array<ContractAddress> = ArrayTrait::new();
        yang_addrs.append(yang1_addr);
        yang_addrs.append(yang2_addr);

        let mut yang_feeds: Array<Span<Wad>> = ArrayTrait::new();
        yang_feeds.append(yang1_feed);
        yang_feeds.append(yang2_feed);
        
        let mut idx: u32 = 0;
        loop {
            if idx == downcast(FEED_LEN).unwrap() {
                break ();
            }

            let timestamp: u64 = DEPLOYMENT_TIMESTAMP + (idx.into() * TIME_INTERVAL);
            set_block_timestamp(timestamp);

            set_contract_address(mock_oracle);
            shrine.advance(yang1_addr, *yang1_feed[idx]);
            shrine.advance(yang2_addr, *yang2_feed[idx]);

            set_contract_address(mock_multiplier);
            shrine.set_multiplier(RAY_ONE.into());

            idx += 1;
        };

        (yang_addrs.span(), yang_feeds.span())
    }

    //
    // Tests
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
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine_addr };
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
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine_addr };
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
        assert(threshold == 0_u128.into(), 'wrong shrine threshold');
        assert(value == 0_u128.into(), 'wrong shrine value');
    }

    // Checks `advance` and `set_multiplier`, and their cumulative values
    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_setup_with_feed() {
        let shrine_addr: ContractAddress = shrine_deploy();
        shrine_setup(shrine_addr);
        let (yang_addrs, yang_feeds) = shrine_with_feeds(shrine_addr);
        let mut yang_addrs = yang_addrs;
        let mut yang_feeds = yang_feeds;

        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine_addr };

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
}
