#[contract]
mod Shrine {
    use array::{ArrayTrait, SpanTrait};
    use cmp::{max, min};
    use integer::{BoundedU256, U256Zeroable, u256_safe_divmod};
    use option::OptionTrait;
    use starknet::{get_block_timestamp, get_caller_address};
    use starknet::contract_address::{ContractAddress, ContractAddressZeroable};
    use traits::{Into, TryInto};
    use zeroable::Zeroable;

    use aura::core::roles::ShrineRoles;

    use aura::utils::access_control::AccessControl;
    use aura::utils::exp::{exp, neg_exp};
    use aura::utils::serde::SpanSerde;
    use aura::utils::storage_access;
    use aura::utils::types::{
        ExceptionalYangRedistribution, Trove, YangBalance, YangRedistribution, YangSuspensionStatus
    };
    use aura::utils::u256_conversions::U128IntoU256;
    use aura::utils::wadray;
    use aura::utils::wadray::{
        BoundedRay, Ray, RayZeroable, RAY_ONE, RAY_PERCENT, Wad, WadZeroable, WAD_DECIMALS, WAD_ONE,
        WAD_SCALE
    };

    //
    // Constants
    //

    // Initial multiplier value to ensure `get_recent_multiplier_from` terminates - (ray): RAY_ONE
    const INITIAL_MULTIPLIER: u128 = 1000000000000000000000000000;
    const MAX_MULTIPLIER: u128 = 3000000000000000000000000000; // Max of 3x (ray): 3 * RAY_ONE

    const MAX_THRESHOLD: u128 = 1000000000000000000000000000; // (ray): RAY_ONE

    // If a yang is deemed risky, it can be marked as suspended. During the
    // SUSPENSION_GRACE_PERIOD, this decision can be reverted and the yang's status
    // can be changed back to normal. If this does not happen, the yang is
    // suspended permanently, i.e. can't be used in the system ever again.
    // The start of a Yang's suspension period is tracked in `yang_suspension`
    const SUSPENSION_GRACE_PERIOD: u64 = 15768000; // 182.5 days, half a year, in seconds

    // Length of a time interval in seconds
    const TIME_INTERVAL: u64 = 1800; // 30 minutes * 60 seconds per minute
    const TIME_INTERVAL_DIV_YEAR: u128 =
        57077625570776; // 1 / (48 30-minute intervals per day) / (365 days per year) = 0.000057077625 (wad)

    // Threshold for rounding remaining debt during redistribution (wad): 10**9
    const ROUNDING_THRESHOLD: u128 = 1000000000;

    // Maximum interest rate a yang can have (ray): RAY_ONE
    const MAX_YANG_RATE: u128 = 100000000000000000000000000;

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

    struct Storage {
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
        // Total amount of debt accrued
        total_debt: Wad,
        // Total amount of synthetic forged
        total_yin: Wad,
        // Keeps track of the price history of each Yang
        // Stores both the actual price and the cumulative price of
        // the yang at each time interval, both as Wads.
        // - interval: timestamp divided by TIME_INTERVAL.
        // (yang_id, interval) -> (price, cumulative_price)
        yang_prices: LegacyMap::<(u32, u64), (Wad, Wad)>,
        // Spot price of yin
        yin_spot_price: Wad,
        // Maximum amount of debt that can exist at any given time
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
        // NOTE: don't read the value directly, instead use `get_yang_threshold_internal`
        //       because a yang might be suspended; the function will return the correct
        //       threshold value under all circumstances
        // (yang_id) -> (Liquidation Threshold)
        thresholds: LegacyMap::<u32, Ray>,
        // Keeps track of how many redistributions have occurred
        redistributions_count: u32,
        // Last redistribution accounted for a trove
        // (trove_id) -> (Last Redistribution ID)
        trove_redistribution_id: LegacyMap::<u64, u32>,
        // Keeps track of whether the redistribution involves at least one yang that
        // no other troves has deposited.
        // (redistribution_id) -> (Is exceptional redistribution)
        is_exceptional_redistribution: LegacyMap::<u32, bool>,
        // Mapping of yang ID and redistribution ID to
        // 1. amount of debt in Wad to be redistributed to each Wad unit of yang
        // 2. amount of debt to be added to the next redistribution to calculate (1)
        // (yang_id, redistribution_id) -> YangRedistribution{debt_per_wad, debt_to_add_to_next}
        yang_redistributions: LegacyMap::<(u32, u32), YangRedistribution>,
        // Mapping of recipient yang ID, redistribution ID and redistributed yang ID to
        // 1. amount of redistributed yang per Wad unit of recipient yang
        // 2. amount of debt per Wad unit of recipient yang
        yang_to_yang_redistribution: LegacyMap::<(u32, u32, u32), ExceptionalYangRedistribution>,
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
    fn YangAdded(yang: ContractAddress, yang_id: u32, start_price: Wad, initial_rate: Ray) {}

    #[event]
    fn YangTotalUpdated(yang: ContractAddress, total: Wad) {}

    #[event]
    fn DebtTotalUpdated(total: Wad) {}

    #[event]
    fn YangsCountUpdated(count: u32) {}

    #[event]
    fn MultiplierUpdated(multiplier: Ray, cumulative_multiplier: Ray, interval: u64) {}

    #[event]
    fn YangRatesUpdated(
        new_rate_idx: u64,
        current_interval: u64,
        yangs: Span<ContractAddress>,
        new_rates: Span<Ray>,
    ) {}

    #[event]
    fn ThresholdUpdated(yang: ContractAddress, threshold: Ray) {}

    #[event]
    fn ForgeFeePaid(trove_id: u64, fee: Wad, fee_pct: Wad) {}

    #[event]
    fn TroveUpdated(trove_id: u64, trove: Trove) {}

    #[event]
    fn TroveRedistributed(redistribution_id: u32, trove_id: u64, debt: Wad) {}

    #[event]
    fn DepositUpdated(yang: ContractAddress, trove_id: u64, amount: Wad) {}

    #[event]
    fn YangPriceUpdated(yang: ContractAddress, price: Wad, cumulative_price: Wad, interval: u64) {}

    #[event]
    fn YinPriceUpdated(old_price: Wad, new_price: Wad) {}

    #[event]
    fn DebtCeilingUpdated(ceiling: Wad) {}

    #[event]
    fn Killed() {}

    // ERC20 events
    #[event]
    fn Transfer(from: ContractAddress, to: ContractAddress, value: u256) {}

    #[event]
    fn Approval(owner: ContractAddress, spender: ContractAddress, value: u256) {}


    //
    // Constructor
    //

    #[constructor]
    fn constructor(admin: ContractAddress, name: felt252, symbol: felt252) {
        AccessControl::initializer(admin);

        // Grant admin permission
        AccessControl::grant_role_internal(ShrineRoles::default_admin_role(), admin);

        is_live::write(true);

        // Seeding initial multiplier to the previous interval to ensure `get_recent_multiplier_from` terminates
        // otherwise, the next multiplier update will run into an endless loop of `get_recent_multiplier_from`
        // since it wouldn't find the initial multiplier
        let prev_interval: u64 = now() - 1;
        let init_multiplier: Ray = INITIAL_MULTIPLIER.into();
        multiplier::write(prev_interval, (init_multiplier, init_multiplier));

        // Setting initial rate era to 1
        rates_latest_era::write(1);

        // Setting initial yin spot price to 1
        yin_spot_price::write(WAD_ONE.into());

        // Emit event
        MultiplierUpdated(init_multiplier, init_multiplier, prev_interval);

        // ERC20
        yin_name::write(name);
        yin_symbol::write(symbol);
        yin_decimals::write(WAD_DECIMALS);
    }

    //
    // Getters
    //

    // Returns a tuple of a trove's threshold, LTV based on compounded debt, trove value and compounded debt
    #[view]
    fn get_trove_info(trove_id: u64) -> (Ray, Ray, Wad, Wad) {
        let interval: u64 = now();

        // Get threshold and trove value
        let (mut threshold, mut value) = get_trove_threshold_and_value_internal(trove_id, interval);
        let trove: Trove = troves::read(trove_id);

        // Catch troves with no value
        if value.is_zero() {
            // This `if` branch handles a corner case where a trove without any yangs deposited (i.e. zero value)
            // attempts to forge a non-zero debt. It ensures that the `assert_healthy` check in `forge` would
            // fail and revert.
            // - Without the check for `value.is_zero()` and `trove.debt.is_non_zero()`, the LTV calculation of
            //   of debt / value will run into a zero division error.
            // - With the check for `value.is_zero()` but without `trove.debt.is_non_zero()`, the LTV will be
            //   incorrectly set to 0 and the `assert_healthy` check will fail to catch this illegal operation.
            if trove.debt.is_non_zero() {
                return (threshold, BoundedRay::max(), value, trove.debt);
            } else {
                return (threshold, BoundedRay::min(), value, trove.debt);
            }
        }

        // Calculate debt
        let compounded_debt: Wad = compound(trove_id, trove, interval);
        let (updated_trove_yang_balances, compounded_debt_with_redistributed_debt) =
            pull_redistributed_debt_and_yangs(
            trove_id,
            compounded_debt,
            trove_redistribution_id::read(trove_id),
            redistributions_count::read()
        );

        if updated_trove_yang_balances.is_some() {
            let (new_threshold, new_value) = get_simulated_trove_threshold_and_value(
                updated_trove_yang_balances.unwrap(), interval
            );
            threshold = new_threshold;
            value = new_value;
        }

        let ltv: Ray = wadray::rdiv_ww(compounded_debt_with_redistributed_debt, value);
        (threshold, ltv, value, compounded_debt_with_redistributed_debt)
    }

    // Returns a tuple of:
    // 1. an array of `YangBalance` struct representing yang amounts attributed to the trove
    //    from exceptional redistributions but not yet pulled to the trove.
    //    If there were no exceptional redistributions, then an empty array is returned.
    // 2. the amount of debt attributed to the trove from ordinary and exceptional redistributions
    //    but not yet pulled to the trove
    #[view]
    fn get_redistributions_attributed_to_trove(trove_id: u64) -> (Span<YangBalance>, Wad) {
        let (updated_trove_yang_balances, pulled_debt) = pull_redistributed_debt_and_yangs(
            trove_id,
            WadZeroable::zero(),
            trove_redistribution_id::read(trove_id),
            redistributions_count::read()
        );

        let mut added_yangs: Array<YangBalance> = Default::default();
        if updated_trove_yang_balances.is_some() {
            let mut updated_trove_yang_balances = updated_trove_yang_balances.unwrap();
            loop {
                match updated_trove_yang_balances.pop_front() {
                    Option::Some(updated_yang_balance) => {
                        let trove_yang_balance: Wad = deposits::read(
                            (*updated_yang_balance.yang_id, trove_id)
                        );
                        let increment: Wad = *updated_yang_balance.amount - trove_yang_balance;
                        if increment.is_non_zero() {
                            added_yangs
                                .append(
                                    YangBalance {
                                        yang_id: *updated_yang_balance.yang_id, amount: increment
                                    }
                                );
                        }
                    },
                    Option::None(_) => {
                        break;
                    },
                };
            };
        }

        (added_yangs.span(), pulled_debt)
    }

    #[view]
    fn get_yin(user: ContractAddress) -> Wad {
        yin::read(user)
    }

    #[view]
    fn get_total_yin() -> Wad {
        total_yin::read()
    }

    #[view]
    fn get_yang_total(yang: ContractAddress) -> Wad {
        let yang_id: u32 = get_valid_yang_id(yang);
        yang_total::read(yang_id)
    }

    #[view]
    fn get_initial_yang_amt(yang: ContractAddress) -> Wad {
        let yang_id: u32 = get_valid_yang_id(yang);
        initial_yang_amts::read(yang_id)
    }

    #[view]
    fn get_yangs_count() -> u32 {
        yangs_count::read()
    }

    #[view]
    fn get_deposit(yang: ContractAddress, trove_id: u64) -> Wad {
        let yang_id: u32 = get_valid_yang_id(yang);
        deposits::read((yang_id, trove_id))
    }

    #[view]
    fn get_total_debt() -> Wad {
        total_debt::read()
    }

    #[view]
    fn get_yang_price(yang: ContractAddress, interval: u64) -> (Wad, Wad) {
        let yang_id: u32 = get_valid_yang_id(yang);
        yang_prices::read((yang_id, interval))
    }

    #[view]
    fn get_yang_rate(yang: ContractAddress, idx: u64) -> Ray {
        let yang_id: u32 = get_valid_yang_id(yang);
        yang_rates::read((yang_id, idx))
    }

    #[view]
    fn get_current_rate_era() -> u64 {
        rates_latest_era::read()
    }

    #[view]
    fn get_debt_ceiling() -> Wad {
        debt_ceiling::read()
    }

    #[view]
    fn get_multiplier(interval: u64) -> (Ray, Ray) {
        multiplier::read(interval)
    }

    #[view]
    fn get_yang_suspension_status(yang: ContractAddress) -> YangSuspensionStatus {
        let yang_id: u32 = get_valid_yang_id(yang);
        get_yang_suspension_status_internal(yang_id)
    }

    #[view]
    fn get_yang_threshold(yang: ContractAddress) -> Ray {
        let yang_id: u32 = get_valid_yang_id(yang);
        scale_threshold_for_recovery_mode(get_yang_threshold_internal(yang_id))
    }

    #[view]
    fn get_raw_yang_threshold(yang: ContractAddress) -> Ray {
        let yang_id: u32 = get_valid_yang_id(yang);
        get_yang_threshold_internal(yang_id)
    }

    #[view]
    fn get_shrine_threshold_and_value() -> (Ray, Wad) {
        get_shrine_threshold_and_value_internal(now())
    }

    // Returns a tuple of 
    // 1. The recovery mode threshold
    // 2. Shrine's LTV
    #[view]
    fn get_recovery_mode_threshold() -> (Ray, Ray) {
        let (liq_threshold, value) = get_shrine_threshold_and_value_internal(now());
        let debt: Wad = total_debt::read();
        let rm_threshold = liq_threshold * RECOVERY_MODE_THRESHOLD_MULTIPLIER.into();

        // If no collateral has been deposited, then shrine's LTV is
        // returned as the maximum possible value.
        if value.is_zero() {
            return (rm_threshold, BoundedRay::max());
        }

        (rm_threshold, wadray::rdiv_ww(debt, value))
    }


    #[view]
    fn get_redistributions_count() -> u32 {
        redistributions_count::read()
    }

    #[view]
    fn get_trove_redistribution_id(trove_id: u64) -> u32 {
        trove_redistribution_id::read(trove_id)
    }

    #[view]
    fn get_redistribution_for_yang(
        yang: ContractAddress, redistribution_id: u32
    ) -> YangRedistribution {
        let yang_id: u32 = get_valid_yang_id(yang);
        yang_redistributions::read((yang_id, redistribution_id))
    }

    #[view]
    fn get_exceptional_redistribution_for_yang_to_yang(
        recipient_yang: ContractAddress, redistribution_id: u32, redistributed_yang: ContractAddress
    ) -> ExceptionalYangRedistribution {
        let recipient_yang_id: u32 = get_valid_yang_id(recipient_yang);
        let redistributed_yang_id: u32 = get_valid_yang_id(redistributed_yang);
        yang_to_yang_redistribution::read(
            (recipient_yang_id, redistribution_id, redistributed_yang_id)
        )
    }

    #[view]
    fn get_live() -> bool {
        is_live::read()
    }


    // ERC20 getters
    #[view]
    fn name() -> felt252 {
        yin_name::read()
    }

    #[view]
    fn symbol() -> felt252 {
        yin_symbol::read()
    }

    #[view]
    fn decimals() -> u8 {
        yin_decimals::read()
    }

    #[view]
    fn total_supply() -> u256 {
        total_yin::read().val.into()
    }

    #[view]
    fn balance_of(account: ContractAddress) -> u256 {
        yin::read(account).val.into()
    }

    #[view]
    fn allowance(owner: ContractAddress, spender: ContractAddress) -> u256 {
        yin_allowances::read((owner, spender))
    }

    //
    // Setters
    //

    // `initial_yang_amt` is passed as an argument from upstream to address the issue of
    // first depositor front-running by requiring an initial deposit when adding the yang
    // to the Shrine
    #[external]
    fn add_yang(
        yang: ContractAddress,
        threshold: Ray,
        initial_price: Wad,
        initial_rate: Ray,
        initial_yang_amt: Wad
    ) {
        AccessControl::assert_has_role(ShrineRoles::ADD_YANG);

        assert(yang_ids::read(yang) == 0, 'SH: Yang already exists');

        assert_rate_is_valid(initial_rate);

        // Assign new ID to yang and add yang struct
        let yang_id: u32 = yangs_count::read() + 1;
        yang_ids::write(yang, yang_id);

        // Update yangs count
        yangs_count::write(yang_id);

        // Set threshold
        set_threshold_internal(yang, threshold);

        // Update initial yang supply
        // Used upstream to prevent first depositor front running
        yang_total::write(yang_id, initial_yang_amt);
        initial_yang_amts::write(yang_id, initial_yang_amt);

        // Since `initial_price` is the first price in the price history, the cumulative price is also set to `initial_price`

        let prev_interval: u64 = now() - 1;
        // seeding initial price to the previous interval to ensure `get_recent_price_from` terminates
        // new prices are pushed to Shrine from an oracle via `advance` and are always set on the current
        // interval (`now()`); if we wouldn't set this initial price to `now() - 1` and oracle could
        // update a price still in the current interval (as oracle update times are independent of
        // Shrine's intervals, a price can be updated multiple times in a single interval) which would
        // result in an endless loop of `get_recent_price_from` since it wouldn't find the initial price
        yang_prices::write((yang_id, prev_interval), (initial_price, initial_price));

        // Setting the base rate for the new yang

        // NOTE: Eras are not incremented when a new yang is added, and the era that is being set
        // for this base rate will have an interval that is <= now(). This would be a problem
        // if there could be a trove containing the newly-added with `trove.last_rate_era < latest_era`.
        // Luckily, this isn't possible because `charge` is called in `deposit`, so a trove's `last_rate_era`
        // will always be updated to `latest_era` immediately before the newly-added yang is deposited.
        let latest_era: u64 = rates_latest_era::read();
        yang_rates::write((yang_id, latest_era), initial_rate);

        // Event emissions
        YangAdded(yang, yang_id, initial_price, initial_rate);
        YangsCountUpdated(yang_id);
        YangTotalUpdated(yang, initial_yang_amt);
    }

    #[external]
    fn set_debt_ceiling(new_ceiling: Wad) {
        AccessControl::assert_has_role(ShrineRoles::SET_DEBT_CEILING);
        debt_ceiling::write(new_ceiling);

        //Event emission
        DebtCeilingUpdated(new_ceiling);
    }

    #[external]
    fn set_threshold(yang: ContractAddress, new_threshold: Ray) {
        AccessControl::assert_has_role(ShrineRoles::SET_THRESHOLD);

        set_threshold_internal(yang, new_threshold);
    }

    #[external]
    fn kill() {
        AccessControl::assert_has_role(ShrineRoles::KILL);
        is_live::write(false);

        // Event emission
        Killed();
    }

    //
    // Core Functions - External
    //

    // Set the price of the specified Yang for the current interval interval
    #[external]
    fn advance(yang: ContractAddress, price: Wad) {
        AccessControl::assert_has_role(ShrineRoles::ADVANCE);

        assert(price.is_non_zero(), 'SH: Price cannot be 0');

        let interval: u64 = now();
        let yang_id: u32 = get_valid_yang_id(yang);

        // Calculating the new cumulative price
        // To do this, we get the interval of the last price update, find the number of
        // intervals BETWEEN the current interval and the last_interval (non-inclusive), multiply that by
        // the last price, and add it to the last cumulative price. Then we add the new price, `price`,
        // for the current interval.
        let (last_price, last_cumulative_price, last_interval) = get_recent_price_from(
            yang_id, interval - 1
        );

        let new_cumulative: Wad = last_cumulative_price
            + (last_price.val * (interval - last_interval - 1).into()).into()
            + price;

        yang_prices::write((yang_id, interval), (price, new_cumulative));

        YangPriceUpdated(yang, price, new_cumulative, interval);
    }

    // Sets the multiplier for the current interval
    #[external]
    fn set_multiplier(new_multiplier: Ray) {
        AccessControl::assert_has_role(ShrineRoles::SET_MULTIPLIER);

        // TODO: Should this be here? Maybe multiplier should be able to go to zero
        assert(new_multiplier.is_non_zero(), 'SH: Multiplier cannot be 0');
        assert(new_multiplier.val <= MAX_MULTIPLIER, 'SH: Multiplier exceeds maximum');

        let interval: u64 = now();
        let (last_multiplier, last_cumulative_multiplier, last_interval) =
            get_recent_multiplier_from(
            interval - 1
        );

        let new_cumulative_multiplier = last_cumulative_multiplier
            + ((interval - last_interval - 1).into() * last_multiplier.val).into()
            + new_multiplier;
        multiplier::write(interval, (new_multiplier, new_cumulative_multiplier));

        MultiplierUpdated(new_multiplier, new_cumulative_multiplier, interval);
    }

    // Updates spot price of yin
    //
    // Shrine denominates all prices (including that of yin) in yin, meaning yin's peg/target price is 1 (wad).
    // Therefore, it's expected that the spot price is denominated in yin, in order to
    // get the true deviation of the spot price from the peg/target price.
    #[external]
    fn update_yin_spot_price(new_price: Wad) {
        AccessControl::assert_has_role(ShrineRoles::UPDATE_YIN_SPOT_PRICE);
        YinPriceUpdated(yin_spot_price::read(), new_price);
        yin_spot_price::write(new_price);
    }

    // Update the base rates of all yangs
    // A base rate of USE_PREV_BASE_RATE means the base rate for the yang stays the same
    // Takes an array of yangs and their updated rates.
    // yangs[i]'s base rate will be set to new_rates[i]
    // yangs's length must equal the number of yangs available.
    #[external]
    fn update_rates(yangs: Span<ContractAddress>, new_rates: Span<Ray>) {
        AccessControl::assert_has_role(ShrineRoles::UPDATE_RATES);

        let yangs_len = yangs.len();
        let num_yangs: u32 = yangs_count::read();

        assert(
            yangs_len == new_rates.len() & yangs_len == num_yangs, 'SH: yangs.len != new_rates.len'
        );

        let latest_era: u64 = rates_latest_era::read();
        let latest_era_interval: u64 = rates_intervals::read(latest_era);
        let current_interval: u64 = now();

        // If the interest rates were already updated in the current interval, don't increment the era
        // Otherwise, increment the era
        // This way, there is at most one set of base rate updates in every interval
        let mut new_era = latest_era;

        if (latest_era_interval != current_interval) {
            new_era += 1;
            rates_latest_era::write(new_era);
            rates_intervals::write(new_era, current_interval);
        }

        // ALL yangs must have a new rate value. A new rate value of `USE_PREV_BASE_RATE` means the
        // yang's rate isn't being updated, and so we get the previous value.
        let mut yangs_copy = yangs;
        let mut new_rates_copy = new_rates;
        loop {
            match new_rates_copy.pop_front() {
                Option::Some(rate) => {
                    let current_yang_id: u32 = get_valid_yang_id(*yangs_copy.pop_front().unwrap());
                    if *rate.val == USE_PREV_BASE_RATE {
                        // Setting new era rate to the previous era's rate
                        yang_rates::write(
                            (current_yang_id, new_era),
                            yang_rates::read((current_yang_id, new_era - 1))
                        );
                    } else {
                        assert_rate_is_valid(*rate);
                        yang_rates::write((current_yang_id, new_era), *rate);
                    }
                },
                Option::None(_) => {
                    break;
                }
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
            assert(yang_rates::read((idx, new_era)).is_non_zero(), 'SH: Incorrect rate update');
            idx -= 1;
        };

        YangRatesUpdated(new_era, current_interval, yangs, new_rates);
    }

    // Deposit a specified amount of a Yang into a Trove
    #[external]
    fn deposit(yang: ContractAddress, trove_id: u64, amount: Wad) {
        AccessControl::assert_has_role(ShrineRoles::DEPOSIT);

        assert_live();

        charge(trove_id);

        let yang_id: u32 = get_valid_yang_id(yang);

        // Update yang balance of system
        let new_total: Wad = yang_total::read(yang_id) + amount;
        yang_total::write(yang_id, new_total);

        // Update trove balance
        let new_trove_balance: Wad = deposits::read((yang_id, trove_id)) + amount;
        deposits::write((yang_id, trove_id), new_trove_balance);

        // Events
        YangTotalUpdated(yang, new_total);
        DepositUpdated(yang, trove_id, new_trove_balance);
    }


    // Withdraw a specified amount of a Yang from a Trove with trove safety check
    #[external]
    fn withdraw(yang: ContractAddress, trove_id: u64, amount: Wad) {
        AccessControl::assert_has_role(ShrineRoles::WITHDRAW);
        // In the event the Shrine is killed, trove users can no longer withdraw yang
        // via the Abbot. Withdrawal of excess yang will be via the Caretaker instead.
        assert_live();
        withdraw_internal(yang, trove_id, amount);
        assert_healthy(trove_id);
    }

    // Mint a specified amount of synthetic and attribute the debt to a Trove
    #[external]
    fn forge(user: ContractAddress, trove_id: u64, amount: Wad, max_forge_fee_pct: Wad) {
        AccessControl::assert_has_role(ShrineRoles::FORGE);
        assert_live();

        charge(trove_id);

        let forge_fee_pct: Wad = get_forge_fee_pct();
        assert(forge_fee_pct <= max_forge_fee_pct, 'SH: forge_fee% > max_forge_fee%');

        let forge_fee = amount * forge_fee_pct;
        let debt_amount = amount + forge_fee;

        let mut new_system_debt = total_debt::read() + debt_amount;
        assert(new_system_debt <= debt_ceiling::read(), 'SH: Debt ceiling reached');
        total_debt::write(new_system_debt);

        // `Trove.charge_from` and `Trove.last_rate_era` were already updated in `charge`.
        let mut trove_info: Trove = troves::read(trove_id);
        trove_info.debt += debt_amount;
        troves::write(trove_id, trove_info);
        assert_healthy(trove_id);
        forge_internal(user, amount);

        // Events
        ForgeFeePaid(trove_id, forge_fee, forge_fee_pct);
        DebtTotalUpdated(new_system_debt);
        TroveUpdated(trove_id, trove_info);
    }

    // Repay a specified amount of synthetic and deattribute the debt from a Trove
    #[external]
    fn melt(user: ContractAddress, trove_id: u64, amount: Wad) {
        AccessControl::assert_has_role(ShrineRoles::MELT);
        // In the event the Shrine is killed, trove users can no longer repay their debt.
        // This also blocks liquidations by Purger.
        assert_live();

        // Charge interest
        charge(trove_id);

        let mut trove_info: Trove = troves::read(trove_id);

        // If `amount` exceeds `trove_info.debt`, then melt all the debt.
        // This is nice for UX so that maximum debt can be melted without knowing the exact
        // of debt in the trove down to the 10**-18.
        let melt_amt: Wad = min(trove_info.debt, amount);
        let new_system_debt: Wad = total_debt::read() - melt_amt;
        total_debt::write(new_system_debt);

        // `Trove.charge_from` and `Trove.last_rate_era` were already updated in `charge`.
        trove_info.debt -= melt_amt;
        troves::write(trove_id, trove_info);

        // Update user balance
        melt_internal(user, melt_amt);

        // Events
        DebtTotalUpdated(new_system_debt);
        TroveUpdated(trove_id, trove_info);
    }

    // Withdraw a specified amount of a Yang from a Trove without trove safety check.
    // This is intended for liquidations where collateral needs to be withdrawn and transferred to the liquidator
    // even if the trove is still unsafe.
    #[external]
    fn seize(yang: ContractAddress, trove_id: u64, amount: Wad) {
        AccessControl::assert_has_role(ShrineRoles::SEIZE);
        withdraw_internal(yang, trove_id, amount);
    }

    #[external]
    fn redistribute(trove_id: u64, debt_to_redistribute: Wad, pct_value_to_redistribute: Ray) {
        AccessControl::assert_has_role(ShrineRoles::REDISTRIBUTE);

        let current_interval: u64 = now();

        // Trove's debt should have been updated to the current interval via `melt` in `Purger.purge`.
        // The trove's debt is used instead of estimated debt from `get_trove_info` to ensure that
        // system has accounted for the accrued interest.
        let mut trove: Trove = troves::read(trove_id);

        // Increment redistribution ID
        let redistribution_id: u32 = redistributions_count::read() + 1;
        redistributions_count::write(redistribution_id);

        // Perform redistribution
        redistribute_internal(
            redistribution_id,
            trove_id,
            debt_to_redistribute,
            pct_value_to_redistribute,
            current_interval
        );

        trove.charge_from = current_interval;
        // Note that this will revert if `debt_to_redistribute` exceeds the trove's debt.
        trove.debt -= debt_to_redistribute;
        troves::write(trove_id, trove);

        // Update the redistribution ID so that it is not possible for the redistributed
        // trove to receive any of its own exceptional redistribution in the event of a
        // redistribution of an amount less than the trove's debt.
        // Note that the trove's last redistribution ID needs to be updated to
        // `redistribution_id - 1` prior to calling `redistribute`.
        trove_redistribution_id::write(trove_id, redistribution_id);

        // Event
        TroveRedistributed(redistribution_id, trove_id, debt_to_redistribute);
    }

    // Mint a specified amount of synthetic without attributing the debt to a Trove
    #[external]
    fn inject(receiver: ContractAddress, amount: Wad) {
        AccessControl::assert_has_role(ShrineRoles::INJECT);
        // Prevent any debt creation, including via flash mints, once the Shrine is killed
        assert_live();
        forge_internal(receiver, amount);
    }

    // Repay a specified amount of synthetic without deattributing the debt from a Trove
    #[external]
    fn eject(burner: ContractAddress, amount: Wad) {
        AccessControl::assert_has_role(ShrineRoles::EJECT);
        melt_internal(burner, amount);
    }

    // Set the timestamp when a Yang's suspension period started
    // Setting to 0 means the Yang is not suspended (i.e. it's deemed safe)
    #[external]
    fn update_yang_suspension(yang: ContractAddress, ts: u64) {
        AccessControl::assert_has_role(ShrineRoles::UPDATE_YANG_SUSPENSION);
        assert(ts <= get_block_timestamp(), 'SH: Invalid timestamp');
        assert(
            get_yang_suspension_status(yang) != YangSuspensionStatus::Permanent(()),
            'SH: Permanent suspension'
        );
        let yang_id: u32 = get_valid_yang_id(yang);
        yang_suspension::write(yang_id, ts);
    }


    //
    // Core Functions - public ERC20
    //

    #[external]
    fn transfer(recipient: ContractAddress, amount: u256) -> bool {
        transfer_internal(get_caller_address(), recipient, amount);
        true
    }

    #[external]
    fn transfer_from(sender: ContractAddress, recipient: ContractAddress, amount: u256) -> bool {
        spend_allowance_internal(sender, get_caller_address(), amount);
        transfer_internal(sender, recipient, amount);
        true
    }

    #[external]
    fn approve(spender: ContractAddress, amount: u256) -> bool {
        approve_internal(get_caller_address(), spender, amount);
        true
    }


    //
    // Core Functions - View
    //

    // Get the last updated price for a yang
    #[view]
    fn get_current_yang_price(yang: ContractAddress) -> (Wad, Wad, u64) {
        get_recent_price_from(get_valid_yang_id(yang), now())
    }


    // Gets last updated multiplier value
    #[view]
    fn get_current_multiplier() -> (Ray, Ray, u64) {
        get_recent_multiplier_from(now())
    }

    // Get yin spot price
    #[view]
    fn get_yin_spot_price() -> Wad {
        yin_spot_price::read()
    }

    // Returns the current forge fee
    // `forge_fee_pct` is a Wad and not Ray because the `exp` function
    // only returns Wads.
    #[view]
    #[inline(always)]
    fn get_forge_fee_pct() -> Wad {
        let yin_price: Wad = yin_spot_price::read();

        if yin_price >= MIN_ZERO_FEE_YIN_PRICE.into() {
            return 0_u128.into();
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
    #[view]
    fn is_healthy(trove_id: u64) -> bool {
        let (threshold, ltv, _, _) = get_trove_info(trove_id);
        ltv <= threshold
    }

    #[view]
    fn get_max_forge(trove_id: u64) -> Wad {
        let (threshold, _, value, debt) = get_trove_info(trove_id);

        let forge_fee_pct: Wad = get_forge_fee_pct();
        let max_debt: Wad = wadray::rmul_rw(threshold, value);

        if debt < max_debt {
            return (max_debt - debt) / (WAD_ONE.into() + forge_fee_pct);
        }

        0_u128.into()
    }

    //
    // Internal
    //

    // Check that system is live
    fn assert_live() {
        assert(is_live::read(), 'SH: System is not live');
    }

    // Helper function to get the yang ID given a yang address, and throw an error if
    // yang address has not been added (i.e. yang ID = 0)
    fn get_valid_yang_id(yang: ContractAddress) -> u32 {
        let yang_id: u32 = yang_ids::read(yang);
        assert(yang_id != 0, 'SH: Yang does not exist');
        yang_id
    }

    #[inline(always)]
    fn now() -> u64 {
        starknet::get_block_timestamp() / TIME_INTERVAL
    }

    fn set_threshold_internal(yang: ContractAddress, threshold: Ray) {
        assert(threshold.val <= MAX_THRESHOLD, 'SH: Threshold > max');
        thresholds::write(get_valid_yang_id(yang), threshold);

        // Event emission
        ThresholdUpdated(yang, threshold);
    }

    fn forge_internal(user: ContractAddress, amount: Wad) {
        yin::write(user, yin::read(user) + amount);
        total_yin::write(total_yin::read() + amount);

        Transfer(ContractAddressZeroable::zero(), user, amount.val.into());
    }

    fn melt_internal(user: ContractAddress, amount: Wad) {
        yin::write(user, yin::read(user) - amount);
        total_yin::write(total_yin::read() - amount);

        Transfer(user, ContractAddressZeroable::zero(), amount.val.into());
    }

    // Withdraw a specified amount of a Yang from a Trove
    fn withdraw_internal(yang: ContractAddress, trove_id: u64, amount: Wad) {
        let yang_id: u32 = get_valid_yang_id(yang);

        // Fails if amount > amount of yang deposited in the given trove
        let trove_yang_balance: Wad = deposits::read((yang_id, trove_id)) - amount;
        let total_yang: Wad = yang_total::read(yang_id) - amount;

        charge(trove_id);

        yang_total::write(yang_id, total_yang);
        deposits::write((yang_id, trove_id), trove_yang_balance);

        // Emit events
        YangTotalUpdated(yang, total_yang);
        DepositUpdated(yang, trove_id, trove_yang_balance);
    }

    // Asserts that `current_new_rate` is in the range (0, MAX_YANG_RATE]
    fn assert_rate_is_valid(rate: Ray) {
        assert(0 < rate.val & rate.val <= MAX_YANG_RATE, 'SH: Rate out of bounds');
    }

    // Adds the accumulated interest as debt to the trove
    fn charge(trove_id: u64) {
        // Do not charge accrued interest once Shrine is killed because total system debt
        // and individual trove's debt are fixed at the time of shutdown.
        if !is_live::read() {
            return;
        }

        let trove: Trove = troves::read(trove_id);

        // Get current interval and yang count
        let current_interval: u64 = now();

        // Get new debt amount
        let compounded_trove_debt: Wad = compound(trove_id, trove, current_interval);

        // Pull undistributed debt and update state
        let trove_last_redistribution_id: u32 = trove_redistribution_id::read(trove_id);
        let current_redistribution_id: u32 = redistributions_count::read();
        let (updated_trove_yang_balances, compounded_trove_debt_with_redistributed_debt, ) =
            pull_redistributed_debt_and_yangs(
            trove_id, compounded_trove_debt, trove_last_redistribution_id, current_redistribution_id
        );

        // If there was any exceptional redistribution, write updated yang_amts to trove
        if updated_trove_yang_balances.is_some() {
            let mut updated_trove_yang_balances = updated_trove_yang_balances.unwrap();
            loop {
                match updated_trove_yang_balances.pop_front() {
                    Option::Some(yang_balance) => {
                        deposits::write((*yang_balance.yang_id, trove_id), *yang_balance.amount);
                    },
                    Option::None(_) => {
                        break;
                    },
                };
            };
        }

        // Update trove
        let updated_trove: Trove = Trove {
            charge_from: current_interval,
            debt: compounded_trove_debt_with_redistributed_debt,
            last_rate_era: rates_latest_era::read()
        };
        troves::write(trove_id, updated_trove);
        trove_redistribution_id::write(trove_id, current_redistribution_id);

        // Get new system debt
        // This adds the interest charged on the trove's debt to the total debt.
        // This should not include redistributed debt, as that is already included in the total.
        let new_system_debt: Wad = total_debt::read() + (compounded_trove_debt - trove.debt);
        total_debt::write(new_system_debt);

        // Emit only if there is a change in the trove's debt
        if compounded_trove_debt != trove.debt {
            DebtTotalUpdated(new_system_debt);
        }

        // Emit only if there is a change in the `Trove` struct
        if updated_trove != trove {
            TroveUpdated(trove_id, updated_trove);
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
    fn compound(trove_id: u64, trove: Trove, end_interval: u64) -> Wad {
        // Saves gas and prevents bugs for troves with no yangs deposited
        // Implicit assumption is that a trove with non-zero debt must have non-zero yangs
        if trove.debt.is_zero() {
            return 0_u128.into();
        }

        let latest_rate_era: u64 = rates_latest_era::read();

        let mut compounded_debt: Wad = trove.debt;
        let mut start_interval: u64 = trove.charge_from;
        let mut trove_last_rate_era: u64 = trove.last_rate_era;

        loop {
            // `trove_last_rate_era` should always be less than or equal to `latest_rate_era`
            if trove_last_rate_era == latest_rate_era {
                let avg_base_rate: Ray = get_avg_rate_over_era(
                    trove_id, start_interval, end_interval, latest_rate_era
                );

                let avg_rate: Ray = avg_base_rate
                    * get_avg_multiplier(start_interval, end_interval);

                // represents `t` in the compound interest formula
                let t: Wad = Wad {
                    val: (end_interval - start_interval).into() * TIME_INTERVAL_DIV_YEAR
                };
                compounded_debt *= exp(wadray::rmul_rw(avg_rate, t));
                break compounded_debt;
            }

            let next_rate_update_era = trove_last_rate_era + 1;
            let next_rate_update_era_interval = rates_intervals::read(next_rate_update_era);

            let avg_base_rate: Ray = get_avg_rate_over_era(
                trove_id, start_interval, next_rate_update_era_interval, trove_last_rate_era
            );
            let avg_rate: Ray = avg_base_rate
                * get_avg_multiplier(start_interval, next_rate_update_era_interval);

            let t: Wad = Wad {
                val: (next_rate_update_era_interval - start_interval).into()
                    * TIME_INTERVAL_DIV_YEAR
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
        trove_id: u64, start_interval: u64, end_interval: u64, rate_era: u64
    ) -> Ray {
        let mut cumulative_weighted_sum: Ray = 0_u128.into();
        let mut cumulative_yang_value: Wad = 0_u128.into();

        let mut current_yang_id: u32 = yangs_count::read();

        let mut avg_rate: Ray = 0_u128.into();

        loop {
            // If all yangs have been iterated over, return the average rate
            if current_yang_id == 0 {
                // This operation would be a problem if the total trove value was ever zero.
                // However, `cumulative_yang_value` cannot be zero because a trove with no yangs deposited
                // cannot have any debt, meaning this code would never run (see `compound`)
                break wadray::wdiv_rw(cumulative_weighted_sum, cumulative_yang_value);
            }

            let yang_deposited: Wad = deposits::read((current_yang_id, trove_id));
            // Update cumulative values only if this yang has been deposited in the trove
            if yang_deposited.is_non_zero() {
                let yang_rate: Ray = yang_rates::read((current_yang_id, rate_era));
                let avg_price: Wad = get_avg_price(current_yang_id, start_interval, end_interval);
                let yang_value: Wad = yang_deposited * avg_price;
                let weighted_rate: Ray = wadray::wmul_wr(yang_value, yang_rate);

                cumulative_weighted_sum += weighted_rate;
                cumulative_yang_value += yang_value;
            }
            current_yang_id -= 1;
        }
    }

    // Loop through yangs for the trove:
    // 1. redistribute a yang according to the percentage value to be redistributed by either:
    //    a. if at least one other trove has deposited that yang, decrementing the trove's yang
    //       balance and total yang supply by the amount redistributed; or
    //    b. otherwise, redistribute this yang to all other yangs that at least one other trove
    //       has deposited, by decrementing the trove's yang balance only;
    // 2. redistribute the proportional debt for that yang:
    //    a. if at least one other trove has deposited that yang, divide the debt by the
    //       remaining amount of yang excluding the initial yang amount and the redistributed trove's
    //       balance; or
    //    b. otherwise, divide the debt across all other yangs that at least one other trove has
    //       deposited excluding the initial yang amount;
    //    and in both cases, store the fixed point division error, and write to storage.
    //
    // Note that this internal function will revert if `pct_value_to_redistribute` exceeds
    // one Ray (100%), due to an overflow when deducting the redistributed amount of yang from
    // the trove.
    fn redistribute_internal(
        redistribution_id: u32,
        trove_id: u64,
        debt_to_redistribute: Wad,
        pct_value_to_redistribute: Ray,
        current_interval: u64
    ) {
        let yangs_count: u32 = yangs_count::read();

        // Placeholders to be used for exceptional redistributions so that
        // `get_shrine_threshold_and_value` only needs to be called once
        let mut shrine_value: Wad = WadZeroable::zero();
        let mut other_troves_total_value: Wad = WadZeroable::zero();
        // Boolean flag to keep track of whether the main loop has encountered the first yang
        // that requires an exceptional redistribution so that we do not make multiple calls
        // to `get_shrine_threshold_and_value_internal` which is expensive.
        let mut has_exceptional_redistribution: bool = false;

        // For exceptional redistribution of yangs (i.e. not deposited by any other troves, and
        // which may be the first yang or the last yang), we need the total yang supply for all
        // yangs (regardless how they are to be redistributed) to remain constant throughout the
        // iteration over the yangs deposited in the trove. Therefore, we keep track of the
        // updated total supply and the redistributed trove's remainder amount for each yang,
        // and only update them after the loop. Note that for ordinary redistribution of yangs,
        // the remainder yang balance after redistribution will also need to be adjusted if the
        // trove's value is not redistributed in full.
        //
        // For yangs that cannot be redistributed via rebasing because no other troves
        // have deposited that yang, keep track of their yang IDs so that the redistributed
        // trove's yang amount can be updated after the main loop. The troves' yang amount
        // cannot be modified while in the main loop for such yangs because it would result
        // in the amount of yangs for other troves to be calculated wrongly.
        //
        // For example, assuming the redistributed trove has yang1, yang2 and yang3, but the
        // only other recipient trove has yang2:
        // 1) First, redistribute yang3 to yang1 (0%) and yang2 (100%). Here, assuming, we set
        //    yang3 amount for redistributed trove to 0. Total yang3 amount remains unchanged
        //    because they have been reallocated to remaining yang2 in other troves.
        // 2) Next, redistribute yang2 as per the normal flow.
        // 3) Finally, redistribute yang1. Here, we expect the yang2 to receive 100%. However,
        //    since we set yang3 amount for redistributed trove to 0, but total yang3 amount
        //    remains unchanged, the total amount of yang3 in other troves is now wrongly
        //    calculated to be the total amount of yang3 in the system.
        //
        // In addition, we need to keep track of the updated total supply for the redistributed yang:
        // (1) for ordinary redistributions, if the trove's value is not entirely redistributed,
        //     we need to account for the appreciation of the remainder yang amounts of the
        //     redistributed trove by decrementing both the trove's yang balance and the total supply;
        // (2) for exceptional redistributions, we need to deduct the error from loss of precision
        //     arising from any exceptional redistribution so that we can update it at the end to ensure subsequent redistributions of collateral
        //     and debt can all be attributed to troves.
        // This has the side effect of rebasing the asset amount per yang.

        // For yangs that can be redistributed via rebasing, the total supply needs to be
        // unchanged to ensure that the shrine's total value remains unchanged when looping over
        // the yangs. This allows the gas-intensive `get_shrine_threshold_and_value`
        // in the exceptional flow to be called only when needed and still return the correct
        // value regardless of the order of the yang that is to be redistributed exceptionally.
        //
        // For example, assuming the redistributed trove has yang1, yang2 and yang3, and the
        // only other recipient trove has yang2 and yang3.
        // 1) First, redistribute yang3 via rebasing. The yang3 amount for redistributed trove is
        //    set to 0, and the total yang3 amount is decremented by the redistributed trove's
        //    deposited amount.
        // 2) Next, redistribute yang2 via rebasing. The yang2 amount for redistributed trove is
        //    set to 0, and the total yang2 amount is decremented by the redistributed trove's
        //    deposited amount.
        // 3) Finally, redistribute yang1. Now, we want to calculate the shrine's value to
        //    determine how much of yang1 and its proportional debt should be redistributed between
        //    yang2 and yang3. However, the total shrine value is now incorrect because yang2 and
        //    yang3 total yang amounts have decremented, but the yang prices have not been updated.
        //
        // Note that these two arrays should be equal in length at the end of the main loop.
        let mut new_yang_totals: Array<YangBalance> = Default::default();
        let mut updated_trove_yang_balances: Array<YangBalance> = Default::default();

        let trove_yang_balances: Span<YangBalance> = get_trove_deposits(trove_id);
        let (_, trove_value) = get_trove_threshold_and_value_internal(trove_id, current_interval);
        let trove_value_to_redistribute: Wad = wadray::rmul_wr(
            trove_value, pct_value_to_redistribute
        );

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
                        updated_trove_yang_balances.append(*yang_balance);
                        continue;
                    }

                    let yang_amt_to_redistribute: Wad = wadray::rmul_wr(
                        trove_yang_amt, pct_value_to_redistribute
                    );
                    let mut updated_trove_yang_balance: Wad = trove_yang_amt
                        - yang_amt_to_redistribute;

                    let redistributed_yang_total_supply: Wad = yang_total::read(
                        yang_id_to_redistribute
                    );
                    let redistributed_yang_initial_amt: Wad = initial_yang_amts::read(
                        yang_id_to_redistribute
                    );

                    // Get the remainder amount of yangs in all other troves that can be redistributed
                    // This excludes any remaining yang in the redistributed trove if the percentage to
                    // be redistributed is less than 100%.
                    let redistributed_yang_recipient_pool: Wad = redistributed_yang_total_supply
                        - trove_yang_amt
                        - redistributed_yang_initial_amt;

                    // Calculate the actual amount of debt that should be redistributed, including any
                    // rounding of dust amounts of debt.
                    let (redistributed_yang_price, _, _) = get_recent_price_from(
                        yang_id_to_redistribute, current_interval
                    );

                    let mut raw_debt_to_distribute_for_yang: Wad = WadZeroable::zero();
                    let mut debt_to_distribute_for_yang: Wad = WadZeroable::zero();

                    if trove_value_to_redistribute.is_non_zero() {
                        let yang_debt_pct: Ray = wadray::rdiv_ww(
                            yang_amt_to_redistribute * redistributed_yang_price,
                            trove_value_to_redistribute
                        );
                        raw_debt_to_distribute_for_yang =
                            wadray::rmul_rw(yang_debt_pct, debt_to_redistribute);
                        let (tmp_debt_to_distribute_for_yang, updated_redistributed_debt) =
                            round_distributed_debt(
                            debt_to_redistribute,
                            raw_debt_to_distribute_for_yang,
                            redistributed_debt
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

                    // Adjust debt to distribute by adding the error from the last redistribution
                    let last_error: Wad = get_recent_redistribution_error_for_yang(
                        yang_id_to_redistribute, redistribution_id - 1
                    );
                    let adjusted_debt_to_distribute_for_yang: Wad = debt_to_distribute_for_yang
                        + last_error;

                    // Placeholders for `YangRedistribution` struct members
                    let mut redistributed_yang_unit_debt: Wad = WadZeroable::zero();
                    let mut debt_error: Wad = WadZeroable::zero();
                    let mut is_exception: bool = false;

                    // If there is some remainder amount of yangs that is at least 1 Wad in other troves
                    // for redistribution, handle it as an ordinary redistribution by redistributing
                    //  yangs by rebasing, and reallocating debt to other troves with the same yang. 
                    // This is expected to be the common case.
                    // Otherwise, redistribute by reallocating the yangs and debt to all other yangs.
                    //
                    // The minimum remainder amount is required to prevent overflow when calculating 
                    // `unit_yang_per_recipient_redistributed_yang` below, and to prevent 
                    // `updated_trove_yang_balance` from being incorrectly zeroed when 
                    // `unit_yang_per_recipient_redistributed_yang` is a very large value.
                    let is_ordinary_redistribution: bool =
                        redistributed_yang_recipient_pool >= WAD_ONE
                        .into();
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
                        //                                            remaining_trove_yang
                        // adjusted_remaining_trove_yang = ---------------------------------------
                        //                                 (1 + unit_yang_per_recipient_pool_yang)
                        //
                        // where `unit_yang_per_recipient_pool_yang` is the amount of redistributed yang to be redistributed
                        // to each Wad unit in `redistributed_yang_recipient_pool + redistributed_yang_initial_amt` - note 
                        // that the initial yang amount needs to be included because it also benefits from the rebasing:
                        //
                        //                                                          yang_amt_to_redistribute
                        // unit_yang_per_recipient_redistributed_yang = ------------------------------------------------------------------
                        //                                              redistributed_yang_recipient_pool + redistributed_yang_initial_amt

                        let unit_yang_per_recipient_redistributed_yang: Ray = wadray::rdiv_ww(
                            yang_amt_to_redistribute,
                            (redistributed_yang_recipient_pool + redistributed_yang_initial_amt)
                        );
                        let remaining_trove_yang: Wad = trove_yang_amt - yang_amt_to_redistribute;
                        updated_trove_yang_balance =
                            wadray::rdiv_wr(
                                remaining_trove_yang,
                                (RAY_ONE.into() + unit_yang_per_recipient_redistributed_yang)
                            );

                        // Note that the trove's deposit and total supply are updated after this loop.
                        // See comment at this array's declaration on why.
                        let yang_offset: Wad = remaining_trove_yang - updated_trove_yang_balance;
                        new_yang_totals
                            .append(
                                YangBalance {
                                    yang_id: yang_id_to_redistribute,
                                    amount: redistributed_yang_total_supply
                                        - yang_amt_to_redistribute
                                        - yang_offset
                                }
                            );

                        // There is a slight discrepancy here because yang is redistributed by rebasing,
                        // which means the initial yang amount is included, but the distribution of debt excludes
                        // the initial yang amount. However, it is unlikely to have any material impact because
                        // all redistributed debt will be attributed to user troves, with a negligible loss in
                        // yang assets for these troves as a result of some amount going towards the initial yang
                        // amount.
                        redistributed_yang_unit_debt = adjusted_debt_to_distribute_for_yang
                            / redistributed_yang_recipient_pool;

                        // Due to loss of precision from fixed point division, the actual debt distributed will be less than
                        // or equal to the amount of debt to distribute.
                        let actual_debt_distributed: Wad = redistributed_yang_unit_debt
                            * redistributed_yang_recipient_pool;
                        debt_error = adjusted_debt_to_distribute_for_yang - actual_debt_distributed;
                    } else {
                        if !has_exceptional_redistribution {
                            // This operation is gas-intensive so we only run it when we encounter the first
                            // yang that cannot be distributed via rebasing, and store the value in the
                            // placeholders declared at the beginning of this function.
                            let (_, tmp_shrine_value) = get_shrine_threshold_and_value_internal(
                                current_interval
                            );
                            shrine_value = tmp_shrine_value;
                            // Note the initial yang amount is not excluded from the value of all other troves
                            // here (it will also be more expensive if we want to do so). Therefore, when
                            // calculating a yang's total value as a percentage of the total value of all
                            // other troves, the value of the initial yang amount should be included too.
                            other_troves_total_value = shrine_value - trove_value;

                            // Update boolean flag so that we do not call `get_shrine_threshold_and_value`
                            // again for any subsequent yangs that require exceptional redistributions.
                            has_exceptional_redistribution = true;
                        }

                        // Keep track of the actual debt and yang distributed to calculate error at the end
                        // This is necessary for yang so that subsequent redistributions do not accrue to the
                        // earlier redistributed yang amount that cannot be attributed to any troves due to
                        // loss of precision.
                        let mut actual_debt_distributed: Wad = WadZeroable::zero();
                        let mut actual_yang_distributed: Wad = WadZeroable::zero();

                        let mut trove_recipient_yang_balances = trove_yang_balances;
                        // Inner loop over all yangs
                        loop {
                            match trove_recipient_yang_balances.pop_front() {
                                Option::Some(recipient_yang) => {
                                    // Skip yang currently being redistributed
                                    if *recipient_yang.yang_id == yang_id_to_redistribute {
                                        continue;
                                    }

                                    let recipient_yang_initial_amt: Wad = initial_yang_amts::read(
                                        *recipient_yang.yang_id
                                    );
                                    // Get the total amount of recipient yang that will receive the
                                    // redistribution, which excludes
                                    // (1) the redistributed trove's deposit; and
                                    // (2) initial yang amount.
                                    let recipient_yang_recipient_pool: Wad = yang_total::read(
                                        *recipient_yang.yang_id
                                    )
                                        - *recipient_yang.amount
                                        - recipient_yang_initial_amt;

                                    // Skip to the next yang if no other troves have this yang
                                    if recipient_yang_recipient_pool.is_zero() {
                                        continue;
                                    }

                                    let (recipient_yang_price, _, _) = get_recent_price_from(
                                        *recipient_yang.yang_id, current_interval
                                    );

                                    // Note that we include the initial yang amount here to calculate the percentage
                                    // because the total Shrine value will include the initial yang amounts too
                                    let recipient_yang_recipient_pool_value: Wad =
                                        (recipient_yang_recipient_pool
                                        + recipient_yang_initial_amt)
                                        * recipient_yang_price;
                                    let pct_to_redistribute_to_recipient_yang: Ray =
                                        wadray::rdiv_ww(
                                        recipient_yang_recipient_pool_value,
                                        other_troves_total_value
                                    );

                                    // Allocate the redistributed yang to the recipient yang
                                    let partial_yang_amt_to_redistribute: Wad = wadray::rmul_wr(
                                        yang_amt_to_redistribute,
                                        pct_to_redistribute_to_recipient_yang
                                    );
                                    let unit_yang: Wad = partial_yang_amt_to_redistribute
                                        / recipient_yang_recipient_pool;

                                    actual_yang_distributed += unit_yang
                                        * recipient_yang_recipient_pool;

                                    // Distribute debt to the recipient yang
                                    let partial_adjusted_debt_to_distribute_for_yang: Wad =
                                        wadray::rmul_wr(
                                        adjusted_debt_to_distribute_for_yang,
                                        pct_to_redistribute_to_recipient_yang
                                    );
                                    let unit_debt: Wad =
                                        partial_adjusted_debt_to_distribute_for_yang
                                        / recipient_yang_recipient_pool;

                                    // Keep track of debt distributed to calculate error at the end
                                    actual_debt_distributed += unit_debt
                                        * recipient_yang_recipient_pool;

                                    // Update the distribution of the redistributed yang for the
                                    // current recipient yang
                                    let exc_yang_redistribution = ExceptionalYangRedistribution {
                                        unit_debt, unit_yang, 
                                    };

                                    yang_to_yang_redistribution::write(
                                        (
                                            *recipient_yang.yang_id,
                                            redistribution_id,
                                            yang_id_to_redistribute
                                        ),
                                        exc_yang_redistribution
                                    );
                                },
                                Option::None(_) => {
                                    break;
                                },
                            };
                        };

                        is_exceptional_redistribution::write(redistribution_id, true);
                        is_exception = true;

                        // Unit debt is zero because it has been redistributed to other yangs, but error
                        // can still be derived from the redistribution across other recipient yangs and
                        // propagated.
                        debt_error = adjusted_debt_to_distribute_for_yang - actual_debt_distributed;

                        // The redistributed yang which was not distributed to recipient yangs due to precision loss,
                        // is subtracted here from the total supply, thereby causing a rebase which increases the
                        // asset : yang ratio. The result is that the error is distributed equally across all yang holders,
                        // including any new holders who were credited this yang by the exceptional redistribution.
                        let yang_error: Wad = yang_amt_to_redistribute - actual_yang_distributed;
                        new_yang_totals
                            .append(
                                YangBalance {
                                    yang_id: yang_id_to_redistribute,
                                    amount: redistributed_yang_total_supply - yang_error
                                }
                            );
                    }

                    let redistributed_yang_info = YangRedistribution {
                        unit_debt: redistributed_yang_unit_debt,
                        error: debt_error,
                        exception: is_exception
                    };
                    yang_redistributions::write(
                        (yang_id_to_redistribute, redistribution_id), redistributed_yang_info
                    );

                    updated_trove_yang_balances
                        .append(
                            YangBalance {
                                yang_id: yang_id_to_redistribute, amount: updated_trove_yang_balance
                            }
                        );

                    // If debt was rounded up, meaning it is now fully redistributed, skip the remaining yangs
                    // Otherwise, continue the iteration
                    if debt_to_distribute_for_yang != raw_debt_to_distribute_for_yang {
                        break;
                    }
                },
                Option::None(_) => {
                    break;
                },
            };
        };

        // See comment at both arrays' declarations on why this is necessary
        let mut new_yang_totals: Span<YangBalance> = new_yang_totals.span();
        let mut updated_trove_yang_balances: Span<YangBalance> = updated_trove_yang_balances.span();
        loop {
            match new_yang_totals.pop_front() {
                Option::Some(total_yang_balance) => {
                    let updated_trove_yang_balance: YangBalance = *updated_trove_yang_balances
                        .pop_front()
                        .unwrap();
                    deposits::write(
                        (updated_trove_yang_balance.yang_id, trove_id),
                        updated_trove_yang_balance.amount
                    );

                    yang_total::write(*total_yang_balance.yang_id, *total_yang_balance.amount);
                },
                Option::None(_) => {
                    break;
                },
            };
        };
    }

    // Returns the last error for `yang_id` at a given `redistribution_id` if the error is non-zero.
    // Otherwise, check `redistribution_id` - 1 recursively for the last error.
    fn get_recent_redistribution_error_for_yang(yang_id: u32, redistribution_id: u32) -> Wad {
        if redistribution_id == 0 {
            return 0_u128.into();
        }

        let redistribution: YangRedistribution = yang_redistributions::read(
            (yang_id, redistribution_id)
        );

        // If redistribution unit-debt is non-zero or the error is non-zero, return the error
        // This catches both the case where the unit debt is non-zero and the error is zero, and the case
        // where the unit debt is zero (due to very large amounts of yang) and the error is non-zero.
        if redistribution.unit_debt.is_non_zero() | redistribution.error.is_non_zero() {
            return redistribution.error;
        }

        get_recent_redistribution_error_for_yang(yang_id, redistribution_id - 1)
    }

    // Helper function to round up the debt to be redistributed for a yang if the remaining debt
    // falls below the defined threshold, so as to avoid rounding errors and ensure that the amount
    // of debt redistributed is equal to amount intended to be redistributed
    fn round_distributed_debt(
        total_debt_to_distribute: Wad, debt_to_distribute: Wad, cumulative_redistributed_debt: Wad
    ) -> (Wad, Wad) {
        let updated_cumulative_redistributed_debt = cumulative_redistributed_debt
            + debt_to_distribute;
        let remaining_debt: Wad = total_debt_to_distribute - updated_cumulative_redistributed_debt;

        if remaining_debt.val <= ROUNDING_THRESHOLD {
            return (
                debt_to_distribute + remaining_debt,
                updated_cumulative_redistributed_debt + remaining_debt
            );
        }

        (debt_to_distribute, updated_cumulative_redistributed_debt)
    }

    // Returns an ordered array of the `YangBalance` struct for a trove's deposits.
    // Starts from yang ID 1.
    fn get_trove_deposits(trove_id: u64) -> Span<YangBalance> {
        let mut yang_balances: Array<YangBalance> = Default::default();

        let yangs_count: u32 = yangs_count::read();
        let mut current_yang_id: u32 = START_YANG_IDX;
        loop {
            if current_yang_id == yangs_count + START_YANG_IDX {
                break yang_balances.span();
            }

            let deposited: Wad = deposits::read((current_yang_id, trove_id));
            yang_balances.append(YangBalance { yang_id: current_yang_id, amount: deposited });

            current_yang_id += 1;
        }
    }

    // Takes in a value for the trove's debt, and returns the following:
    // 1. `Option::None` if there were no exceptional redistributions.
    //    Otherwise, an ordered array of yang amounts including any exceptional redistributions,
    //    starting from yang ID 1
    // 2. updated redistributed debt, if any, otherwise it would be equivalent to the trove debt.
    fn pull_redistributed_debt_and_yangs(
        trove_id: u64,
        mut trove_debt: Wad,
        trove_last_redistribution_id: u32,
        current_redistribution_id: u32
    ) -> (Option<Span<YangBalance>>, Wad) {
        let mut has_exceptional_redistributions: bool = false;

        let mut trove_yang_balances: Span<YangBalance> = get_trove_deposits(trove_id);
        // Early termination if no redistributions since trove was last updated
        if current_redistribution_id == trove_last_redistribution_id {
            return (Option::None(()), trove_debt);
        }

        let yangs_count: u32 = yangs_count::read();

        // Outer loop over redistribution IDs.
        // We need to iterate over redistribution IDs, because redistributed collateral from exceptional
        // redistributions may in turn receive subsequent redistributions
        let mut tmp_redistribution_id: u32 = trove_last_redistribution_id + 1;

        // Offset to be applied to the yang ID when indexing into the `trove_yang_balances` array
        let yang_id_to_array_idx_offset: u32 = 1;
        let loop_end: u32 = current_redistribution_id + 1;
        loop {
            if tmp_redistribution_id == loop_end {
                break;
            }

            let is_exceptional: bool = is_exceptional_redistribution::read(tmp_redistribution_id);
            if is_exceptional {
                has_exceptional_redistributions = true;
            }

            let mut original_yang_balances_copy = trove_yang_balances;
            // Inner loop over all yangs
            loop {
                match original_yang_balances_copy.pop_front() {
                    Option::Some(original_yang_balance) => {
                        let redistribution: YangRedistribution = yang_redistributions::read(
                            (*original_yang_balance.yang_id, tmp_redistribution_id)
                        );
                        // If the trove has deposited a yang, check for ordinary redistribution first.
                        // Note that we cannot skip to the next yang because we still need to check 
                        // for exceptional redistribution in case the recipient pool amount was below the 
                        // redistribution threshold.
                        if (*original_yang_balance.amount).is_non_zero() {
                            // Get the amount of debt per yang for the current redistribution
                            if redistribution.unit_debt.is_non_zero() {
                                trove_debt += redistribution.unit_debt
                                    * *original_yang_balance.amount;
                            }
                        }

                        // If it is not an exceptional redistribution, and trove does not have this yang
                        // deposited, then skip to the next yang.
                        if !is_exceptional {
                            continue;
                        }

                        // Otherwise, it is an exceptional redistribution and the yang was distributed
                        // between all other yangs.
                        if redistribution.exception {
                            // Compute threshold for rounding up outside of inner loop
                            let wad_scale: u256 = WAD_SCALE.into();
                            let wad_scale_divisor: NonZero<u256> = wad_scale.try_into().unwrap();

                            // Keep track of the amount of redistributed yang that the trove will receive
                            let mut yang_increment: Wad = WadZeroable::zero();
                            let mut cumulative_r: u256 = U256Zeroable::zero();

                            // Inner loop iterating over all yangs to calculate the total amount
                            // of the redistributed yang this trove should receive
                            let mut trove_recipient_yang_balances = trove_yang_balances;
                            loop {
                                match trove_recipient_yang_balances.pop_front() {
                                    Option::Some(recipient_yang_balance) => {
                                        let exc_yang_redistribution: ExceptionalYangRedistribution =
                                            yang_to_yang_redistribution::read(
                                            (
                                                *recipient_yang_balance.yang_id,
                                                tmp_redistribution_id,
                                                *original_yang_balance.yang_id
                                            )
                                        );

                                        // Skip if trove does not have any of this yang
                                        if (*recipient_yang_balance.amount).is_zero() {
                                            continue;
                                        }

                                        yang_increment += *recipient_yang_balance.amount
                                            * exc_yang_redistribution.unit_yang;

                                        let (debt_increment, r) = u256_safe_divmod(
                                            (*recipient_yang_balance.amount).into()
                                                * exc_yang_redistribution.unit_debt.into(),
                                            wad_scale_divisor
                                        );
                                        // Accumulate remainder from fixed point division for subsequent addition
                                        // to minimize precision loss
                                        cumulative_r += r;

                                        trove_debt += debt_increment.try_into().unwrap();
                                    },
                                    Option::None(_) => {
                                        break;
                                    },
                                };
                            };

                            // Handle loss of precision from fixed point operations as much as possible
                            // by adding the cumulative remainder. Note that we do not round up here
                            // because it could be too aggressive and may lead to `sum(trove_debt) > total_debt`,
                            // which would result in an overflow if all troves repaid their debt.
                            let cumulative_r: u128 = cumulative_r.try_into().unwrap();
                            trove_debt += (cumulative_r / WAD_SCALE).into();

                            // Create a new `trove_yang_balances` to include the redistributed yang
                            // pulled to the trove.
                            // Note that this should be ordered with yang IDs starting from 1,
                            // similar to `get_trove_deposits`, so that the downward iteration
                            // in the previous loop can also be used to index into the array
                            // for the correct yang ID with 1 offset.
                            let mut updated_trove_yang_balances: Array<YangBalance> =
                                Default::default();
                            let mut yang_id: u32 = START_YANG_IDX;
                            loop {
                                if yang_id == yangs_count + START_YANG_IDX {
                                    break;
                                }

                                if yang_id == *original_yang_balance.yang_id {
                                    updated_trove_yang_balances
                                        .append(
                                            YangBalance { yang_id: yang_id, amount: yang_increment }
                                        );
                                } else {
                                    updated_trove_yang_balances
                                        .append(
                                            *trove_yang_balances
                                                .at(yang_id - yang_id_to_array_idx_offset)
                                        );
                                }

                                yang_id += 1;
                            };

                            trove_yang_balances = updated_trove_yang_balances.span();
                        }
                    },
                    Option::None(_) => {
                        break;
                    },
                };
            };

            tmp_redistribution_id += 1;
        };

        if has_exceptional_redistributions {
            (Option::Some(trove_yang_balances), trove_debt)
        } else {
            (Option::None(()), trove_debt)
        }
    }

    // Returns the price for `yang_id` at `interval` if it is non-zero.
    // Otherwise, check `interval` - 1 recursively for the last available price.
    fn get_recent_price_from(yang_id: u32, interval: u64) -> (Wad, Wad, u64) {
        let (price, cumulative_price) = yang_prices::read((yang_id, interval));

        if price.is_non_zero() {
            return (price, cumulative_price, interval);
        }
        get_recent_price_from(yang_id, interval - 1)
    }

    // Returns the average price for a yang between two intervals, including `end_interval` but NOT including `start_interval`
    // - If `start_interval` is the same as `end_interval`, return the price at that interval.
    // - If `start_interval` is different from `end_interval`, return the average price.
    fn get_avg_price(yang_id: u32, start_interval: u64, end_interval: u64) -> Wad {
        let (start_yang_price, start_cumulative_yang_price, available_start_interval) =
            get_recent_price_from(
            yang_id, start_interval
        );
        let (end_yang_price, end_cumulative_yang_price, available_end_interval) =
            get_recent_price_from(
            yang_id, end_interval
        );

        // If the last available price for both start and end intervals are the same,
        // return that last available price
        // This also catches `start_interval == end_interval`
        if available_start_interval == available_end_interval {
            return start_yang_price;
        }

        let mut cumulative_diff: Wad = end_cumulative_yang_price - start_cumulative_yang_price;

        // Early termination if `start_interval` and `end_interval` are updated
        if start_interval == available_start_interval & end_interval == available_end_interval {
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
        if (end_interval != available_end_interval) {
            let cumulative_offset = Wad {
                val: (end_interval - available_end_interval).into() * end_yang_price.val
            };
            cumulative_diff += cumulative_offset;
        }

        (cumulative_diff.val / (end_interval - start_interval).into()).into()
    }

    // Returns the multiplier at `interval` if it is non-zero.
    // Otherwise, check `interval` - 1 recursively for the last available value.
    fn get_recent_multiplier_from(interval: u64) -> (Ray, Ray, u64) {
        let (multiplier, cumulative_multiplier) = multiplier::read(interval);
        if multiplier.is_non_zero() {
            return (multiplier, cumulative_multiplier, interval);
        }
        get_recent_multiplier_from(interval - 1)
    }

    // Returns the average multiplier over the specified time period, including `end_interval` but NOT including `start_interval`
    // - If `start_interval` is the same as `end_interval`, return the multiplier value at that interval.
    // - If `start_interval` is different from `end_interval`, return the average.
    // Return value is a tuple so that function can be modified as an external view for testing
    fn get_avg_multiplier(start_interval: u64, end_interval: u64) -> Ray {
        let (start_multiplier, start_cumulative_multiplier, available_start_interval) =
            get_recent_multiplier_from(
            start_interval
        );
        let (end_multiplier, end_cumulative_multiplier, available_end_interval) =
            get_recent_multiplier_from(
            end_interval
        );

        // If the last available multiplier for both start and end intervals are the same,
        // return that last available multiplier
        // This also catches `start_interval == end_interval`
        if available_start_interval == available_end_interval {
            return start_multiplier;
        }

        let mut cumulative_diff: Ray = end_cumulative_multiplier - start_cumulative_multiplier;

        // Early termination if `start_interval` and `end_interval` are updated
        if start_interval == available_start_interval & end_interval == available_end_interval {
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

    //
    // Trove health internal functions
    //

    fn assert_healthy(trove_id: u64) {
        assert(is_healthy(trove_id), 'SH: Trove LTV is too high');
    }

    // Returns a tuple of the trove's threshold (maximum LTV before liquidation) and the total trove value, at a given interval.
    // This function uses historical prices but the currently deposited yang amounts to calculate value.
    // The underlying assumption is that the amount of each yang deposited at `interval` is the same as the amount currently deposited.
    fn get_trove_threshold_and_value_internal(trove_id: u64, interval: u64) -> (Ray, Wad) {
        let mut current_yang_id: u32 = yangs_count::read();
        let mut weighted_threshold_sum: Ray = 0_u128.into();
        let mut trove_value: Wad = 0_u128.into();

        loop {
            if current_yang_id == 0 {
                break;
            }

            let deposited: Wad = deposits::read((current_yang_id, trove_id));
            // Update cumulative values only if user has deposited the current yang
            if deposited.is_non_zero() {
                let yang_threshold: Ray = get_yang_threshold_internal(current_yang_id);
                let (price, _, _) = get_recent_price_from(current_yang_id, interval);
                let yang_deposited_value = deposited * price;
                trove_value += yang_deposited_value;
                weighted_threshold_sum += wadray::wmul_rw(yang_threshold, yang_deposited_value);
            }

            current_yang_id -= 1;
        };

        if trove_value.is_non_zero() {
            let trove_threshold: Ray = wadray::wdiv_rw(weighted_threshold_sum, trove_value);
            return (scale_threshold_for_recovery_mode(trove_threshold), trove_value);
        }

        (0_u128.into(), 0_u128.into())
    }

    // Helper function for applying the recovery mode threshold decrease to a threshold,
    // if recovery mode is active
    // The maximum threshold decrease is capped to 50% of the "base threshold"
    fn scale_threshold_for_recovery_mode(mut threshold: Ray) -> Ray {
        let (recovery_mode_threshold, shrine_ltv) = get_recovery_mode_threshold();
        if shrine_ltv >= recovery_mode_threshold {
            threshold =
                max(
                    threshold
                        * THRESHOLD_DECREASE_FACTOR.into()
                        * (recovery_mode_threshold / shrine_ltv),
                    (threshold.val / 2_u128).into()
                );
        }

        threshold
    }

    // Helper to manually calculate what a trove's threshold and value at the given interval would be
    // if its yang balances were equivalent to the `trove_yang_balances` argument.
    fn get_simulated_trove_threshold_and_value(
        mut trove_yang_balances: Span<YangBalance>, interval: u64
    ) -> (Ray, Wad) {
        let mut trove_value: Wad = WadZeroable::zero();
        let mut weighted_threshold_sum: Ray = RayZeroable::zero();
        loop {
            match trove_yang_balances.pop_front() {
                Option::Some(yang_balance) => {
                    // Update cumulative values only if user has deposited the current yang
                    if (*yang_balance.amount).is_non_zero() {
                        let yang_threshold: Ray = get_yang_threshold_internal(
                            *yang_balance.yang_id
                        );

                        let (price, _, _) = get_recent_price_from(*yang_balance.yang_id, interval);

                        let yang_deposited_value = *yang_balance.amount * price;
                        trove_value += yang_deposited_value;
                        weighted_threshold_sum +=
                            wadray::wmul_rw(yang_threshold, yang_deposited_value);
                    }
                },
                Option::None(_) => {
                    break;
                },
            };
        };

        if trove_value.is_non_zero() {
            let trove_threshold = wadray::wdiv_rw(weighted_threshold_sum, trove_value);
            return (scale_threshold_for_recovery_mode(trove_threshold), trove_value);
        }

        (RayZeroable::zero(), WadZeroable::zero())
    }

    // Returns a tuple of the threshold and value of all troves combined.
    // This function uses historical prices but the total amount of currently deposited yangs across
    // all troves to calculate the total value of all troves.
    fn get_shrine_threshold_and_value_internal(current_interval: u64) -> (Ray, Wad) {
        let mut current_yang_id: u32 = yangs_count::read();
        let mut weighted_threshold_sum: Ray = 0_u128.into();
        let mut value: Wad = 0_u128.into();

        loop {
            if current_yang_id == 0 {
                break;
            }

            let deposited: Wad = yang_total::read(current_yang_id);

            // Update cumulative values only if current yang has been deposited
            if deposited.is_non_zero() {
                let yang_threshold: Ray = get_yang_threshold_internal(current_yang_id);

                let (price, _, _) = get_recent_price_from(current_yang_id, current_interval);

                let yang_deposited_value = deposited * price;
                value += yang_deposited_value;
                weighted_threshold_sum += wadray::wmul_rw(yang_threshold, yang_deposited_value);
            }

            current_yang_id -= 1;
        };

        if value.is_non_zero() {
            return (wadray::wdiv_rw(weighted_threshold_sum, value), value);
        }

        (0_u128.into(), 0_u128.into())
    }

    fn get_yang_suspension_status_internal(yang_id: u32) -> YangSuspensionStatus {
        let suspension_ts: u64 = yang_suspension::read(yang_id);
        if suspension_ts.is_zero() {
            return YangSuspensionStatus::None(());
        }

        if get_block_timestamp() - suspension_ts < SUSPENSION_GRACE_PERIOD {
            return YangSuspensionStatus::Temporary(());
        }

        YangSuspensionStatus::Permanent(())
    }

    fn get_yang_threshold_internal(yang_id: u32) -> Ray {
        let base_threshold: Ray = thresholds::read(yang_id);

        match get_yang_suspension_status_internal(yang_id) {
            YangSuspensionStatus::None(_) => {
                base_threshold
            },
            YangSuspensionStatus::Temporary(_) => {
                // linearly decrease the threshold from base_threshold to 0
                // based on the time passed since suspension started
                let ts_diff: u64 = get_block_timestamp() - yang_suspension::read(yang_id);
                base_threshold
                    * ((SUSPENSION_GRACE_PERIOD - ts_diff).into() / SUSPENSION_GRACE_PERIOD.into())
            },
            YangSuspensionStatus::Permanent(_) => {
                RayZeroable::zero()
            },
        }
    }

    //
    // Internal ERC20 functions
    //

    fn transfer_internal(sender: ContractAddress, recipient: ContractAddress, amount: u256) {
        assert(recipient.is_non_zero(), 'SH: No transfer to 0 address');

        let amount_wad: Wad = Wad { val: amount.try_into().unwrap() };

        // Transferring the Yin
        yin::write(sender, yin::read(sender) - amount_wad);
        yin::write(recipient, yin::read(recipient) + amount_wad);

        Transfer(sender, recipient, amount);
    }

    fn approve_internal(owner: ContractAddress, spender: ContractAddress, amount: u256) {
        assert(spender.is_non_zero(), 'SH: No approval of 0 address');
        assert(owner.is_non_zero(), 'SH: No approval for 0 address');

        yin_allowances::write((owner, spender), amount);

        Approval(owner, spender, amount);
    }

    fn spend_allowance_internal(owner: ContractAddress, spender: ContractAddress, amount: u256) {
        let current_allowance: u256 = yin_allowances::read((owner, spender));

        // if current_allowance is not set to the maximum u256, then
        // subtract `amount` from spender's allowance.
        if current_allowance != BoundedU256::max() {
            approve_internal(owner, spender, current_allowance - amount);
        }
    }

    //
    // Public AccessControl functions
    //

    #[view]
    fn get_roles(account: ContractAddress) -> u128 {
        AccessControl::get_roles(account)
    }

    #[view]
    fn has_role(role: u128, account: ContractAddress) -> bool {
        AccessControl::has_role(role, account)
    }

    #[view]
    fn get_admin() -> ContractAddress {
        AccessControl::get_admin()
    }

    #[view]
    fn get_pending_admin() -> ContractAddress {
        AccessControl::get_pending_admin()
    }

    #[external]
    fn grant_role(role: u128, account: ContractAddress) {
        AccessControl::grant_role(role, account);
    }

    #[external]
    fn revoke_role(role: u128, account: ContractAddress) {
        AccessControl::revoke_role(role, account);
    }

    #[external]
    fn renounce_role(role: u128) {
        AccessControl::renounce_role(role);
    }

    #[external]
    fn set_pending_admin(new_admin: ContractAddress) {
        AccessControl::set_pending_admin(new_admin);
    }

    #[external]
    fn accept_admin() {
        AccessControl::accept_admin();
    }
}
