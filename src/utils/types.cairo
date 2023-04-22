use aura::utils::wadray::Wad;
use aura::utils::storage_access_impls::TroveStorageAccess;

#[derive(Drop, Serde)]
struct Trove {
    charge_from: usize, // Time ID (timestamp // TIME_ID_INTERVAL) for start of next accumulated interest calculation
    debt: Wad, // Normalized debt
    last_rate_era: usize,
}
