use starknet::StorageBaseAddress;

use aura::utils::wadray::Wad;

#[derive(Copy, Drop, Serde, storage_access::StorageAccess)]
struct Trove {
    charge_from: u64, // Time ID (timestamp // TIME_ID_INTERVAL) for start of next accumulated interest calculation
    debt: Wad, // Normalized debt
    last_rate_era: u64,
}

#[derive(Drop, Serde, storage_access::StorageAccess)]
struct YangRedistribution {
    unit_debt: Wad, // Amount of debt in wad to be distributed to each wad unit of yang
    error: Wad, // Amount of debt to be added to the next redistribution to calculate `debt_per_yang`
}
