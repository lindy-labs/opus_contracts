#[contract]
mod Shrine {
    use array::ArrayTrait;
    use array::SpanTrait;
    use box::BoxTrait;
    use cmp::min;
    use integer::BoundedU128;
    use integer::BoundedU256;
    use integer::upcast;
    use option::OptionTrait;
    use starknet::ContractAddress;
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::BlockInfo;
    use starknet::get_caller_address;
    use traits::Into;
    use traits::TryInto;
    use zeroable::Zeroable;

    use aura::utils::storage_access_impls;
    use aura::utils::types::Trove;
    use aura::utils::types::YangRedistribution;
    use aura::utils::u256_conversions::U128IntoU256;
    use aura::utils::wadray;
    use aura::utils::wadray::Ray;
    use aura::utils::wadray::RAY_PERCENT;
    use aura::utils::wadray::RAY_ONE;
    use aura::utils::wadray::Wad;
    use aura::utils::wadray::WAD_ONE;
    use aura::utils::exp::exp;

    //
    // Constants
    //

    // Initial multiplier value to ensure `get_recent_multiplier_from` terminates - (ray): RAY_ONE
    const INITIAL_MULTIPLIER: u128 = 1000000000000000000000000000;
    const MAX_MULTIPLIER: u128 = 3000000000000000000000000000; // Max of 3x (ray): 3 * RAY_ONE

    const MAX_THRESHOLD: u128 = 1000000000000000000000000000; // (ray): RAY_ONE

    // Length of a time interval in seconds
    const TIME_INTERVAL: u64 = 1800; // 30 minutes * 60 seconds per minute
    const TIME_INTERVAL_DIV_YEAR: u128 =
        57077625570776; // 1 / (48 30-minute segments per day) / (365 days per year) = 0.000057077625 (wad)

    // Threshold for rounding remaining debt during redistribution (wad): 10**9
    const ROUNDING_THRESHOLD: u128 = 1000000000;

    // Maximum interest rate a yang can have (ray): RAY_ONE
    const MAX_YANG_RATE: u128 = 100000000000000000000000000;

    // Flag for setting the yang's new base rate to its previous base rate in `update_rates`
    // (ray): MAX_YANG_RATE + 1
    const USE_PREV_BASE_RATE: u128 = 100000000000000000000000001;

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
        // Maximum amount of debt that can exist at any given time
        debt_ceiling: Wad,
        // Global interest rate multiplier
        // stores both the actual multiplier, and the cumulative multiplier of
        // the yang at each time interval, both as Rays
        // (interval) -> (multiplier, cumulative_multiplier)
        multiplier: LegacyMap::<u64, (Ray, Ray)>,
        // Keeps track of the most recent rates index
        // Each index is associated with an update to the interest rates of all yangs.
        rates_latest_era: u64,
        // Keeps track of the interval at which the rate update at `era` was made.
        // (era) -> (interval)
        rates_intervals: LegacyMap::<u64, u64>,
        // Keeps track of the interest rate of each yang at each era
        // (yang_id, era) -> (Interest Rate)
        yang_rates: LegacyMap::<(u32, u64), Ray>,
        // Liquidation threshold per yang (as LTV) - Ray
        // (yang_id) -> (Liquidation Threshold)
        thresholds: LegacyMap::<u32, Ray>,
        // Keeps track of how many redistributions have occurred
        redistributions_count: u32,
        // Last redistribution accounted for a trove
        // (trove_id) -> (Last Redistribution ID)
        trove_redistribution_id: LegacyMap::<u64, u32>,
        // Mapping of yang ID and redistribution ID to
        // 1. amount of debt in Wad to be redistributed to each Wad unit of yang
        // 2. amount of debt to be added to the next redistribution to calculate (1)
        // (yang_id, redistribution_id) -> YangRedistribution{debt_per_wad, debt_to_add_to_next}
        yang_redistributions: LegacyMap::<(u32, u32), YangRedistribution>,
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
        yangs: Array<ContractAddress>,
        new_rates: Array<Ray>,
    ) {}

    #[event]
    fn ThresholdUpdated(yang: ContractAddress, threshold: Ray) {}

    #[event]
    fn TroveUpdated(trove_id: u64, trove: Trove) {}

    #[event]
    fn TroveRedistributed(redistribution_id: u32, trove_id: u64, debt: Wad) {}

    #[event]
    fn DepositUpdated(yang: ContractAddress, trove_id: u64, amount: Wad) {}

    #[event]
    fn YangPriceUpdated(yang: ContractAddress, price: Wad, cumulative_price: Wad, interval: u64) {}

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
        //AccessControl::initializer(admin);

        // Grant admin permission
        //AccessControl::_grant_role(ShrineRoles.DEFAULT_SHRINE_ADMIN_ROLE, admin);

        is_live::write(true);

        // Seeding initial multiplier to the previous interval to ensure `get_recent_multiplier_from` terminates
        // otherwise, the next multiplier update will run into an endless loop of `get_recent_multiplier_from`
        // since it wouldn't find the initial multiplier
        let prev_interval: u64 = now() - 1;
        let init_multiplier: Ray = INITIAL_MULTIPLIER.into();
        multiplier::write(prev_interval, (init_multiplier, init_multiplier));

        // Emit event
        MultiplierUpdated(init_multiplier, init_multiplier, prev_interval);

        // ERC20
        yin_name::write(name);
        yin_symbol::write(symbol);
        // TODO: replace with `WAD_DECIMALS` constant from wadray library
        yin_decimals::write(18);
    }

    //
    // Getters
    //

    // Returns a tuple of a trove's threshold, LTV based on compounded debt, trove value and compounded debt
    #[view]
    fn get_trove_info(trove_id: u64) -> (Ray, Ray, Wad, Wad) {
        let interval: u64 = now();

        // Get threshold and trove value
        let yang_count: u32 = yangs_count::read();
        let (threshold, value) = get_trove_threshold_and_value_internal(trove_id, interval);

        // Calculate debt
        let trove: Trove = troves::read(trove_id);

        // Catch troves with no value
        if value.is_zero() {
            if trove.debt.is_non_zero() {
                return (threshold, BoundedU128::max().into(), value, trove.debt);
            } else {
                return (threshold, 0_u128.into(), value, trove.debt);
            }
        }

        let debt: Wad = compound(trove_id, trove, interval, yang_count);
        let debt: Wad = pull_redistributed_debt(trove_id, debt, false);
        let ltv: Ray = wadray::rdiv_ww(debt, value);

        (threshold, ltv, value, debt)
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
    fn get_debt_ceiling() -> Wad {
        debt_ceiling::read()
    }

    #[view]
    fn get_multiplier(interval: u64) -> (Ray, Ray) {
        multiplier::read(interval)
    }

    #[view]
    fn get_yang_threshold(yang: ContractAddress) -> Ray {
        let yang_id: u32 = get_valid_yang_id(yang);
        thresholds::read(yang_id)
    }

    #[view]
    fn get_shrine_threshold_and_value() -> (Ray, Wad) {
        get_shrine_threshold_and_value_internal(now())
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
    fn get_redistributed_unit_debt_for_yang(yang: ContractAddress, redistribution_id: u32) -> Wad {
        let yang_id: u32 = get_valid_yang_id(yang);
        let redistribution: YangRedistribution = yang_redistributions::read(
            (yang_id, redistribution_id)
        );
        redistribution.unit_debt
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
        //AccessControl.assert_has_role(ShrineRoles.ADD_YANG);

        assert(yang_ids::read(yang) == 0, 'Yang already exists');

        assert_rate_is_valid(initial_rate);

        // Assign new ID to yang and add yang struct
        let yang_id: u32 = yangs_count::read() + 1;
        yang_ids::write(yang, yang_id);

        // Update yangs count
        yangs_count::write(yang_id);

        // Set threshold
        set_threshold(yang, threshold);

        // Update initial yang supply
        // Used upstream to prevent first depositor front running
        yang_total::write(yang_id, initial_yang_amt);

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
        // for this base rate will have an interval that, in practice, is < now(). This would be a problem
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
    fn set_ceiling(new_ceiling: Wad) {
        //AccessControl.assert_has_role(ShrineRoles.SET_CEILING);
        debt_ceiling::write(new_ceiling);

        //Event emission
        DebtCeilingUpdated(new_ceiling);
    }

    #[external]
    fn set_threshold(yang: ContractAddress, new_threshold: Ray) {
        //AccessControl.assert_has_role(ShrineRoles.SET_THRESHOLD);

        assert(new_threshold.val <= MAX_THRESHOLD, 'Threshold > max');
        thresholds::write(get_valid_yang_id(yang), new_threshold);

        // Event emission
        ThresholdUpdated(yang, new_threshold);
    }

    #[external]
    fn kill() {
        //AccessControl.assert_has_role(ShrineRoles.KILL);
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
        //AccessControl.assert_has_role(ShrineRoles.ADVANCE);

        assert(price.is_non_zero(), 'Cannot set a price to 0');

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
            + (last_price.val * upcast(interval - last_interval - 1)).into()
            + price;

        yang_prices::write((yang_id, interval), (price, new_cumulative));

        YangPriceUpdated(yang, price, new_cumulative, interval);
    }

    // Sets the multiplier for the current interval
    #[external]
    fn set_multiplier(new_multiplier: Ray) {
        //AccessControl.assert_has_role(ShrineRoles.SET_MULTIPLIER);

        // TODO: Should this be here? Maybe multiplier should be able to go to zero
        assert(new_multiplier.is_non_zero(), 'Cannot set multiplier to zero');
        assert(new_multiplier.val <= MAX_MULTIPLIER, 'multiplier exceeds maximum');

        let interval: u64 = now();
        let (last_multiplier, last_cumulative_multiplier, last_interval) =
            get_recent_multiplier_from(
            interval - 1
        );

        let new_cumulative_multiplier = last_cumulative_multiplier
            + (upcast(interval - last_interval - 1) * last_multiplier.val).into()
            + new_multiplier;
        multiplier::write(interval, (new_multiplier, new_cumulative_multiplier));

        MultiplierUpdated(new_multiplier, new_cumulative_multiplier, interval);
    }


    // Update the base rates of all yangs
    // A base rate of USE_PREV_BASE_RATE means the base rate for the yang stays the same
    // Takes an array of yangs and their updated rates.
    // yangs[i]'s base rate will be set to new_rates[i]
    // yangs's length must equal the number of yangs available.
    #[external]
    fn update_rates(yangs: Array<ContractAddress>, new_rates: Array<Ray>) {
        //AccessControl.assert_has_role(ShrineRoles.UPDATE_RATES);

        let mut yangs_span: Span<ContractAddress> = yangs.span();
        let mut new_rates_span: Span<Ray> = new_rates.span();

        let yangs_len = yangs_span.len();
        let num_yangs: u32 = yangs_count::read();

        assert(
            yangs_len == new_rates_span.len() & yangs_len == num_yangs,
            'yangs.len() != new_rates.len()'
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
        loop {
            match (new_rates_span.pop_front()) {
                Option::Some(rate) => {
                    let current_yang_id: u32 = get_valid_yang_id(*yangs_span.pop_front().unwrap());
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
                    break ();
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
        let mut idx: u32 = 0;
        loop {
            if idx == num_yangs {
                break ();
            }
            assert(yang_rates::read((idx, new_era)).is_non_zero(), 'Incorrect rate update');
            idx += 1;
        };

        YangRatesUpdated(new_era, current_interval, yangs, new_rates);
    }

    // Deposit a specified amount of a Yang into a Trove
    #[external]
    fn deposit(yang: ContractAddress, trove_id: u64, amount: Wad) {
        //AccessControl.assert_has_role(ShrineRoles.DEPOSIT);

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
        //AccessControl.assert_has_role(ShrineRoles.WITHDRAW);
        withdraw_internal(yang, trove_id, amount);
        assert_healthy(trove_id);
    }

    // Mint a specified amount of synthetic and attribute the debt to a Trove
    #[external]
    fn forge(user: ContractAddress, trove_id: u64, amount: Wad) {
        //AccessControl.assert_has_role(ShrineRoles.FORGE);
        assert_live();

        charge(trove_id);

        let new_system_debt = total_debt::read() + amount;
        assert(new_system_debt <= debt_ceiling::read(), 'Debt ceiling reached');
        total_debt::write(new_system_debt);

        // `Trove.charge_from` and `Trove.last_rate_era` were already updated in `charge`. 
        let old_trove_info: Trove = troves::read(trove_id);
        let new_trove_info = Trove {
            charge_from: old_trove_info.charge_from,
            debt: old_trove_info.debt + amount,
            last_rate_era: old_trove_info.last_rate_era
        };
        troves::write(trove_id, new_trove_info);

        assert_healthy(trove_id);

        forge_internal(user, amount);

        // Events
        DebtTotalUpdated(new_system_debt);
        TroveUpdated(trove_id, new_trove_info);
    }

    // Repay a specified amount of synthetic and deattribute the debt from a Trove
    #[external]
    fn melt(user: ContractAddress, trove_id: u64, amount: Wad) {
        //AccessControl.assert_has_role(ShrineRoles.MELT);

        // Charge interest
        charge(trove_id);

        let old_trove_info: Trove = troves::read(trove_id);

        // If `amount` exceeds `old_trove_info.debt`, then melt all the debt. 
        // This is nice for UX so that maximum debt can be melted without knowing the exact 
        // of debt in the trove down to the 10**-18. 
        let melt_amt: Wad = min(old_trove_info.debt, amount);
        let new_system_debt: Wad = total_debt::read() - melt_amt;
        total_debt::write(new_system_debt);

        // `charge_from` and `last_rate_era` are already updated in `charge`
        let new_trove_info: Trove = Trove {
            charge_from: old_trove_info.charge_from,
            debt: old_trove_info.debt - melt_amt,
            last_rate_era: old_trove_info.last_rate_era
        };
        troves::write(trove_id, new_trove_info);

        // Update user balance
        melt_internal(user, melt_amt);

        // Events
        DebtTotalUpdated(new_system_debt);
        TroveUpdated(trove_id, new_trove_info);
    }

    // Withdraw a specified amount of a Yang from a Trove without trove safety check.
    // This is intended for liquidations where collateral needs to be withdrawn and transferred to the liquidator
    // even if the trove is still unsafe.
    #[external]
    fn seize(yang: ContractAddress, trove_id: u64, amount: Wad) {
        //AccessControl.assert_has_role(ShrineRoles.SEIZE);
        withdraw_internal(yang, trove_id, amount);
    }

    #[external]
    fn redistribute(trove_id: u64) {
        //AccessControl.assert_has_role(ShrineRoles.REDISTRIBUTE);

        let current_interval: u64 = now();
        let (_, trove_value) = get_trove_threshold_and_value_internal(trove_id, current_interval);

        // Trove's debt should have been updated to the current interval via `melt` in `Purger.purge`.
        // The trove's debt is used instead of estimated debt from `get_trove_info` to ensure that
        // system has accounted for the accrued interest.
        let trove: Trove = troves::read(trove_id);

        // Increment redistribution ID
        let redistribution_id: u32 = redistributions_count::read() + 1;
        redistributions_count::write(redistribution_id);

        //Perform redistribution
        let redistributed_debt = redistribute_internal(
            redistribution_id, trove_id, trove_value, trove.debt, current_interval
        );

        let updated_trove = Trove {
            charge_from: current_interval, debt: 0_u128.into(), last_rate_era: trove.last_rate_era
        };
        troves::write(trove_id, updated_trove);

        // Event 
        TroveRedistributed(redistribution_id, trove_id, redistributed_debt);
    }

    // Mint a specified amount of synthetic without attributing the debt to a Trove
    #[external]
    fn inject(receiver: ContractAddress, amount: Wad) {
        //AccessControl.assert_has_role(ShrineRoles.INJECT);
        forge_internal(receiver, amount);
    }

    // Repay a specified amount of synthetic without deattributing the debt from a Trove
    #[external]
    fn eject(burner: ContractAddress, amount: Wad) {
        //AccessControl.assert_has_role(ShrineRoles.EJECT);
        melt_internal(burner, amount);
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


    // Returns a bool indicating whether the given trove is healthy or not
    #[view]
    fn is_healthy(trove_id: u64) -> bool {
        let (threshold, ltv, _, _) = get_trove_info(trove_id);
        ltv <= threshold
    }

    #[view]
    fn get_max_forge(trove_id: u64) -> Wad {
        let (threshold, _, value, debt) = get_trove_info(trove_id);

        let max_debt: Wad = wadray::rmul_rw(threshold, value);

        if debt < max_debt {
            return max_debt - debt;
        }

        0_u128.into()
    }

    //
    // Internal
    //

    // Check that system is live
    fn assert_live() {
        assert(is_live::read(), 'System is not live');
    }

    // Helper function to get the yang ID given a yang address, and throw an error if
    // yang address has not been added (i.e. yang ID = 0)
    fn get_valid_yang_id(yang: ContractAddress) -> u32 {
        let yang_id: u32 = yang_ids::read(yang);
        assert(yang_id != 0, 'Yang does not exist');
        yang_id
    }

    #[inline(always)]
    fn now() -> u64 {
        starknet::get_block_timestamp() / TIME_INTERVAL
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
        assert(0 < rate.val & rate.val <= MAX_YANG_RATE, 'Rate out of bounds');
    }

    // Adds the accumulated interest as debt to the trove
    fn charge(trove_id: u64) {
        let trove: Trove = troves::read(trove_id);

        // Get current interval and yang count
        let current_interval: u64 = now();
        let yang_count: u32 = yangs_count::read();

        // Get new debt amount
        let compounded_trove_debt: Wad = compound(trove_id, trove, current_interval, yang_count);

        // Pull undistributed debt and update state
        let new_trove_debt: Wad = pull_redistributed_debt(trove_id, compounded_trove_debt, true);

        // Update trove
        let updated_trove: Trove = Trove {
            charge_from: current_interval,
            debt: new_trove_debt,
            last_rate_era: rates_latest_era::read()
        };
        troves::write(trove_id, updated_trove);

        // Get new system debt
        // This adds the interest charged on the trove's debt to the total debt.
        // This should not include redistributed debt, as that is already included in the total.
        let new_system_debt: Wad = total_debt::read() + (compounded_trove_debt - trove.debt);
        total_debt::write(new_system_debt);

        // Don't emit events if there hasn't been a change in debt
        if compounded_trove_debt != trove.debt {
            DebtTotalUpdated(new_system_debt);
            TroveUpdated(trove_id, updated_trove);
        }
    }


    // Returns the amount of debt owed by trove after having interest charged over a given time period
    // Assumes the trove hasn't minted or paid back any additional debt during the given time period
    // Assumes the trove hasn't deposited or withdrawn any additional collateral during the given time period
    // Time period includes `end_interval` and does NOT include `start_interval`.

    // Compound interest formula: P(t) = P_0 * e^(rt)
    // P_0 = principal
    // r = nominal interest rate (what the interest rate would be if there was no compounding
    // t = time elapsed, in years
    fn compound(trove_id: u64, trove: Trove, end_interval: u64, num_yangs: u32) -> Wad {
        // Saves gas and prevents bugs for troves with no yangs deposited
        // Implicit assumption is that a trove with non-zero debt must have non-zero yangs
        if trove.debt.is_zero() {
            return 0_u128.into();
        }

        let latest_rate_era: u64 = rates_latest_era::read();
        let num_yangs: u32 = yangs_count::read();

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
                    val: upcast(end_interval - start_interval) * TIME_INTERVAL_DIV_YEAR
                };
                compounded_debt *= exp(wadray::rmul_rw(avg_rate, t));
                break compounded_debt;
            }

            let next_rate_update_era = trove_last_rate_era + 1;
            let next_rate_update_era_interval = rates_intervals::read(next_rate_update_era);

            let avg_base_rate: Ray = get_avg_rate_over_era(
                trove_id, start_interval, next_rate_update_era_interval, latest_rate_era
            );
            let avg_rate: Ray = avg_base_rate
                * get_avg_multiplier(start_interval, next_rate_update_era_interval);

            let t: Wad = Wad {
                val: upcast((next_rate_update_era_interval - start_interval))
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
                // However, `cum_yang_value` cannot be zero because a trove with no yangs deposited
                // cannot have any debt, meaning this code would never run (see `compound`)
                break wadray::wdiv_rw(cumulative_weighted_sum, cumulative_yang_value);
            }

            // Skip over this yang if it hasn't been deposited in the trove
            let yang_deposited: Wad = deposits::read((current_yang_id, trove_id));
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
    // 1. set the deposit to 0
    // 2. calculate the redistributed debt for that yang and fixed point division error, and write to storage
    //
    // Returns the total amount of debt redistributed.
    fn redistribute_internal(
        redistribution_id: u32,
        trove_id: u64,
        trove_value: Wad,
        trove_debt: Wad,
        current_interval: u64
    ) -> Wad {
        let mut current_yang_id: u32 = yangs_count::read();
        let mut redistributed_debt: Wad = 0_u128.into();

        loop {
            if current_yang_id == 0 {
                break redistributed_debt;
            }

            // Skip over this yang if it hasn't been deposited in the trove
            let deposited: Wad = deposits::read((current_yang_id, trove_id));
            if deposited.is_non_zero() {
                deposits::write((current_yang_id, trove_id), 0_u128.into());

                // Decrementing the system's yang balance by the amount deposited in the trove has the effect of
                // rebasing (i.e. appreciating) the ratio of asset to yang for the remaining troves.
                // By removing the distributed yangs from the system, it distributes the assets between
                // the remaining yangs.
                let new_yang_total: Wad = yang_total::read(current_yang_id) - deposited;
                yang_total::write(current_yang_id, new_yang_total);

                // Calculate (value of yang / trove value) * debt and assign redistributed debt to yang
                let (yang_price, _, _) = get_recent_price_from(current_yang_id, current_interval);
                let raw_debt_to_distribute = ((deposited * yang_price) / trove_value) * trove_debt;

                let (debt_to_distribute, updated_redistributed_debt) = round_distributed_debt(
                    trove_debt, raw_debt_to_distribute, redistributed_debt
                );
                redistributed_debt = updated_redistributed_debt;

                // Adjust debt to distribute by adding the error from the last redistribution
                let last_error: Wad = get_recent_redistribution_error_for_yang(
                    current_yang_id, redistribution_id - 1
                );

                let adjusted_debt_to_distribute: Wad = debt_to_distribute + last_error;

                let unit_debt: Wad = adjusted_debt_to_distribute / new_yang_total;

                // Due to loss of precision from fixed point division, the actual debt distributed will be less than
                // or equal to the amount of debt to distribute.
                let actual_debt_distributed: Wad = unit_debt * new_yang_total;
                let new_error: Wad = adjusted_debt_to_distribute - actual_debt_distributed;
                let current_yang_redistribution = YangRedistribution {
                    unit_debt: unit_debt, error: new_error
                };

                yang_redistributions::write(
                    (current_yang_id, redistribution_id), current_yang_redistribution
                );

                // Continue iteration if there is no dust
                // Otherwise, if debt is rounded up and fully redistributed, skip the remaining yangs
                if debt_to_distribute != raw_debt_to_distribute {
                    break redistributed_debt;
                }
            }

            current_yang_id -= 1;
        }
    }

    // Returns the last error for `yang_id` at a given `redistribution_id` if the packed value is non-zero.
    // Otherwise, check `redistribution_id` - 1 recursively for the last error.
    fn get_recent_redistribution_error_for_yang(yang_id: u32, redistribution_id: u32) -> Wad {
        if redistribution_id == 0 {
            return 0_u128.into();
        }

        let error: Wad = yang_redistributions::read((yang_id, redistribution_id)).error;

        if error.is_non_zero() {
            return error;
        }

        get_recent_redistribution_error_for_yang(yang_id, redistribution_id - 1)
    }


    // Helper function to round up the debt to be redistributed for a yang if the remaining debt
    // falls below the defined threshold, so as to avoid rounding errors and ensure that the amount
    // of debt redistributed is equal to the trove's debt
    fn round_distributed_debt(
        total_debt_to_distribute: Wad,
        remaining_debt_to_distribute: Wad,
        cumulative_redistributed_debt: Wad
    ) -> (Wad, Wad) {
        let updated_cumulative_redistributed_debt = remaining_debt_to_distribute
            + cumulative_redistributed_debt;
        let remaining_debt: Wad = total_debt_to_distribute - updated_cumulative_redistributed_debt;

        if remaining_debt.val <= ROUNDING_THRESHOLD {
            return (
                remaining_debt_to_distribute + remaining_debt,
                updated_cumulative_redistributed_debt + remaining_debt
            );
        }

        (remaining_debt_to_distribute, updated_cumulative_redistributed_debt)
    }

    // Takes in a value for the trove's debt, and returns the updated value after adding
    // the redistributed debt, if any.
    // Takes in a boolean flag to determine whether the redistribution ID for the trove should be updated.
    // Any state update of the trove's debt should be performed in the caller function.
    fn pull_redistributed_debt(
        trove_id: u64, mut trove_debt: Wad, update_redistribution_id: bool
    ) -> Wad {
        let current_redistribution_id: u32 = redistributions_count::read();
        let trove_last_redistribution_id: u32 = trove_redistribution_id::read(trove_id);

        // Early termination if no redistributions since trove was last updated
        if current_redistribution_id == trove_last_redistribution_id {
            return trove_debt;
        }

        // Outer loop iterating over the trove's yangs
        let mut current_yang_id: u32 = yangs_count::read();
        loop {
            if current_yang_id == 0 {
                break ();
            }

            let deposited: Wad = deposits::read((current_yang_id, trove_id));
            if deposited.is_non_zero() {
                // Inner loop iterating over the redistribution IDs for each of the trove's yangs
                let mut current_redistribution_id_temp = current_redistribution_id;
                let mut debt_increment: Wad = 0_u128.into();
                loop {
                    if trove_last_redistribution_id == current_redistribution_id_temp {
                        break ();
                    }

                    // Get the amount of debt per yang for the current redistribution
                    let unit_debt: Wad = yang_redistributions::read(
                        (current_yang_id, current_redistribution_id)
                    ).unit_debt;

                    if unit_debt.is_non_zero() {
                        debt_increment += unit_debt * deposited;
                    }
                    current_redistribution_id_temp -= 1;
                };
                trove_debt += debt_increment;
            }
            current_yang_id -= 1;
        };

        if update_redistribution_id {
            trove_redistribution_id::write(trove_id, current_redistribution_id);
        }

        trove_debt
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
            return (cumulative_diff.val / upcast(end_interval - start_interval)).into();
        }

        // If the start interval is not updated, adjust the cumulative difference (see `advance`) by deducting
        // (number of intervals missed from `available_start_interval` to `start_interval` * start price).
        if start_interval != available_start_interval {
            let cumulative_offset = Wad {
                val: upcast(start_interval - available_start_interval) * start_yang_price.val
            };
            cumulative_diff -= cumulative_offset;
        }

        // If the end interval is not updated, adjust the cumulative difference by adding
        // (number of intervals missed from `available_end_interval` to `end_interval` * end price).
        if (end_interval != available_end_interval) {
            let cumulative_offset = Wad {
                val: upcast(end_interval - available_end_interval) * end_yang_price.val
            };
            cumulative_diff += cumulative_offset;
        }

        (cumulative_diff.val / upcast(end_interval - start_interval)).into()
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
            return (cumulative_diff.val / upcast(end_interval - start_interval)).into();
        }

        // If the start interval is not updated, adjust the cumulative difference (see `advance`) by deducting
        // (number of intervals missed from `available_start_interval` to `start_interval` * start price).
        if start_interval != available_start_interval {
            let cumulative_offset = Ray {
                val: upcast(start_interval - available_start_interval) * start_multiplier.val
            };
            cumulative_diff -= cumulative_offset;
        }

        // If the end interval is not updated, adjust the cumulative difference by adding
        // (number of intervals missed from `available_end_interval` to `end_interval` * end price).
        if (end_interval != available_end_interval) {
            let cumulative_offset = Ray {
                val: upcast(end_interval - available_end_interval) * end_multiplier.val
            };
            cumulative_diff += cumulative_offset;
        }

        (cumulative_diff.val / upcast(end_interval - start_interval)).into()
    }

    //
    // Trove health internal functions
    //

    fn assert_healthy(trove_id: u64) {
        assert(is_healthy(trove_id), 'Trove LTV is too high');
    }

    // Returns a tuple of the custom threshold (maximum LTV before liquidation) of a trove and the total trove value, at a given interval.
    // This function uses historical prices but the currently deposited yang amounts to calculate value.
    // The underlying assumption is that the amount of each yang deposited at `interval` is the same as the amount currently deposited.
    fn get_trove_threshold_and_value_internal(trove_id: u64, interval: u64) -> (Ray, Wad) {
        let mut current_yang_id: u32 = yangs_count::read();
        let mut weighted_threshold: Ray = 0_u128.into();
        let mut trove_value: Wad = 0_u128.into();

        loop {
            if current_yang_id == 0 {
                break ();
            }

            let deposited: Wad = deposits::read((current_yang_id, trove_id));

            // Skip over current yang if user hasn't deposited anything
            if deposited.is_non_zero() {
                let yang_threshold: Ray = thresholds::read(current_yang_id);

                let (price, _, _) = get_recent_price_from(current_yang_id, interval);

                let yang_deposited_value = deposited * price;
                trove_value += yang_deposited_value;
                weighted_threshold += wadray::wmul_rw(yang_threshold, yang_deposited_value);
            }

            current_yang_id -= 1;
        };

        if trove_value.is_non_zero() {
            return (wadray::wdiv_rw(weighted_threshold, trove_value), trove_value);
        }

        (0_u128.into(), 0_u128.into())
    }


    // Returns a tuple of the threshold and value of all troves combined.
    // This function uses historical prices but the total amount of currently deposited yangs across
    // all troves to calculate the total value of all troves.
    fn get_shrine_threshold_and_value_internal(current_interval: u64) -> (Ray, Wad) {
        let mut current_yang_id: u32 = yangs_count::read();
        let mut weighted_threshold: Ray = 0_u128.into();
        let mut value: Wad = 0_u128.into();

        loop {
            if current_yang_id == 0 {
                break ();
            }

            let deposited: Wad = yang_total::read(current_yang_id);

            // Skip over current yang if none has  been deposited
            if deposited.is_non_zero() {
                let yang_threshold: Ray = thresholds::read(current_yang_id);

                let (price, _, _) = get_recent_price_from(current_yang_id, current_interval);

                let yang_deposited_value = deposited * price;
                value += yang_deposited_value;
                weighted_threshold += wadray::wmul_rw(yang_threshold, yang_deposited_value);
            }

            current_yang_id -= 1;
        };

        if value.is_non_zero() {
            return (wadray::wdiv_rw(weighted_threshold, value), value);
        }

        (0_u128.into(), 0_u128.into())
    }


    //
    // Internal ERC20 functions
    //

    fn transfer_internal(sender: ContractAddress, recipient: ContractAddress, amount: u256) {
        assert(recipient.is_non_zero(), 'cannot transfer to 0 address');

        let amount_wad: Wad = amount.try_into().unwrap().into();

        // Transferring the Yin
        yin::write(sender, yin::read(sender) - amount_wad);
        yin::write(sender, yin::read(sender) + amount_wad);

        Transfer(sender, recipient, amount);
    }

    fn approve_internal(owner: ContractAddress, spender: ContractAddress, amount: u256) {
        assert(spender.is_non_zero(), 'cannot approve 0 address');
        assert(owner.is_non_zero(), 'cannot approve for 0 address');

        yin_allowances::write((owner, spender), amount);

        Approval(owner, spender, amount);
    }

    fn spend_allowance_internal(owner: ContractAddress, spender: ContractAddress, amount: u256) {
        let mut current_allowance: u256 = yin_allowances::read((owner, spender));

        // if current_allowance is not set to the maximum u256, then 
        // subtract `amount` from spender's allowance.
        if current_allowance != BoundedU256::max() {
            current_allowance -= amount;
            approve_internal(owner, spender, current_allowance);
        }
    }
}
