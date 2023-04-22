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
    use aura::utils::types::Trove;
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
        yang_redistribution: LegacyMap::<(u64, u64), (Wad, Wad)>,
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
    // Internal
    //

    fn now() -> u64 {
        let time = starknet::get_block_info().unbox().block_timestamp;
        time / TIME_INTERVAL.try_into().unwrap()
    }
}
