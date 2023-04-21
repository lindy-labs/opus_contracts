#[contract]
mod Shrine {
    use starknet::ContractAddress;

    use aura::utils::wadray::Ray;
    use aura::utils::wadray::Wad;


    struct Storage {
        // A trove can forge debt up to its threshold depending on the yangs deposited.
        troves: LegacyMap::<usize, PackedTrove>,
        // Stores the amount of the "yin" (synthetic) each user owns.
        // yin can be exchanged for ERC20 synthetic tokens via the yin gate.
        yin: LegacyMap::<ContractAddress, Wad>,
        // Stores information about the total supply for each yang
        yang_total: LegacyMap::<usize, Wad>,
        // Number of collateral accepted by the system.
        // The return value is also the ID of the last added collateral.
        yangs_count: usize,
        // Mapping from yang ContractAddress to yang ID.
        // Yang ID starts at 1.
        yang_id: LegacyMap::<ContractAddress, usize>,
        // Keeps track of how much of each yang has been deposited into each Trove - Wad
        deposits: LegacyMap::<(usize, usize), Wad>,
        // Total amount of debt accrued
        total_debt: Wad,
        // Total amount of synthetic forged
        total_yin: Wad,
        // Keeps track of the price history of each Yang - packed
        // interval: timestamp divided by TIME_INTERVAL.
        // packed contains both the actual price (high 125 bits) and the cumulative price (low 125 bits) of
        // the yang at each time interval, both as Wads
        yang_price: LegacyMap::<(usize, usize), packed>,
        // Total debt ceiling - Wad
        ceiling: Wad,
        // Global interest rate multiplier - packed
        // packed contains both the actual multiplier (high 125 bits), and the cumulative multiplier (low 125 bits) of
        // the yang at each time interval, both as Rays
        multiplier: LegacyMap::<usize, packed>,
        // Keeps track of the most recent rates index
        // Each index is associated with an update to the interest rates of all yangs.
        rates_latest_era: usize,
        // Keeps track of the interval at which the rate update at `idx` was made.
        rates_intervals: LegacyMap::<usize, usize>,
        // Keeps track of the interest rate of each yang at each index
        yang_rates: LegacyMap::<(usize, usize), Ray>,
        // Liquidation threshold per yang (as LTV) - Ray
        thresholds: LegacyMap::<usize, Ray>,
        // Keeps track of how many redistributions have occurred
        redistributions_count: usize,
        // Last redistribution accounted for a trove
        trove_redistribution_id: LegacyMap::<usize, usize>,
        // Mapping of yang ID and redistribution ID to a packed value of
        // 1. amount of debt in Wad to be redistributed to each Wad unit of yang
        // 2. amount of debt to be added to the next redistribution to calculate (1)
        yang_redistribution: LegacyMap::<(usize, usize), packed>,
        // Keeps track of whether shrine is live or killed
        is_live: bool,
        // Yin storage
        yin_name: felt252,
        yin_symbol: felt252,
        yin_decimals: usize,
        yin_allowances: LegacyMap::<(ContractAddress, ContractAddress), u256>,
    }

    //
    // Events
    //

    #[event]
    fn YangAdded(yang: ContractAddress, yang_id: usize, start_price: Wad, initial_rate: Ray) {}

    #[event]
    fn YangTotalUpdated(yang: ContractAddress, total: Wad) {}

    #[event]
    fn DebtTotalUpdated(total: Wad) {}

    #[event]
    fn YangsCountUpdated(count: usize) {}

    #[event]
    fn MultiplierUpdated(multiplier: Ray, cumulative_multiplier: Ray, interval: usize) {}

    #[event]
    fn YangRatesUpdated(
        new_rate_idx: usize,
        current_interval: usize,
        yangs_len: usize, //yangs: ContractAddress*,
        new_rates_len: usize,
    //new_rates: Ray*,
    ) {}

    #[event]
    fn ThresholdUpdated(yang: ContractAddress, threshold: Ray) {}

    #[event]
    fn TroveUpdated(trove_id: usize, trove: Trove) {}

    #[event]
    fn TroveRedistributed(redistribution_id: usize, trove_id: usize, debt: Wad) {}

    #[event]
    fn DepositUpdated(yang: ContractAddress, trove_id: usize, amount: Wad) {}

    #[event]
    fn YangPriceUpdated(
        yang: ContractAddress, price: Wad, cumulative_price: Wad, interval: usize
    ) {}

    #[event]
    fn CeilingUpdated(ceiling: Wad) {}

    #[event]
    fn Killed() {}

    // ERC20 events
    #[event]
    fn Transfer(from_: ContractAddress, to: ContractAddress, value: Uint256) {}

    #[event]
    fn Approval(owner: ContractAddress, spender: ContractAddress, value: Uint256) {}
}
