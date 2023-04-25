use aura::utils::wadray::Wad;
use aura::utils::storage_access_impls::TroveStorageAccess;

#[derive(Copy, Drop, Serde)]
struct Trove {
    charge_from: u64, // Time ID (timestamp // TIME_ID_INTERVAL) for start of next accumulated interest calculation
    debt: Wad, // Normalized debt
    last_rate_era: u64,
}

#[derive(Drop, Serde)]
struct YangRedistribution {
    unit_debt: Wad, // Amount of debt in wad to be distributed to each wad unit of yang
    error: Wad, // Amount of debt to be added to the next redistribution to calculate `debt_per_yang`
}
