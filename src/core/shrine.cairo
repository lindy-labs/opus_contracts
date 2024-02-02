#[starknet::contract]
mod shrine {
    use access_control::access_control_component;
    use cmp::{max, min};
    use core::starknet::event::EventEmitter;
    use integer::{BoundedU256, U256Zeroable, u256_safe_div_rem};
    use opus::core::roles::shrine_roles;
    use opus::interfaces::IERC20::{IERC20, IERC20CamelOnly};
    use opus::interfaces::ISRC5::ISRC5;
    use opus::interfaces::IShrine::IShrine;
    use opus::types::{Health, Trove, YangBalance, YangSuspensionStatus};
    use opus::utils::exp::{exp, neg_exp};
    use starknet::contract_address::{ContractAddress, ContractAddressZeroable};
    use starknet::{get_block_timestamp, get_caller_address};
    use wadray::{
        BoundedRay, Ray, RayZeroable, RAY_ONE, Signed, SignedWad, Wad, WadZeroable, WAD_DECIMALS, WAD_ONE, WAD_SCALE
    };

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    //
    // Constants
    //

    // Initial multiplier value to ensure `get_recent_multiplier_from` terminates - (ray): RAY_ONE
    const INITIAL_MULTIPLIER: u128 = 1000000000000000000000000000;
    const MAX_MULTIPLIER: u128 = 10000000000000000000000000000; // Max of 10x (ray): 10 * RAY_ONE

    const MAX_THRESHOLD: u128 = 1000000000000000000000000000; // (ray): RAY_ONE

    // If a yang is deemed risky, it can be marked as suspended. During the
    // SUSPENSION_GRACE_PERIOD, this decision can be reverted and the yang's status
    // can be changed back to normal. If this does not happen, the yang is
    // suspended permanently, i.e. can't be used in the system ever again.
    // The start of a Yang's suspension period is tracked in `yang_suspension`
    const SUSPENSION_GRACE_PERIOD: u64 =
        consteval_int!((182 * 24 + 12) * 60 * 60); // 182.5 days, half a year, in seconds

    // Length of a time interval in seconds
    const TIME_INTERVAL: u64 = consteval_int!(30 * 60); // 30 minutes * 60 seconds per minute
    const TIME_INTERVAL_DIV_YEAR: u128 =
        57077625570776; // 1 / (48 30-minute intervals per day) / (365 days per year) = 0.000057077625 (wad)

    // Threshold for rounding remaining debt during redistribution (wad): 10**9
    const ROUNDING_THRESHOLD: u128 = 1000000000;

    // Minimum amount of yang that must be in recipient troves for ordinary
    // redistribution of yang to occur without overflow (wad): WAD_ONE
    const MIN_RECIPIENT_YANG_AMT: u128 = 1000000000000000000;

    // Maximum interest rate a yang can have (ray): RAY_ONE
    const MAX_YANG_RATE: u128 = 1000000000000000000000000000;

    // Flag for setting the yang's new base rate to its previous base rate in `update_rates`
    // (ray): MAX_YANG_RATE + 1
    const USE_PREV_BASE_RATE: u128 = 1000000000000000000000000001;

    // Forge fee function parameters
    const FORGE_FEE_A: u128 = 92103403719761827360719658187; // 92.103403719761827360719658187 (ray)
    const FORGE_FEE_B: u128 = 55000000000000000; // 0.055 (wad)
    // The lowest yin spot price where the forge fee will still be zero
    const MIN_ZERO_FEE_YIN_PRICE: u128 = 995000000000000000; // 0.995 (wad)
    // The maximum forge fee as a percentage of forge amount
    const FORGE_FEE_CAP_PCT: u128 = 4000000000000000000; // 400% or 4 (wad)
    // The maximum deviation before `FORGE_FEE_CAP_PCT` is reached
    const FORGE_FEE_CAP_PRICE: u128 = 929900000000000000; // 0.9299 (wad)

    // Convenience constant for upward iteration of yangs
    const START_YANG_IDX: u32 = 1;

    const RECOVERY_MODE_THRESHOLD_MULTIPLIER: u128 = 700000000000000000000000000; // 0.7 (ray)

    // Factor that scales how much thresholds decline during recovery mode
    const THRESHOLD_DECREASE_FACTOR: u128 = 1000000000000000000000000000; // 1 (ray)

    // SRC5 interface constants
    const ISRC5_ID: felt252 = 0x3f918d17e5ee77373b56385708f855659a07f75997f365cf87748628532a055;
    const IERC20_ID: felt252 = 0x10a8f9ff27838cf36e9599878726d548a5c5c1acb0d7e04e99372cbb79f730b;
    const IERC20_CAMEL_ID: felt252 = 0x2be91edd4cf1388a08c3612416baf85deb00e47d840e6d645f248c8ab64a4ab;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        // A trove can forge debt up to its threshold depending on the yangs deposited.
        // (trove_id) -> (Trove)
        troves: LegacyMap::<u64, Trove>,
        // Stores the amount of the "yin" (synthetic) each user owns.
        // (user_address) -> (Yin)
        yin: LegacyMap::<ContractAddress, Wad>,
        // Stores information about the total supply for each yang
        // (yang_id) -> (Total Supply)
        yang_total: LegacyMap::<u32, Wad>,
        // Stores information about the initial yang amount minted to the system
        initial_yang_amts: LegacyMap::<u32, Wad>,
        // Number of collateral types accepted by the system.
        // The return value is also the ID of the last added collateral.
        yangs_count: u32,
        // Mapping from yang ContractAddress to yang ID.
        // Yang ID starts at 1.
        // (yang_address) -> (yang_id)
        yang_ids: LegacyMap::<ContractAddress, u32>,
        // Keeps track of how much of each yang has been deposited into each Trove - Wad
        // (yang_id, trove_id) -> (Amount Deposited)
        deposits: LegacyMap::<(u32, u64), Wad>,
        // Total amount of debt accrued for troves
        // This includes any debt surplus already accounted for in the budget.
        total_troves_debt: Wad,
        // Amount of deficit from exceptionally redistributed trove's debt
        // This amount is included in the budget.
        total_troves_deficit: SignedWad,
        // Total amount of synthetic forged and injected
        total_yin: Wad,
        // Current budget
        // - If amount is negative, then there is a deficit i.e. `total_yin` > total debt
        //   There is more yin in circulation than yin that needs to be repaid.
        // - If amount is positive, then there is a surplus i.e. total debt > `total_yin`
        //   There is more yin that needs to be repaid than in circulation.
        // based on current on-chain conditions
        budget: SignedWad,
        // Keeps track of the price history of each Yang
        // Stores both the actual price and the cumulative price of
        // the yang at each time interval, both as Wads.
        // - interval: timestamp divided by TIME_INTERVAL.
        // (yang_id, interval) -> (price, cumulative_price)
        yang_prices: LegacyMap::<(u32, u64), (Wad, Wad)>,
        // Spot price of yin
        yin_spot_price: Wad,
        // Minimum value for a trove before a user can forge any debt
        minimum_trove_value: Wad,
        // Maximum amount of yin that can be generated. Once this ceiling is exceeded, the
        // creation of new yin by users should be disallowed.
        // - If the budget is positive, a user may create new yin only if the resulting total
        //   yin amount and any debt surpluses is less than or equal to the ceiling.
        // - If the budget is neutral or negative, a user may create new yin only if the resulting
        //   total yin amount is less than the ceiling.
        //
        // Note that this does not  prevent interest from accruing or the budget from accruing
        // a surplus, and positive budgets can still be minted as yin. Therefore, it is possible
        // for the total amount of yin to exceed the debt ceiling.
        debt_ceiling: Wad,
        // Global interest rate multiplier
        // stores both the actual multiplier, and the cumulative multiplier of
        // the yang at each time interval, both as Rays
        // (interval) -> (multiplier, cumulative_multiplier)
        multiplier: LegacyMap::<u64, (Ray, Ray)>,
        // Keeps track of the most recent rates index.
        // Rate era starts at 1.
        // Each index is associated with an update to the interest rates of all yangs.
        rates_latest_era: u64,
        // Keeps track of the interval at which the rate update at `era` was made.
        // (era) -> (interval)
        rates_intervals: LegacyMap::<u64, u64>,
        // Keeps track of the interest rate of each yang at each era
        // (yang_id, era) -> (Interest Rate)
        yang_rates: LegacyMap::<(u32, u64), Ray>,
        // Keeps track of when a yang was suspended
        // 0 means it is not suspended
        // (yang_id) -> (suspension timestamp)
        yang_suspension: LegacyMap::<u32, u64>,
        // Liquidation threshold per yang (as LTV) - Ray
        // NOTE: don't read the value directly, instead use `get_yang_threshold_helper`
        //       because a yang might be suspended; the function will return the correct
        //       threshold value under all circumstances
        // (yang_id) -> (Liquidation Threshold)
        thresholds: LegacyMap::<u32, Ray>,
        // Keeps track of how many redistributions have occurred
        redistributions_count: u32,
        // Last redistribution accounted for a trove
        // (trove_id) -> (Last Redistribution ID)
        trove_redistribution_id: LegacyMap::<u64, u32>,
        // Mapping of yang ID and redistribution ID to amount of debt in Wad to be redistributed 
        // to each Wad unit of yang
        // (yang_id, redistribution_id) -> debt_per_wad
        yang_redistributions: LegacyMap::<(u32, u32), Wad>,
        // Keeps track of whether shrine is live or killed
        is_live: bool,
        // Yin storage
        yin_name: felt252,
        yin_symbol: felt252,
        yin_decimals: u8,
        // Mapping of user's yin allowance for another user
        // (user_address, spender_address) -> (Allowance)
        yin_allowances: LegacyMap::<(ContractAddress, ContractAddress), u256>,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AccessControlEvent: access_control_component::Event,
        YangAdded: YangAdded,
        YangTotalUpdated: YangTotalUpdated,
        TotalTrovesDebtUpdated: TotalTrovesDebtUpdated,
        TotalTrovesDeficitUpdated: TotalTrovesDeficitUpdated,
        BudgetAdjusted: BudgetAdjusted,
        MultiplierUpdated: MultiplierUpdated,
        YangRatesUpdated: YangRatesUpdated,
        ThresholdUpdated: ThresholdUpdated,
        ForgeFeePaid: ForgeFeePaid,
        TroveUpdated: TroveUpdated,
        TroveRedistributed: TroveRedistributed,
        DepositUpdated: DepositUpdated,
        YangPriceUpdated: YangPriceUpdated,
        YinPriceUpdated: YinPriceUpdated,
        MinimumTroveValueUpdated: MinimumTroveValueUpdated,
        DebtCeilingUpdated: DebtCeilingUpdated,
        YangSuspended: YangSuspended,
        YangUnsuspended: YangUnsuspended,
        Killed: Killed,
        Transfer: Transfer,
        Approval: Approval,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct YangAdded {
        #[key]
        yang: ContractAddress,
        yang_id: u32,
        start_price: Wad,
        initial_rate: Ray
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct YangTotalUpdated {
        #[key]
        yang: ContractAddress,
        total: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct TotalTrovesDebtUpdated {
        total: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct TotalTrovesDeficitUpdated {
        total: SignedWad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct BudgetAdjusted {
        amount: SignedWad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct MultiplierUpdated {
        multiplier: Ray,
        cumulative_multiplier: Ray,
        #[key]
        interval: u64
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct YangRatesUpdated {
        #[key]
        rate_era: u64,
        current_interval: u64,
        yangs: Span<ContractAddress>,
        new_rates: Span<Ray>
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct ThresholdUpdated {
        #[key]
        yang: ContractAddress,
        threshold: Ray
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct ForgeFeePaid {
        #[key]
        trove_id: u64,
        fee: Wad,
        fee_pct: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct TroveUpdated {
        #[key]
        trove_id: u64,
        trove: Trove
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct TroveRedistributed {
        #[key]
        redistribution_id: u32,
        #[key]
        trove_id: u64,
        debt: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct DepositUpdated {
        #[key]
        yang: ContractAddress,
        #[key]
        trove_id: u64,
        amount: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct YangPriceUpdated {
        #[key]
        yang: ContractAddress,
        price: Wad,
        cumulative_price: Wad,
        #[key]
        interval: u64
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct YinPriceUpdated {
        old_price: Wad,
        new_price: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct MinimumTroveValueUpdated {
        value: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct DebtCeilingUpdated {
        ceiling: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct YangSuspended {
        #[key]
        yang: ContractAddress,
        timestamp: u64
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct YangUnsuspended {
        #[key]
        yang: ContractAddress,
        timestamp: u64
    }


    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Killed {}

    // ERC20 events

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Transfer {
        #[key]
        from: ContractAddress,
        #[key]
        to: ContractAddress,
        value: u256
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Approval {
        #[key]
        owner: ContractAddress,
        #[key]
        spender: ContractAddress,
        value: u256
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress, name: felt252, symbol: felt252) {
        self.access_control.initializer(admin, Option::Some(shrine_roles::default_admin_role()));

        self.is_live.write(true);

        // Seeding initial multiplier to the previous interval to ensure `get_recent_multiplier_from` terminates
        // otherwise, the next multiplier update will run into an endless loop of `get_recent_multiplier_from`
        // since it wouldn't find the initial multiplier
        let prev_interval: u64 = now() - 1;
        let init_multiplier: Ray = INITIAL_MULTIPLIER.into();
        self.multiplier.write(prev_interval, (init_multiplier, init_multiplier));

        // Setting initial rate era to 1
        self.rates_latest_era.write(1);

        // Setting initial yin spot price to 1
        self.yin_spot_price.write(WAD_ONE.into());

        // Emit event
        self
            .emit(
                MultiplierUpdated {
                    multiplier: init_multiplier, cumulative_multiplier: init_multiplier, interval: prev_interval
                }
            );

        // ERC20
        self.yin_name.write(name);
        self.yin_symbol.write(symbol);
        self.yin_decimals.write(WAD_DECIMALS);
    }

    //
    // External Shrine functions
    //

    #[abi(embed_v0)]
    impl IShrineImpl of IShrine<ContractState> {
        //
        // Getters
        //

        fn get_yin(self: @ContractState, user: ContractAddress) -> Wad {
            self.yin.read(user)
        }

        fn get_total_yin(self: @ContractState) -> Wad {
            self.total_yin.read()
        }

        // Get yin spot price
        fn get_yin_spot_price(self: @ContractState) -> Wad {
            self.yin_spot_price.read()
        }

        fn get_yang_total(self: @ContractState, yang: ContractAddress) -> Wad {
            let yang_id: u32 = self.get_valid_yang_id(yang);
            self.yang_total.read(yang_id)
        }

        fn get_initial_yang_amt(self: @ContractState, yang: ContractAddress) -> Wad {
            let yang_id: u32 = self.get_valid_yang_id(yang);
            self.initial_yang_amts.read(yang_id)
        }

        fn get_yangs_count(self: @ContractState) -> u32 {
            self.yangs_count.read()
        }

        fn get_deposit(self: @ContractState, yang: ContractAddress, trove_id: u64) -> Wad {
            let yang_id: u32 = self.get_valid_yang_id(yang);
            self.deposits.read((yang_id, trove_id))
        }

        fn get_budget(self: @ContractState) -> SignedWad {
            self.budget.read()
        }

        fn get_total_troves_deficit(self: @ContractState) -> SignedWad {
            self.total_troves_deficit.read()
        }

        fn get_yang_price(self: @ContractState, yang: ContractAddress, interval: u64) -> (Wad, Wad) {
            let yang_id: u32 = self.get_valid_yang_id(yang);
            self.yang_prices.read((yang_id, interval))
        }

        fn get_yang_rate(self: @ContractState, yang: ContractAddress, rate_era: u64) -> Ray {
            let yang_id: u32 = self.get_valid_yang_id(yang);
            self.yang_rates.read((yang_id, rate_era))
        }

        fn get_current_rate_era(self: @ContractState) -> u64 {
            self.rates_latest_era.read()
        }

        fn get_minimum_trove_value(self: @ContractState) -> Wad {
            self.minimum_trove_value.read()
        }

        fn get_debt_ceiling(self: @ContractState) -> Wad {
            self.debt_ceiling.read()
        }

        fn get_multiplier(self: @ContractState, interval: u64) -> (Ray, Ray) {
            self.multiplier.read(interval)
        }

        fn get_yang_suspension_status(self: @ContractState, yang: ContractAddress) -> YangSuspensionStatus {
            let yang_id: u32 = self.get_valid_yang_id(yang);
            self.get_yang_suspension_status_helper(yang_id)
        }

        // Returns a tuple of
        // 1. The "raw yang threshold"
        // 2. The "scaled yang threshold" for recovery mode
        // 1 and 2 will be the same if recovery mode is not in effect
        fn get_yang_threshold(self: @ContractState, yang: ContractAddress) -> (Ray, Ray) {
            let yang_id: u32 = self.get_valid_yang_id(yang);
            let threshold = self.get_yang_threshold_helper(yang_id);
            (threshold, self.scale_threshold_for_recovery_mode(threshold))
        }

        // Returns a Health struct comprising the Shrine's threshold, LTV, value and debt;
        fn get_shrine_health(self: @ContractState) -> Health {
            let (threshold, value) = self.get_threshold_and_value(self.get_shrine_deposits(), now());
            let debt: Wad = self.total_troves_debt.read();

            // If no collateral has been deposited, then shrine's LTV is
            // returned as the maximum possible value.
            let ltv: Ray = if value.is_zero() {
                BoundedRay::max()
            } else {
                wadray::rdiv_ww(debt, value)
            };

            Health { threshold, ltv, value, debt }
        }

        fn get_redistributions_count(self: @ContractState) -> u32 {
            self.redistributions_count.read()
        }

        fn get_trove_redistribution_id(self: @ContractState, trove_id: u64) -> u32 {
            self.trove_redistribution_id.read(trove_id)
        }

        fn get_redistribution_for_yang(self: @ContractState, yang: ContractAddress, redistribution_id: u32) -> Wad {
            let yang_id: u32 = self.get_valid_yang_id(yang);
            self.yang_redistributions.read((yang_id, redistribution_id))
        }

        fn is_recovery_mode(self: @ContractState) -> bool {
            let shrine_health: Health = self.get_shrine_health();
            self.is_recovery_mode_helper(shrine_health)
        }

        fn get_live(self: @ContractState) -> bool {
            self.is_live.read()
        }

        //
        // Setters - External
        //

        // `initial_yang_amt` is passed as an argument from upstream to address the issue of
        // first depositor front-running by requiring an initial deposit when adding the yang
        // to the Shrine
        fn add_yang(
            ref self: ContractState,
            yang: ContractAddress,
            threshold: Ray,
            start_price: Wad,
            initial_rate: Ray,
            initial_yang_amt: Wad
        ) {
            self.access_control.assert_has_role(shrine_roles::ADD_YANG);

            assert(self.yang_ids.read(yang) == 0, 'SH: Yang already exists');

            assert_rate_is_valid(initial_rate);

            // Assign new ID to yang and add yang struct
            let yang_id: u32 = self.yangs_count.read() + 1;
            self.yang_ids.write(yang, yang_id);

            // Update yangs count
            self.yangs_count.write(yang_id);

            // Set threshold
            self.set_threshold_helper(yang, threshold);

            // Update initial yang supply
            // Used upstream to prevent first depositor front running
            self.yang_total.write(yang_id, initial_yang_amt);
            self.initial_yang_amts.write(yang_id, initial_yang_amt);

            // Since `start_price` is the first price in the price history, the cumulative price is also set to `start_price`

            let prev_interval: u64 = now() - 1;
            // seeding initial price to the previous interval to ensure `get_recent_price_from` terminates
            // new prices are pushed to Shrine from an oracle via `advance` and are always set on the current
            // interval (`now()`); if we wouldn't set this initial price to `now() - 1` and oracle could
            // update a price still in the current interval (as oracle update times are independent of
            // Shrine's intervals, a price can be updated multiple times in a single interval) which would
            // result in an endless loop of `get_recent_price_from` since it wouldn't find the initial price
            self.yang_prices.write((yang_id, prev_interval), (start_price, start_price));

            // Setting the base rate for the new yang

            // NOTE: Eras are not incremented when a new yang is added, and the era that is being set
            // for this base rate will have an interval that is <= now(). This would be a problem
            // if there could be a trove containing the newly-added with `trove.last_rate_era < latest_era`.
            // Luckily, this isn't possible because `charge` is called in `deposit`, so a trove's `last_rate_era`
            // will always be updated to `latest_era` immediately before the newly-added yang is deposited.
            let latest_era: u64 = self.rates_latest_era.read();
            self.yang_rates.write((yang_id, latest_era), initial_rate);

            // Event emissions
            self.emit(YangAdded { yang, yang_id, start_price, initial_rate });
            self.emit(YangTotalUpdated { yang, total: initial_yang_amt });
        }

        fn set_threshold(ref self: ContractState, yang: ContractAddress, new_threshold: Ray) {
            self.access_control.assert_has_role(shrine_roles::SET_THRESHOLD);

            self.set_threshold_helper(yang, new_threshold);
        }

        fn suspend_yang(ref self: ContractState, yang: ContractAddress) {
            self.access_control.assert_has_role(shrine_roles::UPDATE_YANG_SUSPENSION);

            assert(self.get_yang_suspension_status(yang) == YangSuspensionStatus::None, 'SH: Already suspended');

            let timestamp: u64 = get_block_timestamp();
            self.yang_suspension.write(self.get_valid_yang_id(yang), timestamp);
            self.emit(YangSuspended { yang, timestamp });
        }

        fn unsuspend_yang(ref self: ContractState, yang: ContractAddress) {
            self.access_control.assert_has_role(shrine_roles::UPDATE_YANG_SUSPENSION);

            assert(
                self.get_yang_suspension_status(yang) != YangSuspensionStatus::Permanent, 'SH: Suspension is permanent'
            );

            self.yang_suspension.write(self.get_valid_yang_id(yang), 0);
            self.emit(YangUnsuspended { yang, timestamp: get_block_timestamp() });
        }

        // Update the base rates of all yangs
        // A base rate of USE_PREV_BASE_RATE means the base rate for the yang stays the same
        // Takes an array of yangs and their updated rates.
        // yangs[i]'s base rate will be set to new_rates[i]
        // yangs's length must equal the number of yangs available.
        fn update_rates(ref self: ContractState, yangs: Span<ContractAddress>, new_rates: Span<Ray>) {
            self.access_control.assert_has_role(shrine_roles::UPDATE_RATES);

            let yangs_len = yangs.len();
            let num_yangs: u32 = self.yangs_count.read();

            assert(yangs_len == num_yangs, 'SH: Too few yangs');
            assert(yangs_len == new_rates.len(), 'SH: yangs.len != new_rates.len');

            let latest_rate_era: u64 = self.rates_latest_era.read();
            let latest_rate_era_interval: u64 = self.rates_intervals.read(latest_rate_era);
            let current_interval: u64 = now();

            // If the interest rates were already updated in the current interval, don't increment the era
            // Otherwise, increment the era
            // This way, there is at most one set of base rate updates in every interval
            let mut rate_era = latest_rate_era;

            if latest_rate_era_interval != current_interval {
                rate_era += 1;
                self.rates_latest_era.write(rate_era);
                self.rates_intervals.write(rate_era, current_interval);
            }

            // ALL yangs must have a new rate value. A new rate value of `USE_PREV_BASE_RATE` means the
            // yang's rate isn't being updated, and so we get the previous value.
            let mut yangs_copy = yangs;
            let mut new_rates_copy = new_rates;
            // TODO: temporary workaround for issue with borrowing snapshots in loops
            let self_snap = @self;
            loop {
                match new_rates_copy.pop_front() {
                    Option::Some(rate) => {
                        let current_yang_id: u32 = self_snap.get_valid_yang_id(*yangs_copy.pop_front().unwrap());
                        if *rate.val == USE_PREV_BASE_RATE {
                            // Setting new era rate to the previous era's rate
                            self
                                .yang_rates
                                .write(
                                    (current_yang_id, rate_era),
                                    self_snap.yang_rates.read((current_yang_id, rate_era - 1))
                                );
                        } else {
                            assert_rate_is_valid(*rate);
                            self.yang_rates.write((current_yang_id, rate_era), *rate);
                        }
                    },
                    Option::None => { break; }
                };
            };

            // Verify that all rates were updated correctly
            // This is necessary because we don't enforce that the `yangs` array really contains
            // every single yang, only that its length is the same as the number of yangs.
            // For all we know, `yangs` could contain one yang address 10 times.
            // Even though this is an admin/governance function, such a mistake could break
            // interest rate calculations, which is why it's important that we verify that all yangs'
            // rates were correctly updated.
            let mut idx: u32 = num_yangs;
            loop {
                if idx == 0 {
                    break ();
                }
                assert(self.yang_rates.read((idx, rate_era)).is_non_zero(), 'SH: Incorrect rate update');
                idx -= 1;
            };

            self.emit(YangRatesUpdated { rate_era, current_interval, yangs, new_rates });
        }

        // Set the price of the specified Yang for the current interval interval
        fn advance(ref self: ContractState, yang: ContractAddress, price: Wad) {
            self.access_control.assert_has_role(shrine_roles::ADVANCE);

            assert(price.is_non_zero(), 'SH: Price cannot be 0');

            let interval: u64 = now();
            let yang_id: u32 = self.get_valid_yang_id(yang);

            // Calculating the new cumulative price
            // To do this, we get the interval of the last price update, find the number of
            // intervals BETWEEN the current interval and the last_interval (non-inclusive), multiply that by
            // the last price, and add it to the last cumulative price. Then we add the new price, `price`,
            // for the current interval.
            let (last_price, last_cumulative_price, last_interval) = self.get_recent_price_from(yang_id, interval - 1);

            let cumulative_price: Wad = last_cumulative_price
                + (last_price.val * (interval - last_interval - 1).into()).into()
                + price;

            self.yang_prices.write((yang_id, interval), (price, cumulative_price));
            self.emit(YangPriceUpdated { yang, price, cumulative_price, interval });
        }

        // Sets the multiplier for the current interval
        fn set_multiplier(ref self: ContractState, multiplier: Ray) {
            self.access_control.assert_has_role(shrine_roles::SET_MULTIPLIER);

            assert(multiplier.is_non_zero(), 'SH: Multiplier cannot be 0');
            assert(multiplier.val <= MAX_MULTIPLIER, 'SH: Multiplier exceeds maximum');

            let interval: u64 = now();
            let (last_multiplier, last_cumulative_multiplier, last_interval) = self
                .get_recent_multiplier_from(interval - 1);

            let cumulative_multiplier = last_cumulative_multiplier
                + ((interval - last_interval - 1).into() * last_multiplier.val).into()
                + multiplier;
            self.multiplier.write(interval, (multiplier, cumulative_multiplier));

            self.emit(MultiplierUpdated { multiplier, cumulative_multiplier, interval });
        }

        fn set_minimum_trove_value(ref self: ContractState, value: Wad) {
            self.access_control.assert_has_role(shrine_roles::SET_MINIMUM_TROVE_VALUE);

            self.minimum_trove_value.write(value);

            // Event emission
            self.emit(MinimumTroveValueUpdated { value });
        }

        fn set_debt_ceiling(ref self: ContractState, ceiling: Wad) {
            self.access_control.assert_has_role(shrine_roles::SET_DEBT_CEILING);
            self.debt_ceiling.write(ceiling);

            //Event emission
            self.emit(DebtCeilingUpdated { ceiling });
        }

        fn adjust_budget(ref self: ContractState, amount: SignedWad) {
            self.access_control.assert_has_role(shrine_roles::ADJUST_BUDGET);

            self.adjust_budget_helper(amount);
        }

        // Updates spot price of yin
        //
        // Shrine denominates all prices (including that of yin) in yin, meaning yin's peg/target price is 1 (wad).
        // Therefore, it's expected that the spot price is denominated in yin, in order to
        // get the true deviation of the spot price from the peg/target price.
        fn update_yin_spot_price(ref self: ContractState, new_price: Wad) {
            self.access_control.assert_has_role(shrine_roles::UPDATE_YIN_SPOT_PRICE);
            self.emit(YinPriceUpdated { old_price: self.yin_spot_price.read(), new_price });
            self.yin_spot_price.write(new_price);
        }

        fn kill(ref self: ContractState) {
            self.access_control.assert_has_role(shrine_roles::KILL);
            self.is_live.write(false);

            // Event emission
            self.emit(Killed {});
        }

        //
        // Core Functions - External
        //

        // Deposit a specified amount of a Yang into a Trove
        fn deposit(ref self: ContractState, yang: ContractAddress, trove_id: u64, amount: Wad) {
            self.access_control.assert_has_role(shrine_roles::DEPOSIT);

            self.assert_live();

            self.charge(trove_id);

            let yang_id: u32 = self.get_valid_yang_id(yang);

            // Update yang balance of system
            let new_total: Wad = self.yang_total.read(yang_id) + amount;
            self.yang_total.write(yang_id, new_total);

            // Update trove balance
            let new_trove_balance: Wad = self.deposits.read((yang_id, trove_id)) + amount;
            self.deposits.write((yang_id, trove_id), new_trove_balance);

            // Events
            self.emit(YangTotalUpdated { yang, total: new_total });
            self.emit(DepositUpdated { yang, trove_id, amount: new_trove_balance });
        }

        // Withdraw a specified amount of a Yang from a Trove with trove safety check
        fn withdraw(ref self: ContractState, yang: ContractAddress, trove_id: u64, amount: Wad) {
            self.access_control.assert_has_role(shrine_roles::WITHDRAW);
            // In the event the Shrine is killed, trove users can no longer withdraw yang
            // via the Abbot. Withdrawal of excess yang will be via the Caretaker instead.
            self.assert_live();
            self.withdraw_helper(yang, trove_id, amount);
            self.assert_valid_trove_action(trove_id);
        }

        // Mint a specified amount of synthetic and attribute the debt to a Trove
        fn forge(ref self: ContractState, user: ContractAddress, trove_id: u64, amount: Wad, max_forge_fee_pct: Wad) {
            self.access_control.assert_has_role(shrine_roles::FORGE);
            self.assert_live();

            self.charge(trove_id);

            let forge_fee_pct: Wad = self.get_forge_fee_pct();
            assert(forge_fee_pct <= max_forge_fee_pct, 'SH: forge_fee% > max_forge_fee%');

            let forge_fee = amount * forge_fee_pct;
            let debt_amount = amount + forge_fee;

            self.assert_le_debt_ceiling(self.total_yin.read() + amount, self.budget.read() + forge_fee.into());

            self.increment_total_troves_debt(debt_amount.into());

            // `Trove.charge_from` and `Trove.last_rate_era` were already updated in `charge`.
            let mut trove: Trove = self.troves.read(trove_id);
            trove.debt += debt_amount;
            self.troves.write(trove_id, trove);

            self.assert_valid_trove_action(trove_id);

            self.forge_helper(user, amount);

            // Events
            if forge_fee.is_non_zero() {
                self.adjust_budget_helper(forge_fee.into());
                self.emit(ForgeFeePaid { trove_id, fee: forge_fee, fee_pct: forge_fee_pct });
            }
            self.emit(TroveUpdated { trove_id, trove });
        }

        // Repay a specified amount of synthetic and deattribute the debt from a Trove
        fn melt(ref self: ContractState, user: ContractAddress, trove_id: u64, amount: Wad) {
            self.access_control.assert_has_role(shrine_roles::MELT);
            // In the event the Shrine is killed, trove users can no longer repay their debt.
            // This also blocks liquidations by Purger.
            self.assert_live();

            // Charge interest
            self.charge(trove_id);

            let mut trove: Trove = self.troves.read(trove_id);

            // If `amount` exceeds `trove.debt`, then melt all the debt.
            // This is nice for UX so that maximum debt can be melted without knowing the exact
            // of debt in the trove down to the 10**-18.
            let melt_amt: Wad = min(trove.debt, amount);
            let new_total_troves_debt: Wad = self.total_troves_debt.read() - melt_amt;
            self.total_troves_debt.write(new_total_troves_debt);

            // `Trove.charge_from` and `Trove.last_rate_era` were already updated in `charge`.
            trove.debt -= melt_amt;
            self.troves.write(trove_id, trove);

            // Update user balance
            self.melt_helper(user, melt_amt);

            // Events
            self.emit(TotalTrovesDebtUpdated { total: new_total_troves_debt });
            self.emit(TroveUpdated { trove_id, trove });
        }

        // Withdraw a specified amount of a Yang from a Trove without trove safety check.
        // This is intended for liquidations where collateral needs to be withdrawn and transferred to the liquidator
        // even if the trove is still unsafe.
        fn seize(ref self: ContractState, yang: ContractAddress, trove_id: u64, amount: Wad) {
            self.access_control.assert_has_role(shrine_roles::SEIZE);
            self.withdraw_helper(yang, trove_id, amount);
        }

        fn redistribute(
            ref self: ContractState, trove_id: u64, debt_to_redistribute: Wad, pct_value_to_redistribute: Ray
        ) {
            self.access_control.assert_has_role(shrine_roles::REDISTRIBUTE);
            assert(pct_value_to_redistribute <= RAY_ONE.into(), 'SH: pct_val_to_redistribute > 1');
            let current_interval: u64 = now();

            // Trove's debt should have been updated to the current interval via `melt` in `Purger.purge`.
            // The trove's debt is used instead of estimated debt from `get_trove_health` to ensure that
            // system has accounted for the accrued interest.
            let mut trove: Trove = self.troves.read(trove_id);

            // Increment redistribution ID
            let redistribution_id: u32 = self.redistributions_count.read() + 1;
            self.redistributions_count.write(redistribution_id);

            // Perform redistribution
            self
                .redistribute_helper(
                    redistribution_id, trove_id, debt_to_redistribute, pct_value_to_redistribute, current_interval
                );

            trove.charge_from = current_interval;
            // Note that this will revert if `debt_to_redistribute` exceeds the trove's debt.
            trove.debt -= debt_to_redistribute;
            self.troves.write(trove_id, trove);

            // Update the redistribution ID so that it is not possible for the redistributed
            // trove to receive any of its own redistribution in the event of a
            // redistribution of an amount less than the trove's debt.
            // Note that the trove's last redistribution ID needs to be updated to
            // `redistribution_id - 1` prior to calling `redistribute`.
            self.trove_redistribution_id.write(trove_id, redistribution_id);

            // Event
            self.emit(TroveRedistributed { redistribution_id, trove_id, debt: debt_to_redistribute });
        }

        // Mint a specified amount of synthetic without attributing the debt to a Trove
        fn inject(ref self: ContractState, receiver: ContractAddress, amount: Wad) {
            self.access_control.assert_has_role(shrine_roles::INJECT);
            // Prevent any debt creation, including via flash mints, once the Shrine is killed
            self.assert_live();

            self.assert_le_debt_ceiling(self.total_yin.read() + amount, self.budget.read());

            self.forge_helper(receiver, amount);
        }

        // Repay a specified amount of synthetic without deattributing the debt from a Trove
        fn eject(ref self: ContractState, burner: ContractAddress, amount: Wad) {
            self.access_control.assert_has_role(shrine_roles::EJECT);
            self.melt_helper(burner, amount);
        }

        //
        // Core Functions - View
        //

        // Get the last updated price for a yang
        fn get_current_yang_price(self: @ContractState, yang: ContractAddress) -> (Wad, Wad, u64) {
            self.get_recent_price_from(self.get_valid_yang_id(yang), now())
        }

        // Gets last updated multiplier value
        fn get_current_multiplier(self: @ContractState) -> (Ray, Ray, u64) {
            self.get_recent_multiplier_from(now())
        }

        // Returns the current forge fee
        // `forge_fee_pct` is a Wad and not Ray because the `exp` function
        // only returns Wads.
        #[inline(always)]
        fn get_forge_fee_pct(self: @ContractState) -> Wad {
            let yin_price: Wad = self.yin_spot_price.read();

            if yin_price >= MIN_ZERO_FEE_YIN_PRICE.into() {
                return WadZeroable::zero();
            } else if yin_price < FORGE_FEE_CAP_PRICE.into() {
                return FORGE_FEE_CAP_PCT.into();
            }

            // Won't underflow since yin_price < WAD_ONE
            let deviation: Wad = WAD_ONE.into() - yin_price;

            // This is a workaround since we don't yet have negative numbers
            if deviation >= FORGE_FEE_B.into() {
                exp(wadray::rmul_rw(FORGE_FEE_A.into(), deviation - FORGE_FEE_B.into()))
            } else {
                // `neg_exp` calculates e^(-x) given x.
                neg_exp(wadray::rmul_rw(FORGE_FEE_A.into(), FORGE_FEE_B.into() - deviation))
            }
        }

        // Returns a bool indicating whether the given trove is healthy or not
        fn is_healthy(self: @ContractState, trove_id: u64) -> bool {
            let health: Health = self.get_trove_health(trove_id);
            self.is_healthy_helper(health)
        }

        // Returns the maximum amount of yin that a trove can forge based on its current health.
        // Note that forging the return value from this getter may still revert in the following cases:
        // 1. forging the amount triggers recovery mode, causing the trove to be unsafe based on its
        //    recovery mode threshold instead of its usual threshold; or
        // 2. forging the amount causes the debt ceiling to be exceeded.
        fn get_max_forge(self: @ContractState, trove_id: u64) -> Wad {
            let health: Health = self.get_trove_health(trove_id);

            let forge_fee_pct: Wad = self.get_forge_fee_pct();
            let max_debt: Wad = wadray::rmul_rw(health.threshold, health.value);

            if health.debt < max_debt {
                return (max_debt - health.debt) / (WAD_ONE.into() + forge_fee_pct);
            }

            WadZeroable::zero()
        }

        // Returns a tuple of a trove's threshold, LTV based on compounded debt, trove value and compounded debt
        // Returns a Health struct comprising the trove's threshold, LTV based on compounded debt,
        // trove value and compounded debt;
        fn get_trove_health(self: @ContractState, trove_id: u64) -> Health {
            let interval: u64 = now();

            // Get threshold and trove value
            let trove_yang_balances: Span<YangBalance> = self.get_trove_deposits(trove_id);
            let (mut threshold, mut value) = self.get_threshold_and_value(trove_yang_balances, interval);
            threshold = self.scale_threshold_for_recovery_mode(threshold);

            let trove: Trove = self.troves.read(trove_id);

            // Catch troves with no value
            if value.is_zero() {
                // This `if` branch handles a corner case where a trove without any yangs deposited (i.e. zero value)
                // attempts to forge a non-zero debt. It ensures that the `assert_healthy` check in `forge` would
                // fail and revert.
                // - Without the check for `value.is_zero()` and `trove.debt.is_non_zero()`, the LTV calculation of
                //   of debt / value will run into a zero division error.
                // - With the check for `value.is_zero()` but without `trove.debt.is_non_zero()`, the LTV will be
                //   incorrectly set to 0 and the `assert_healthy` check will fail to catch this illegal operation.
                let ltv: Ray = if trove.debt.is_non_zero() {
                    BoundedRay::max()
                } else {
                    BoundedRay::min()
                };

                return Health { threshold, ltv, value, debt: trove.debt };
            }

            // Calculate debt
            let compounded_debt: Wad = self.compound(trove_id, trove, interval);
            let compounded_debt_with_redistributed_debt: Wad = compounded_debt
                + self.fetch_redistributed_debt(trove_id);

            let ltv: Ray = wadray::rdiv_ww(compounded_debt_with_redistributed_debt, value);

            Health { threshold, ltv, value, debt: compounded_debt_with_redistributed_debt }
        }

        fn get_redistributed_debt_for_trove(self: @ContractState, trove_id: u64) -> Wad {
            self.fetch_redistributed_debt(trove_id)
        }
    }

    //
    // Internal Shrine functions
    //

    #[generate_trait]
    impl ShrineHelpers of ShrineHelpersTrait {
        //
        // Helpers for assertions
        //

        // Check that system is live
        fn assert_live(self: @ContractState) {
            assert(self.is_live.read(), 'SH: System is not live');
        }

        #[inline(always)]
        fn is_healthy_helper(self: @ContractState, health: Health) -> bool {
            health.ltv <= health.threshold
        }

        // Checks that:
        // 1. the trove is healthy i.e. its LTV is equal to or lower than its threshold
        // 2. the trove has at least the minimum value if it has non-zero debt
        fn assert_valid_trove_action(self: @ContractState, trove_id: u64) {
            let health: Health = self.get_trove_health(trove_id);
            assert(self.is_healthy_helper(health), 'SH: Trove LTV is too high');
            if health.debt.is_non_zero() {
                assert(health.value >= self.minimum_trove_value.read(), 'SH: Below minimum trove value');
            }
        }

        // If the budget is positive, check that the new total amount of yin and any debt surpluses
        // is less than the debt ceiling. Otherwise, if the budget is negative (i.e. there is a deficit),
        // check that the new total amount of yin is less than the debt ceiling.
        fn assert_le_debt_ceiling(self: @ContractState, new_total_yin: Wad, new_budget: SignedWad) {
            let budget_adjustment: Wad = match new_budget.try_into() {
                Option::Some(surplus) => { surplus },
                Option::None => { WadZeroable::zero() }
            };
            let new_total_debt: Wad = new_total_yin + budget_adjustment;
            assert(new_total_debt <= self.debt_ceiling.read(), 'SH: Debt ceiling reached');
        }

        //
        // Helpers for getters and view functions
        //

        // Helper function to check if recovery mode is triggered for Shrine
        fn is_recovery_mode_helper(self: @ContractState, health: Health) -> bool {
            let recovery_mode_threshold: Ray = health.threshold * RECOVERY_MODE_THRESHOLD_MULTIPLIER.into();
            health.ltv >= recovery_mode_threshold
        }

        // Helper function to get the yang ID given a yang address, and throw an error if
        // yang address has not been added (i.e. yang ID = 0)
        fn get_valid_yang_id(self: @ContractState, yang: ContractAddress) -> u32 {
            let yang_id: u32 = self.yang_ids.read(yang);
            assert(yang_id != 0, 'SH: Yang does not exist');
            yang_id
        }

        // Returns the price for `yang_id` at `interval` if it is non-zero.
        // Otherwise, check `interval` - 1 recursively for the last available price.
        fn get_recent_price_from(self: @ContractState, yang_id: u32, interval: u64) -> (Wad, Wad, u64) {
            let (price, cumulative_price) = self.yang_prices.read((yang_id, interval));

            if price.is_non_zero() {
                return (price, cumulative_price, interval);
            }
            self.get_recent_price_from(yang_id, interval - 1)
        }

        // Returns the multiplier at `interval` if it is non-zero.
        // Otherwise, check `interval` - 1 recursively for the last available value.
        fn get_recent_multiplier_from(self: @ContractState, interval: u64) -> (Ray, Ray, u64) {
            let (multiplier, cumulative_multiplier) = self.multiplier.read(interval);
            if multiplier.is_non_zero() {
                return (multiplier, cumulative_multiplier, interval);
            }
            self.get_recent_multiplier_from(interval - 1)
        }

        // Helper function for applying the recovery mode threshold decrease to a threshold,
        // if recovery mode is active
        // The maximum threshold decrease is capped to 50% of the "base threshold"
        fn scale_threshold_for_recovery_mode(self: @ContractState, mut threshold: Ray) -> Ray {
            let shrine_health: Health = self.get_shrine_health();

            if self.is_recovery_mode_helper(shrine_health) {
                let recovery_mode_threshold: Ray = shrine_health.threshold * RECOVERY_MODE_THRESHOLD_MULTIPLIER.into();
                return max(
                    threshold * THRESHOLD_DECREASE_FACTOR.into() * (recovery_mode_threshold / shrine_health.ltv),
                    (threshold.val / 2_u128).into()
                );
            }

            threshold
        }

        fn get_yang_suspension_status_helper(self: @ContractState, yang_id: u32) -> YangSuspensionStatus {
            let suspension_ts: u64 = self.yang_suspension.read(yang_id);
            if suspension_ts.is_zero() {
                return YangSuspensionStatus::None;
            }

            if get_block_timestamp() - suspension_ts < SUSPENSION_GRACE_PERIOD {
                return YangSuspensionStatus::Temporary;
            }

            YangSuspensionStatus::Permanent
        }

        fn get_yang_threshold_helper(self: @ContractState, yang_id: u32) -> Ray {
            let base_threshold: Ray = self.thresholds.read(yang_id);
            match self.get_yang_suspension_status_helper(yang_id) {
                YangSuspensionStatus::None => { base_threshold },
                YangSuspensionStatus::Temporary => {
                    // linearly decrease the threshold from base_threshold to 0
                    // based on the time passed since suspension started
                    let ts_diff: u64 = get_block_timestamp() - self.yang_suspension.read(yang_id);
                    base_threshold * ((SUSPENSION_GRACE_PERIOD - ts_diff).into() / SUSPENSION_GRACE_PERIOD.into())
                },
                YangSuspensionStatus::Permanent => { RayZeroable::zero() },
            }
        }

        // Returns an ordered array of the `YangBalance` struct for a trove's deposits.
        // Starts from yang ID 1.
        // Note that zero values are added to the return array because downstream
        // computation assumes the full array of yangs.
        fn get_trove_deposits(self: @ContractState, trove_id: u64) -> Span<YangBalance> {
            let mut yang_balances: Array<YangBalance> = ArrayTrait::new();

            let mut current_yang_id: u32 = START_YANG_IDX;
            let loop_end: u32 = self.yangs_count.read() + START_YANG_IDX;
            loop {
                if current_yang_id == loop_end {
                    break yang_balances.span();
                }

                let deposited: Wad = self.deposits.read((current_yang_id, trove_id));
                yang_balances.append(YangBalance { yang_id: current_yang_id, amount: deposited });

                current_yang_id += 1;
            }
        }

        // Returns an ordered array of the `YangBalance` struct for the total deposited yangs in the Shrine.
        // Starts from yang ID 1.
        fn get_shrine_deposits(self: @ContractState) -> Span<YangBalance> {
            let mut yang_balances: Array<YangBalance> = ArrayTrait::new();

            let mut current_yang_id: u32 = START_YANG_IDX;
            let loop_end: u32 = self.yangs_count.read() + START_YANG_IDX;
            loop {
                if current_yang_id == loop_end {
                    break yang_balances.span();
                }

                let yang_total: Wad = self.yang_total.read(current_yang_id);
                yang_balances.append(YangBalance { yang_id: current_yang_id, amount: yang_total });

                current_yang_id += 1;
            }
        }

        // Returns a tuple of:
        // 1. the custom threshold (maximum LTV before liquidation)
        // 2. the total value of the yangs, at a given interval
        // based on historical prices and the given yang balances.
        fn get_threshold_and_value(
            self: @ContractState, mut yang_balances: Span<YangBalance>, interval: u64
        ) -> (Ray, Wad) {
            let mut weighted_threshold_sum: Ray = RayZeroable::zero();
            let mut total_value: Wad = WadZeroable::zero();

            loop {
                match yang_balances.pop_front() {
                    Option::Some(yang_balance) => {
                        // Update cumulative values only if the yang balance is greater than 0
                        if (*yang_balance.amount).is_non_zero() {
                            let yang_threshold: Ray = self.get_yang_threshold_helper(*yang_balance.yang_id);
                            let (price, _, _) = self.get_recent_price_from(*yang_balance.yang_id, interval);

                            let yang_deposited_value = *yang_balance.amount * price;
                            total_value += yang_deposited_value;
                            weighted_threshold_sum += wadray::wmul_rw(yang_threshold, yang_deposited_value);
                        }
                    },
                    Option::None => { break; },
                };
            };

            // Catch division by zero
            let threshold: Ray = if total_value.is_non_zero() {
                wadray::wdiv_rw(weighted_threshold_sum, total_value)
            } else {
                RayZeroable::zero()
            };

            (threshold, total_value)
        }

        //
        // Helpers for setters
        //

        fn set_threshold_helper(ref self: ContractState, yang: ContractAddress, threshold: Ray) {
            assert(threshold.val <= MAX_THRESHOLD, 'SH: Threshold > max');
            self.thresholds.write(self.get_valid_yang_id(yang), threshold);

            // Event emission
            self.emit(ThresholdUpdated { yang, threshold });
        }

        //
        // Helpers for core functions
        //

        fn increment_total_troves_debt(ref self: ContractState, amount: Wad) {
            let adjusted_amount: Wad = self.adjust_total_troves_deficit_helper(amount.into()).unwrap();

            let total_troves_debt: Wad = self.total_troves_debt.read();
            let new_total_troves_debt: Wad = total_troves_debt + adjusted_amount;

            self.total_troves_debt.write(new_total_troves_debt);
            self.emit(TotalTrovesDebtUpdated { total: new_total_troves_debt });
        }

        fn adjust_budget_helper(ref self: ContractState, amount: SignedWad) {
            self.budget.write(self.budget.read() + amount);

            self.emit(BudgetAdjusted { amount });
        }

        // Helper to adjust the total troves deficit.
        // - If the amount is positive and the total troves deficit is negative, return the 
        //   excess amount if any or zero. 
        // - If the amount is positive and the total troves deficit is not negative, return the
        //   original amount.
        // - If the amount is negative, return none.
        fn adjust_total_troves_deficit_helper(ref self: ContractState, amount: SignedWad) -> Option<Wad> {
            let mut excess: Option<Wad> = Option::None;
            let mut deficit_adjustment: SignedWad = amount;

            let total_troves_deficit: SignedWad = self.total_troves_deficit.read();
            if amount.is_positive() {
                let amount_wad: Wad = amount.try_into().unwrap();
                // Early return if no deficit
                if !total_troves_deficit.is_negative() {
                    return Option::Some(amount_wad);
                }

                // Prioritize reducing the troves deficit if any, to the extent of the deficit.
                // This ensures that the deficit will not be positive.
                let troves_deficit_to_reduce: Wad = min(amount_wad, total_troves_deficit.val.into());
                excess = Option::Some(amount_wad - troves_deficit_to_reduce);

                deficit_adjustment = troves_deficit_to_reduce.into();
            }

            let new_total_troves_deficit: SignedWad = self.total_troves_deficit.read() + deficit_adjustment;
            self.total_troves_deficit.write(new_total_troves_deficit);

            self.emit(TotalTrovesDeficitUpdated { total: new_total_troves_deficit });

            excess
        }

        fn forge_helper(ref self: ContractState, user: ContractAddress, amount: Wad) {
            self.yin.write(user, self.yin.read(user) + amount);
            self.total_yin.write(self.total_yin.read() + amount);

            self.emit(Transfer { from: ContractAddressZeroable::zero(), to: user, value: amount.into() });
        }

        fn melt_helper(ref self: ContractState, user: ContractAddress, amount: Wad) {
            let user_balance: Wad = self.yin.read(user);
            assert(user_balance >= amount, 'SH: Insufficient yin balance');

            self.yin.write(user, user_balance - amount);
            self.total_yin.write(self.total_yin.read() - amount);

            self.emit(Transfer { from: user, to: ContractAddressZeroable::zero(), value: amount.into() });
        }

        // Withdraw a specified amount of a Yang from a Trove
        fn withdraw_helper(ref self: ContractState, yang: ContractAddress, trove_id: u64, amount: Wad) {
            let yang_id: u32 = self.get_valid_yang_id(yang);

            // Fails if amount > amount of yang deposited in the given trove
            let trove_balance: Wad = self.deposits.read((yang_id, trove_id));
            assert(trove_balance >= amount, 'SH: Insufficient yang balance');

            let new_trove_balance: Wad = trove_balance - amount;
            let new_total: Wad = self.yang_total.read(yang_id) - amount;

            self.charge(trove_id);

            self.yang_total.write(yang_id, new_total);
            self.deposits.write((yang_id, trove_id), new_trove_balance);

            // Emit events
            self.emit(YangTotalUpdated { yang, total: new_total });
            self.emit(DepositUpdated { yang, trove_id, amount: new_trove_balance });
        }

        // Adds the accumulated interest as debt to the trove
        fn charge(ref self: ContractState, trove_id: u64) {
            // Do not charge accrued interest once Shrine is killed because total troves' debt
            // and individual trove's debt are fixed at the time of shutdown.
            if !self.is_live.read() {
                return;
            }

            let trove: Trove = self.troves.read(trove_id);

            // Get current interval and yang count
            let current_interval: u64 = now();

            // Get new debt amount
            let compounded_trove_debt: Wad = self.compound(trove_id, trove, current_interval);
            let compounded_trove_debt_with_redistributed_debt: Wad = compounded_trove_debt
                + self.fetch_redistributed_debt(trove_id);

            // Update trove
            let updated_trove: Trove = Trove {
                charge_from: current_interval,
                debt: compounded_trove_debt_with_redistributed_debt,
                last_rate_era: self.rates_latest_era.read()
            };
            self.troves.write(trove_id, updated_trove);
            self.trove_redistribution_id.write(trove_id, self.redistributions_count.read());

            let charged: Wad = compounded_trove_debt - trove.debt;

            // Add the interest charged on the trove's debt to the total troves' debt and
            // budget only if there is a change in the trove's debt. This should not include
            // redistributed debt, as that is already included in the total.
            if charged.is_non_zero() {
                self.increment_total_troves_debt(charged);
                self.adjust_budget_helper(charged.into());
            }

            // Emit only if there is a change in the `Trove` struct
            if updated_trove != trove {
                self.emit(TroveUpdated { trove_id, trove: updated_trove });
            }
        }

        // Returns the amount of debt owed by trove after having interest charged over a given time period
        // Assumes the trove hasn't minted or paid back any additional debt during the given time period
        // Assumes the trove hasn't deposited or withdrawn any additional collateral during the given time period
        // Time period includes `end_interval` and does NOT include `start_interval`.

        // Compound interest formula: P(t) = P_0 * e^(rt)
        // P_0 = principal
        // r = nominal interest rate (what the interest rate would be if there was no compounding)
        // t = time elapsed, in years
        fn compound(self: @ContractState, trove_id: u64, trove: Trove, end_interval: u64) -> Wad {
            // Saves gas and prevents bugs for troves with no yangs deposited
            // Implicit assumption is that a trove with non-zero debt must have non-zero yangs
            if trove.debt.is_zero() {
                return WadZeroable::zero();
            }

            let latest_rate_era: u64 = self.rates_latest_era.read();

            let mut compounded_debt: Wad = trove.debt;
            let mut start_interval: u64 = trove.charge_from;
            let mut trove_last_rate_era: u64 = trove.last_rate_era;

            loop {
                // `trove_last_rate_era` should always be less than or equal to `latest_rate_era`
                if trove_last_rate_era == latest_rate_era {
                    let avg_base_rate: Ray = self
                        .get_avg_rate_over_era(trove_id, start_interval, end_interval, latest_rate_era);

                    let avg_rate: Ray = avg_base_rate * self.get_avg_multiplier(start_interval, end_interval);

                    // represents `t` in the compound interest formula
                    let t: Wad = Wad { val: (end_interval - start_interval).into() * TIME_INTERVAL_DIV_YEAR };
                    compounded_debt *= exp(wadray::rmul_rw(avg_rate, t));
                    break compounded_debt;
                }

                let next_rate_update_era = trove_last_rate_era + 1;
                let next_rate_update_era_interval = self.rates_intervals.read(next_rate_update_era);

                let avg_base_rate: Ray = self
                    .get_avg_rate_over_era(
                        trove_id, start_interval, next_rate_update_era_interval, trove_last_rate_era
                    );
                let avg_rate: Ray = avg_base_rate
                    * self.get_avg_multiplier(start_interval, next_rate_update_era_interval);

                let t: Wad = Wad {
                    val: (next_rate_update_era_interval - start_interval).into() * TIME_INTERVAL_DIV_YEAR
                };
                compounded_debt *= exp(wadray::rmul_rw(avg_rate, t));

                start_interval = next_rate_update_era_interval;
                trove_last_rate_era = next_rate_update_era;
            }
        }

        // Returns the average interest rate charged to a trove from `start_interval` to `end_interval`,
        // Assumes that the time from `start_interval` to `end_interval` spans only a single "era".
        // An era is the time between two interest rate updates, during which all yang interest rates are constant.
        //
        // Also assumes that the trove's debt, and the trove's yang deposits
        // remain constant over the entire time period.
        fn get_avg_rate_over_era(
            self: @ContractState, trove_id: u64, start_interval: u64, end_interval: u64, rate_era: u64
        ) -> Ray {
            let mut cumulative_weighted_sum: Ray = RayZeroable::zero();
            let mut cumulative_yang_value: Wad = WadZeroable::zero();

            let mut current_yang_id: u32 = self.yangs_count.read();
            loop {
                // If all yangs have been iterated over, return the average rate
                if current_yang_id == 0 {
                    // This operation would be a problem if the total trove value was ever zero.
                    // However, `cumulative_yang_value` cannot be zero because a trove with no yangs deposited
                    // cannot have any debt, meaning this code would never run (see `compound`)
                    break wadray::wdiv_rw(cumulative_weighted_sum, cumulative_yang_value);
                }

                let yang_deposited: Wad = self.deposits.read((current_yang_id, trove_id));
                // Update cumulative values only if this yang has been deposited in the trove
                if yang_deposited.is_non_zero() {
                    let yang_rate: Ray = self.yang_rates.read((current_yang_id, rate_era));
                    let avg_price: Wad = self.get_avg_price(current_yang_id, start_interval, end_interval);
                    let yang_value: Wad = yang_deposited * avg_price;
                    let weighted_rate: Ray = wadray::wmul_wr(yang_value, yang_rate);

                    cumulative_weighted_sum += weighted_rate;
                    cumulative_yang_value += yang_value;
                }
                current_yang_id -= 1;
            }
        }

        // Returns the average price for a yang between two intervals, including `end_interval` but NOT including `start_interval`
        // - If `start_interval` is the same as `end_interval`, return the price at that interval.
        // - If `start_interval` is different from `end_interval`, return the average price.
        fn get_avg_price(self: @ContractState, yang_id: u32, start_interval: u64, end_interval: u64) -> Wad {
            let (start_yang_price, start_cumulative_yang_price, available_start_interval) = self
                .get_recent_price_from(yang_id, start_interval);
            let (end_yang_price, end_cumulative_yang_price, available_end_interval) = self
                .get_recent_price_from(yang_id, end_interval);

            // If the last available price for both start and end intervals are the same,
            // return that last available price
            // This also catches `start_interval == end_interval`
            if available_start_interval == available_end_interval {
                return start_yang_price;
            }

            let mut cumulative_diff: Wad = end_cumulative_yang_price - start_cumulative_yang_price;

            // Early termination if `start_interval` and `end_interval` are updated
            if start_interval == available_start_interval && end_interval == available_end_interval {
                return (cumulative_diff.val / (end_interval - start_interval).into()).into();
            }

            // If the start interval is not updated, adjust the cumulative difference (see `advance`) by deducting
            // (number of intervals missed from `available_start_interval` to `start_interval` * start price).
            if start_interval != available_start_interval {
                let cumulative_offset = Wad {
                    val: (start_interval - available_start_interval).into() * start_yang_price.val
                };
                cumulative_diff -= cumulative_offset;
            }

            // If the end interval is not updated, adjust the cumulative difference by adding
            // (number of intervals missed from `available_end_interval` to `end_interval` * end price).
            if end_interval != available_end_interval {
                let cumulative_offset = Wad {
                    val: (end_interval - available_end_interval).into() * end_yang_price.val
                };
                cumulative_diff += cumulative_offset;
            }

            (cumulative_diff.val / (end_interval - start_interval).into()).into()
        }

        // Returns the average multiplier over the specified time period, including `end_interval` but NOT including `start_interval`
        // - If `start_interval` is the same as `end_interval`, return the multiplier value at that interval.
        // - If `start_interval` is different from `end_interval`, return the average.
        // Return value is a tuple so that function can be modified as an external view for testing
        fn get_avg_multiplier(self: @ContractState, start_interval: u64, end_interval: u64) -> Ray {
            let (start_multiplier, start_cumulative_multiplier, available_start_interval) = self
                .get_recent_multiplier_from(start_interval);
            let (end_multiplier, end_cumulative_multiplier, available_end_interval) = self
                .get_recent_multiplier_from(end_interval);

            // If the last available multiplier for both start and end intervals are the same,
            // return that last available multiplier
            // This also catches `start_interval == end_interval`
            if available_start_interval == available_end_interval {
                return start_multiplier;
            }

            let mut cumulative_diff: Ray = end_cumulative_multiplier - start_cumulative_multiplier;

            // Early termination if `start_interval` and `end_interval` are updated
            if start_interval == available_start_interval && end_interval == available_end_interval {
                return (cumulative_diff.val / (end_interval - start_interval).into()).into();
            }

            // If the start interval is not updated, adjust the cumulative difference (see `advance`) by deducting
            // (number of intervals missed from `available_start_interval` to `start_interval` * start price).
            if start_interval != available_start_interval {
                let cumulative_offset = Ray {
                    val: (start_interval - available_start_interval).into() * start_multiplier.val
                };
                cumulative_diff -= cumulative_offset;
            }

            // If the end interval is not updated, adjust the cumulative difference by adding
            // (number of intervals missed from `available_end_interval` to `end_interval` * end price).
            if (end_interval != available_end_interval) {
                let cumulative_offset = Ray {
                    val: (end_interval - available_end_interval).into() * end_multiplier.val
                };
                cumulative_diff += cumulative_offset;
            }

            (cumulative_diff.val / (end_interval - start_interval).into()).into()
        }

        // Loop through yangs for the trove:
        // 1. redistribute a yang according to the percentage value to be redistributed; and
        // 2. redistribute the proportional debt for that yang.
        //
        // For yangs that can be ordinarily redistributed to other troves that have deposited the same
        // yang, decrement the trove's yang balance and total yang supply by the amount redistributed
        // (including any adjustments if the trove has some amount of the redistributed yang remaining), 
        // and divide the debt by the recipient amount of yang (i.e. excluding the initial yang amount 
        // and the redistributed trove's yang.
        //
        // For yangs that have not been deposited by any other troves (i.e. exceptional redistribution), 
        // we transfer the redistributed trove's yang to the initial yang amount, and add the debt to 
        // the budget as a deficit. This ensures that the redistributed debt can still be backed in 
        // the event of a shutdown, but essentially locks the redistributed yang's value in Shrine, 
        //
        // Note that this internal function will revert if `pct_value_to_redistribute` exceeds
        // one Ray (100%), due to an overflow when deducting the redistributed amount of yang from
        // the trove.
        fn redistribute_helper(
            ref self: ContractState,
            redistribution_id: u32,
            trove_id: u64,
            debt_to_redistribute: Wad,
            pct_value_to_redistribute: Ray,
            current_interval: u64
        ) {
            // TODO: temporary workaround for issue with borrowing snapshots in loops
            let self_snap = @self;

            let trove_yang_balances: Span<YangBalance> = self.get_trove_deposits(trove_id);
            let (_, trove_value) = self.get_threshold_and_value(trove_yang_balances, current_interval);
            let trove_value_to_redistribute: Wad = wadray::rmul_wr(trove_value, pct_value_to_redistribute);

            // Keep track of the total debt redistributed for the return value
            let mut redistributed_debt: Wad = WadZeroable::zero();
            let mut trove_yang_balances_copy = trove_yang_balances;
            // Iterate over the yangs deposited in the trove to be redistributed
            loop {
                match trove_yang_balances_copy.pop_front() {
                    Option::Some(yang_balance) => {
                        let trove_yang_amt: Wad = (*yang_balance).amount;
                        let yang_id_to_redistribute = (*yang_balance).yang_id;
                        // Skip over this yang if it has not been deposited in the trove
                        if trove_yang_amt.is_zero() {
                            continue;
                        }

                        let yang_amt_to_redistribute: Wad = wadray::rmul_wr(trove_yang_amt, pct_value_to_redistribute);

                        let yang_total: Wad = self.yang_total.read(yang_id_to_redistribute);
                        let initial_yang_amt: Wad = self.initial_yang_amts.read(yang_id_to_redistribute);

                        // Get the remainder amount of yangs in all other troves that can be redistributed
                        // This excludes any remaining yang in the redistributed trove if the percentage to
                        // be redistributed is less than 100%.
                        let recipient_yang_amt: Wad = yang_total - trove_yang_amt - initial_yang_amt;

                        // Calculate the actual amount of debt that should be redistributed, including any
                        // rounding of dust amounts of debt.
                        let (redistributed_yang_price, _, _) = self_snap
                            .get_recent_price_from(yang_id_to_redistribute, current_interval);

                        let mut raw_debt_to_distribute_for_yang: Wad = WadZeroable::zero();
                        let mut debt_to_distribute_for_yang: Wad = WadZeroable::zero();

                        if trove_value_to_redistribute.is_non_zero() {
                            let yang_debt_pct: Ray = wadray::rdiv_ww(
                                yang_amt_to_redistribute * redistributed_yang_price, trove_value_to_redistribute
                            );
                            raw_debt_to_distribute_for_yang = wadray::rmul_rw(yang_debt_pct, debt_to_redistribute);
                            let (tmp_debt_to_distribute_for_yang, updated_redistributed_debt) = round_distributed_debt(
                                debt_to_redistribute, raw_debt_to_distribute_for_yang, redistributed_debt
                            );

                            redistributed_debt = updated_redistributed_debt;
                            debt_to_distribute_for_yang = tmp_debt_to_distribute_for_yang;
                        } else {
                            // If `trove_value_to_redistribute` is zero due to loss of precision,
                            // redistribute all of `debt_to_redistribute` to the first yang that the trove
                            // has deposited. Note that `redistributed_debt` does not need to be updated because
                            // setting `debt_to_distribute_for_yang` to a non-zero value would terminate the loop
                            // after this iteration at
                            // `debt_to_distribute_for_yang != raw_debt_to_distribute_for_yang` (i.e. `1 != 0`).
                            //
                            // At worst, `debt_to_redistribute` will accrue to the error and
                            // no yang is decremented from the redistributed trove, but redistribution should
                            // not revert.
                            debt_to_distribute_for_yang = debt_to_redistribute;
                        };

                        // If there is at least `MIN_RECIPIENT_YANG_AMT` amount of yang in other troves,
                        // handle it as an ordinary redistribution by rebasing the redistributed yang, and
                        // reallocating debt to other troves with the same yang. The minimum remainder amount
                        // is required to prevent overflow when calculating `unit_yang_per_recipient_yang` below,
                        // and to prevent `updated_trove_yang_balance` from being incorrectly zeroed when
                        // `unit_yang_per_recipient_yang` is a very large value.
                        //
                        // This is expected to be the common case.
                        // Otherwise, redistribute by:
                        // (1) decrementing the redistributed trove's yangs so that the value accrue to the initial 
                        //     yang amounts via rebasing (and will be locked up in Shrine until and if global shutdown 
                        //     occurs);
                        // (2) adding the trove's debt to the budget as a deficit.
                        let is_ordinary_redistribution: bool = recipient_yang_amt >= MIN_RECIPIENT_YANG_AMT.into();

                        let mut updated_trove_yang_balance: Wad = trove_yang_amt - yang_amt_to_redistribute;
                        let mut updated_yang_total: Wad = yang_total;

                        if is_ordinary_redistribution {
                            // Since the amount of assets in the Gate remains constant, decrementing the system's yang
                            // balance by the amount deposited in the trove has the effect of rebasing (i.e. appreciating)
                            // the ratio of asset to yang for the remaining amount of that yang.
                            //
                            // Example:
                            // - At T0, there is a total of 100 units of YANG_1, and 100 units of YANG_1_ASSET in the Gate.
                            //   1 unit of YANG_1 corresponds to 1 unit of YANG_1_ASSET.
                            // - At T1, a trove with 10 units of YANG_1 is redistributed. The trove's deposit of YANG_1 is
                            //   zeroed, and the total units of YANG_1 drops to 90 (100 - 10 = 90). The amount of YANG_1_ASSET
                            //   in the Gate remains at 100 units.
                            //   1 unit of YANG_1 now corresponds to 1.1111... unit of YANG_1_ASSET.
                            //
                            // Therefore, we need to adjust the remainder yang amount of the redistributed trove according to
                            // this formula below to offset the appreciation from rebasing for the redistributed trove:
                            //
                            //                                        remaining_trove_yang
                            // adjusted_remaining_trove_yang = ----------------------------------
                            //                                 (1 + unit_yang_per_recipient_yang)
                            //
                            // where `unit_yang_per_recipient_yang` is the amount of redistributed yang to be redistributed
                            // to each Wad unit in `recipient_yang_amt + initial_yang_amt` - note
                            // that the initial yang amount needs to be included because it also benefits from the rebasing:
                            //
                            //                                       yang_amt_to_redistribute
                            // unit_yang_per_recipient_yang = -------------------------------------
                            //                                recipient_yang_amt + initial_yang_amt

                            let unit_yang_per_recipient_yang: Ray = wadray::rdiv_ww(
                                yang_amt_to_redistribute, (recipient_yang_amt + initial_yang_amt)
                            );
                            let remaining_trove_yang: Wad = trove_yang_amt - yang_amt_to_redistribute;
                            updated_trove_yang_balance =
                                wadray::rdiv_wr(remaining_trove_yang, (RAY_ONE.into() + unit_yang_per_recipient_yang));

                            let yang_offset: Wad = remaining_trove_yang - updated_trove_yang_balance;
                            updated_yang_total -= (yang_amt_to_redistribute + yang_offset);

                            // There is a slight discrepancy here because yang is redistributed by rebasing,
                            // which means the initial yang amount is included, but the distribution of debt excludes
                            // the initial yang amount. However, it is unlikely to have any material impact because
                            // all redistributed debt will be attributed to user troves, with a negligible loss in
                            // yang assets for these troves as a result of some amount going towards the initial yang
                            // amount. Even though the initial yang amount may increase over time due to exceptional
                            // redistributions, this is expected to be rare.
                            let unit_debt: Wad = debt_to_distribute_for_yang / recipient_yang_amt;
                            self.yang_redistributions.write((yang_id_to_redistribute, redistribution_id), unit_debt);

                            // Due to loss of precision from fixed point division, the actual debt distributed will be 
                            // less than or equal to the amount of debt to distribute.
                            let actual_debt_distributed_for_yang: Wad = unit_debt * recipient_yang_amt;
                            let debt_error: Wad = debt_to_distribute_for_yang - actual_debt_distributed_for_yang;

                            self.adjust_budget_helper(SignedWad { val: debt_error.val, sign: true });
                            self.adjust_total_troves_deficit_helper(SignedWad { val: debt_error.val, sign: true });
                        } else {
                            // Move the redistributed yang amount from the trove to the initial yang amounts
                            self
                                .initial_yang_amts
                                .write(
                                    yang_id_to_redistribute,
                                    self.initial_yang_amts.read(yang_id_to_redistribute) + yang_amt_to_redistribute,
                                );

                            // The redistributed debt should exclude any previous errors, which should be carried over to 
                            // the next ordinary redistribution instead.
                            self.adjust_budget_helper(SignedWad { val: debt_to_distribute_for_yang.val, sign: true });
                            self
                                .adjust_total_troves_deficit_helper(
                                    SignedWad { val: debt_to_distribute_for_yang.val, sign: true }
                                );
                        }

                        self.deposits.write((yang_id_to_redistribute, trove_id), updated_trove_yang_balance);
                        self.yang_total.write(yang_id_to_redistribute, updated_yang_total);

                        // If debt was rounded up, meaning it is now fully redistributed, skip the remaining yangs
                        // Otherwise, continue the iteration
                        if debt_to_distribute_for_yang != raw_debt_to_distribute_for_yang {
                            break;
                        }
                    },
                    Option::None => { break; },
                };
            };
        }

        // Calculates the redistributed debt that has not been attributed for a trove.
        fn fetch_redistributed_debt(self: @ContractState, trove_id: u64) -> Wad {
            let trove_last_redistribution_id: u32 = self.trove_redistribution_id.read(trove_id);
            let current_redistribution_id: u32 = self.redistributions_count.read();

            let mut redistributed_debt = WadZeroable::zero();
            // Early termination if no redistributions since trove was last updated
            if current_redistribution_id == trove_last_redistribution_id {
                return redistributed_debt;
            }

            // Outer loop iterating over the trove's yangs
            let mut current_yang_id: u32 = self.yangs_count.read();
            loop {
                if current_yang_id == 0 {
                    break redistributed_debt;
                }

                let deposited: Wad = self.deposits.read((current_yang_id, trove_id));
                if deposited.is_non_zero() {
                    // Inner loop iterating over the redistribution IDs for each of the trove's yangs
                    let mut current_redistribution_id_temp = current_redistribution_id;
                    loop {
                        if trove_last_redistribution_id == current_redistribution_id_temp {
                            break;
                        }

                        // Get the amount of debt per yang for the current redistribution
                        let unit_debt: Wad = self
                            .yang_redistributions
                            .read((current_yang_id, current_redistribution_id_temp));

                        if unit_debt.is_non_zero() {
                            redistributed_debt += unit_debt * deposited;
                        }
                        current_redistribution_id_temp -= 1;
                    };
                }
                current_yang_id -= 1;
            }
        }
    }

    //
    // Internal functions for Shrine that do not access storage
    //

    #[inline(always)]
    fn now() -> u64 {
        starknet::get_block_timestamp() / TIME_INTERVAL
    }

    // Asserts that `current_new_rate` is in the range (0, MAX_YANG_RATE]
    fn assert_rate_is_valid(rate: Ray) {
        assert(0 < rate.val && rate.val <= MAX_YANG_RATE, 'SH: Rate out of bounds');
    }

    // Helper function to round up the debt to be redistributed for a yang if the remaining debt
    // falls below the defined threshold, so as to avoid rounding errors and ensure that the amount
    // of debt redistributed is equal to amount intended to be redistributed
    fn round_distributed_debt(
        total_debt_to_distribute: Wad, debt_to_distribute: Wad, cumulative_redistributed_debt: Wad
    ) -> (Wad, Wad) {
        let updated_cumulative_redistributed_debt = cumulative_redistributed_debt + debt_to_distribute;
        let remaining_debt: Wad = total_debt_to_distribute - updated_cumulative_redistributed_debt;

        if remaining_debt.val <= ROUNDING_THRESHOLD {
            return (debt_to_distribute + remaining_debt, updated_cumulative_redistributed_debt + remaining_debt);
        }

        (debt_to_distribute, updated_cumulative_redistributed_debt)
    }

    //
    // Public ERC20 functions
    //

    #[abi(embed_v0)]
    impl IERC20Impl of IERC20<ContractState> {
        // ERC20 getters
        fn name(self: @ContractState) -> felt252 {
            self.yin_name.read()
        }

        fn symbol(self: @ContractState) -> felt252 {
            self.yin_symbol.read()
        }

        fn decimals(self: @ContractState) -> u8 {
            self.yin_decimals.read()
        }

        fn total_supply(self: @ContractState) -> u256 {
            self.total_yin.read().into()
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.yin.read(account).into()
        }

        fn allowance(self: @ContractState, owner: ContractAddress, spender: ContractAddress) -> u256 {
            self.yin_allowances.read((owner, spender))
        }

        // ERC20 public functions
        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            self.transfer_helper(get_caller_address(), recipient, amount);
            true
        }

        fn transfer_from(
            ref self: ContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256
        ) -> bool {
            self.spend_allowance_helper(sender, get_caller_address(), amount);
            self.transfer_helper(sender, recipient, amount);
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            self.approve_helper(get_caller_address(), spender, amount);
            true
        }
    }

    #[abi(embed_v0)]
    impl IERC20CamelImpl of IERC20CamelOnly<ContractState> {
        fn totalSupply(self: @ContractState) -> u256 {
            self.total_supply()
        }

        fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
            self.balance_of(account)
        }

        fn transferFrom(
            ref self: ContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256
        ) -> bool {
            self.transfer_from(sender, recipient, amount)
        }
    }
    //
    // Internal ERC20 functions
    //

    #[generate_trait]
    impl ERC20Helpers of ERC20HelpersTrait {
        fn transfer_helper(ref self: ContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256) {
            assert(recipient.is_non_zero(), 'SH: No transfer to 0 address');

            let amount_wad: Wad = Wad { val: amount.try_into().unwrap() };

            // Transferring the Yin
            let sender_balance: Wad = self.yin.read(sender);
            assert(sender_balance >= amount_wad, 'SH: Insufficient yin balance');

            self.yin.write(sender, sender_balance - amount_wad);
            self.yin.write(recipient, self.yin.read(recipient) + amount_wad);

            self.emit(Transfer { from: sender, to: recipient, value: amount });
        }

        fn approve_helper(ref self: ContractState, owner: ContractAddress, spender: ContractAddress, amount: u256) {
            assert(spender.is_non_zero(), 'SH: No approval of 0 address');
            assert(owner.is_non_zero(), 'SH: No approval for 0 address');

            self.yin_allowances.write((owner, spender), amount);

            self.emit(Approval { owner, spender, value: amount });
        }

        fn spend_allowance_helper(
            ref self: ContractState, owner: ContractAddress, spender: ContractAddress, amount: u256
        ) {
            let current_allowance: u256 = self.yin_allowances.read((owner, spender));

            // if current_allowance is not set to the maximum u256, then
            // subtract `amount` from spender's allowance.
            if current_allowance != BoundedU256::max() {
                assert(current_allowance >= amount, 'SH: Insufficient yin allowance');
                self.approve_helper(owner, spender, current_allowance - amount);
            }
        }
    }

    //
    // SRC5
    //

    #[abi(embed_v0)]
    impl ISRC5Impl of ISRC5<ContractState> {
        fn supports_interface(self: @ContractState, interface_id: felt252) -> bool {
            interface_id == ISRC5_ID || interface_id == IERC20_ID || interface_id == IERC20_CAMEL_ID
        }
    }
}
