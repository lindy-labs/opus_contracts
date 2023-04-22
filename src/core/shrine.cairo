#[contract]
mod Shrine {
    use box::BoxTrait;
    use option::OptionTrait;
    use starknet::ContractAddress;
    use starknet::BlockInfo;
    use traits::Into;
    use traits::TryInto;

    use aura::utils::storage_access_impls::RayTupleStorageAccess;
    use aura::utils::storage_access_impls::U128TupleStorageAccess;
    use aura::utils::storage_access_impls::WadTupleStorageAccess;
    use aura::utils::storage_access_impls::YangRedistributionStorageAccess;
    use aura::utils::types::Trove;
    use aura::utils::types::YangRedistribution;
    use aura::utils::wadray;
    use aura::utils::wadray::Ray;
    use aura::utils::wadray::RAY_PERCENT;
    use aura::utils::wadray::RAY_ONE;
    use aura::utils::wadray::Wad;
    use aura::utils::wadray::WAD_ONE;

    //
    // Constants
    //

    // Initial multiplier value to ensure `get_recent_multiplier_from` terminates
    const INITIAL_MULTIPLIER: u128 = 1000000000000000000000000000;

    const MAX_THRESHOLD: u128 = 1000000000000000000000000000;

    const TIME_INTERVAL: u128 = 1800; // 30 minutes * 60 seconds per minute
    const TIME_INTERVAL_DIV_YEAR: u128 =
        57077625570776; // 1 / (48 30-minute segments per day) / (365 days per year) = 0.000057077625 (wad)

    // Threshold for rounding remaining debt during redistribution
    const ROUNDING_THRESHOLD: u128 = 1000000000;

    // Maximum interest rate a yang can have (ray)
    const MAX_YANG_RATE: u128 = 100000000000000000000000000;

    // Flag for setting the yang's new base rate to its previous base rate in `update_rates`
    const USE_PREV_BASE_RATE: u128 = 100000000000000000000000001;

    // Coressponds to '11111...' in binary
    const ALL_ONES: u128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    struct Storage {
        // A trove can forge debt up to its threshold depending on the yangs deposited.
        troves: LegacyMap::<u64, Trove>,
        // Stores the amount of the "yin" (synthetic) each user owns.
        // yin can be exchanged for ERC20 synthetic tokens via the yin gate.
        yin: LegacyMap::<ContractAddress, Wad>,
        // Stores information about the total supply for each yang
        yang_total: LegacyMap::<u64, Wad>,
        // Number of collateral accepted by the system.
        // The return value is also the ID of the last added collateral.
        yangs_count: u64,
        // Mapping from yang ContractAddress to yang ID.
        // Yang ID starts at 1.
        yang_id: LegacyMap::<ContractAddress, u64>,
        // Keeps track of how much of each yang has been deposited into each Trove - Wad
        deposits: LegacyMap::<(u64, u64), Wad>,
        // Total amount of debt accrued
        total_debt: Wad,
        // Total amount of synthetic forged
        total_yin: Wad,
        // Keeps track of the price history of each Yang 
        // interval: timestamp divided by TIME_INTERVAL.
        // Stores both the actual price and the cumulative price of
        // the yang at each time interval, both as Wads
        // (yang_id, interval) -> (price, cumulative_price)
        yang_price: LegacyMap::<(u64, u64), (Wad, Wad)>,
        // Total debt ceiling - Wad
        ceiling: Wad,
        // Global interest rate multiplier
        // stores both the actual multiplier, and the cumulative multiplier of
        // the yang at each time interval, both as Rays
        // (yang_id, interval) -> (multiplier, cumulative_multiplier)
        multiplier: LegacyMap::<u64, (Ray, Ray)>,
        // Keeps track of the most recent rates index
        // Each index is associated with an update to the interest rates of all yangs.
        rates_latest_era: u64,
        // Keeps track of the interval at which the rate update at `idx` was made.
        // (idx) -> (interval)
        rates_intervals: LegacyMap::<u64, u64>,
        // Keeps track of the interest rate of each yang at each index
        yang_rates: LegacyMap::<(u64, u64), Ray>,
        // Liquidation threshold per yang (as LTV) - Ray
        thresholds: LegacyMap::<u64, Ray>,
        // Keeps track of how many redistributions have occurred
        redistributions_count: u64,
        // Last redistribution accounted for a trove
        trove_redistribution_id: LegacyMap::<u64, u64>,
        // Mapping of yang ID and redistribution ID to
        // 1. amount of debt in Wad to be redistributed to each Wad unit of yang
        // 2. amount of debt to be added to the next redistribution to calculate (1)
        // (yang_id, redistribution_id) -> (debt_per_wad, debt_to_add_to_next)
        yang_redistribution: LegacyMap::<(u64, u64), YangRedistribution>,
        // Keeps track of whether shrine is live or killed
        is_live: bool,
        // Yin storage
        yin_name: felt252,
        yin_symbol: felt252,
        yin_decimals: u64,
        yin_allowances: LegacyMap::<(ContractAddress, ContractAddress), u256>,
    }


    //
    // Events
    //

    #[event]
    fn YangAdded(yang: ContractAddress, yang_id: u64, start_price: Wad, initial_rate: Ray) {}

    #[event]
    fn YangTotalUpdated(yang: ContractAddress, total: Wad) {}

    #[event]
    fn DebtTotalUpdated(total: Wad) {}

    #[event]
    fn YangsCountUpdated(count: u64) {}

    #[event]
    fn MultiplierUpdated(multiplier: Ray, cumulative_multiplier: Ray, interval: u64) {}

    #[event]
    fn YangRatesUpdated(
        new_rate_idx: u64,
        current_interval: u64,
        yangs_len: u64, //yangs: ContractAddress*,
        new_rates_len: u64,
    //new_rates: Ray*,
    ) {}

    #[event]
    fn ThresholdUpdated(yang: ContractAddress, threshold: Ray) {}

    #[event]
    fn TroveUpdated(trove_id: u64, trove: Trove) {}

    #[event]
    fn TroveRedistributed(redistribution_id: u64, trove_id: u64, debt: Wad) {}

    #[event]
    fn DepositUpdated(yang: ContractAddress, trove_id: u64, amount: Wad) {}

    #[event]
    fn YangPriceUpdated(yang: ContractAddress, price: Wad, cumulative_price: Wad, interval: u64) {}

    #[event]
    fn CeilingUpdated(ceiling: Wad) {}

    #[event]
    fn Killed() {}

    // ERC20 events
    #[event]
    fn Transfer(from_: ContractAddress, to: ContractAddress, value: u256) {}

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

        // Set initial multiplier value
        let prev_interval: u64 = now() - 1;
        let init_multiplier = Ray { val: INITIAL_MULTIPLIER };
        multiplier::write(prev_interval, (init_multiplier, init_multiplier));

        // Emit event
        MultiplierUpdated(init_multiplier, init_multiplier, prev_interval);

        // ERC20
        yin_name::write(name);
        yin_symbol::write(symbol);
        yin_decimals::write(18);
    }

    //
    // Getters
    //
    #[view]
    fn get_trove_info(trove_id: u64) -> (Ray, Ray, Wad, Wad) {
        let interval: u64 = now();

        // Get threshold and trove value
        let yang_count: u64 = yangs_count::read();
        //let (threshold: Ray, value: Wad) = get_trove_threshold_and_value_internal(trove_id, interval, yang_count, 0, 0);

        // Calculate debt
        let trove: Trove = troves::read(trove_id);

        // Catch troves with no value
        if value == 0 & trove.debt != 0 {
            (threshold, wadray::U128_MAX, value, trove.debt)
        } else {
            (threshold, 0, value, trove.debt)
        }

        let mut debt: Wad = compound(trove_id, trove, interval, yang_count);
        debt = pull_redistributed_debt(trove_id, debt, false);
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
        let yang_id: u64 = yang_id::read(yang);
        yang_total::read(yang_id)
    }

    #[view]
    fn get_yangs_count() -> u64 {
        yangs_count::read()
    }

    #[view]
    fn get_deposit(yang: ContractAddress, trove_id: u64) -> Wad {
        let yang_id: u64 = yang_id::read(yang);
        deposits::read(yang_id, trove_id)
    }

    #[view]
    fn get_total_debt() -> Wad {
        total_debt::read()
    }

    #[view]
    fn get_yang_price(yang: ContractAddress, interval: u64) -> (Wad, Wad) {
        let yang_id: u64 = yang_id::read(yang);
        (price, cumulative_price)
    }

    #[view]
    fn get_yang_rate(yang: ContractAddress, idx: u64) -> Ray {
        let yang_id: u64 = yang_id::read(yang);
        yang_rates::read(yang_id, idx)
    }

    #[view]
    fn get_ceiling() -> Wad {
        ceiling::read()
    }

    #[view]
    fn get_multiplier(interval: u64) -> (Ray, Ray) {
        let mul_and_cumulative_mul: packed = multiplier::read(interval);
        //let (multiplier: Ray, cumulative_multiplier: Ray) = unpack_125(mul_and_cumulative_mul);
        (multiplier, cumulative_multiplier)
    }

    #[view]
    fn get_yang_threshold(yang: ContractAddress) -> Ray {
        let yang_id: u64 = get_valid_yang_id(yang);
        thresholds::read(yang_id)
    }

    #[view]
    fn get_threshold_and_value() -> (Ray, Wad) {
        let current_interval: u64 = now();
        let yang_count: u64 = yangs_count::read();
        //let (threshold: Ray, value: Wad) = get_threshold_and_value_internal(current_interval, yang_count, 0, 0);
        (threshold, value)
    }

    #[view]
    fn get_redistributions_count() -> u64 {
        redistributions_count::read()
    }

    #[view]
    fn get_trove_redistribution_id(trove_id: u64) -> u64 {
        trove_redistribution_id::read(trove_id)
    }

    #[view]
    fn get_redistributed_unit_debt_for_yang(yang: ContractAddress, redistribution_id: u64) -> Wad {
        let yang_id: u64 = get_valid_yang_id(yang);
        let redistribution: YangRedistribution = get_yang_redistribution(
            yang_id, redistribution_id
        );
        redistribution.unit_debt
    }

    #[view]
    fn get_live() -> bool {
        is_live::read()
    }


    //
    // Internal
    //

    // Check that system is live
    fn assert_live() {
        assert(shrine_live::read(), 'Shrine: System is not live');
    }

    // Helper function to get the yang ID given a yang address, and throw an error if
    // yang address has not been added (i.e. yang ID = 0)
    fn get_valid_yang_id(yang: ContractAddress) -> u64 {
        let yang_id: u64 = shrine_yang_id::read(yang);
        assert(yang_id != 0, 'Shrine: Yang does not exist');
        yang_id
    }

    fn get_yang_redistribution(yang_id: u64, redistribution_id: u64) -> YangRedistribution {
        yang_redistribution::read((yang_id, redistribution_id))
    }

    fn set_yang_redistribution(
        yang_id: u64, redistribution_id: u64, redistribution: YangRedistribution
    ) {
        yang_redistribution::write((yang_id, redistribution_id), redistribution);
    }

    fn now() -> u64 {
        let time: u64 = starknet::get_block_info().unbox().block_timestamp;
        time / TIME_INTERVAL.try_into().unwrap()
    }

    fn forge_internal(user: ContractAddress, amount: Wad) {
        yin::write(user, yin::read(user) + amount)
        total_yin::write(total_yin::read() + amount);

        Transfer(0, user, amount.val.into());
    }

    fn melt_internal(user: ContractAddress, amount: Wad) {
        yin::write(user, yin::read(user) - amount)
        total_yin::write(total_yin::read() - amount);

        Transfer(user, 0, amount.val.into());
    }

    // Withdraw a specified amount of a Yang from a Trove
    fn withdraw_internal(yang: ContractAddress, trove_id: u64, amount: Wad) {
        let yang_id: u64 = get_valid_yang_id(yang);
        let mut total_yang: Wad = yang_total::read(yang_id) - amount;

        // Ensure trove has sufficient yang
        let mut trove_yang_balance: Wad = deposits::read(yang_id, trove_id);
        trove_yang_balance -= amount;

        //Charge interest
        charge(trove_id);

        // Update yang balance of system
        total_yang -= amount;
        yang_total::write(yang_id, total_yang);

        // Update yang balance of trove
        deposits::write((yang_id, trove_id), trove_yang_balance);

        // Emit events
        YangTotalUpdated(yang, total_yang);
        DepositUpdated(yang, trove_id, trove_yang_balance);
    }

    // Internal function for looping over all yangs and updating their base rates
    // ALL yangs must have a new rate value. A new rate value of `USE_PREV_BASE_RATE` means the
    // yang's rate isn't being updated, and so we get the previous value.
    //fn update_rates_loop(new_idx: u64, num_yangs: u64, yangs: new_rates:)

    //
    // Internal ERC20 functions
    //
    fn _transfer(sender: ContractAddress, recipient: ContractAddress, amount: u256) {
        assert(recipient != 0, 'Shrine: cannot transfer to the zero address');

        let amount: Wad = Wad { val: amount.try_into().unwrap() };

        // Transferring the Yin
        yin::write(sender, yin::read(sender) - amount);
        yin::write(sender, yin::read(sender) + amount);

        Transfer(sender, recipient, amount);
    }

    fn _approve(owner: ContractAddress, spender: ContractAddress, amount: u256) {
        assert(spender != 0, 'Shrine: cannot approve the zero address');
        assert(owner != 0, 'Shrine: cannot approve for the zero address');

        yin_allowances::write((owner, spender), amount);

        Approval(owner, spender, amount);
    }

    fn _spend_allowance(owner: ContractAddress, spender: ContractAddress, amount: u256) {
        let mut current_allowance: u256 = yin_allowances::read((owner, spender));

        // if current_allowance is not set to the maximum u256, then 
        // subtract `amount` from spender's allowance.
        if current_allowance.low != ALL_ONES | current_allowance.high != ALL_ONES {
            current_allowance -= amount;
            _approve(owner, spender, current_allowance);
        }
    }
}
