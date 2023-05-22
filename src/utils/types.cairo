use starknet::ContractAddress;
use starknet::StorageBaseAddress;

use aura::interfaces::IAbsorber::IBlesserDispatcher;
use aura::utils::serde::IBlesserDispatcherSerde;
use aura::utils::wadray::{Ray, Wad};

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


//
// Absorber
//

// For absorptions, the `asset_amt_per_share` is tied to an absorption ID and is not changed once set.
// For blessings, the `asset_amt_per_share` is a cumulative value that is updated until the given epoch ends
#[derive(Copy, Drop, Serde, storage_access::StorageAccess)]
struct DistributionInfo {
    asset_amt_per_share: u128, // Amount of asset in its decimal precision per share wad
    error: u128, // Error to be added to next absorption
}

#[derive(Copy, Drop, Serde, storage_access::StorageAccess)]
struct Reward {
    asset: ContractAddress, // ERC20 address of token
    blesser: IBlesserDispatcher, // Address of contract implementing `IBlesser` for distributing the token to the absorber
    is_active: bool, // Whether the blesser (vesting contract) should be called
}

#[derive(Copy, Drop, Serde, storage_access::StorageAccess)]
struct Provision {
    epoch: u32, // Epoch in which shares are issued
    shares: Wad, // Amount of shares for provider in the above epoch
}

#[derive(Copy, Drop, Serde, storage_access::StorageAccess)]
struct Request {
    timestamp: u64, // Timestamp of request
    timelock: u64, // Amount of time that needs to elapse after the timestamp before removal
    has_removed: bool, // Whether provider has called `remove`

//
// Pragma
//

mod Pragma {
    #[derive(Copy, Drop, Serde)]
    enum DataType {
        Spot: u256,
        Future: u256,
        Generic: u256,
    }

    #[derive(Copy, Drop, Serde)]
    struct PricesResponse {
        price: u256,
        decimals: u256,
        last_updated_timestamp: u256,
        num_sources_aggregated: u256,
    }

    #[derive(Copy, Drop, Serde)]
    struct PriceValidityThresholds {
        freshness: u64,
        sources: u64
    }

    #[derive(Copy, Drop, Serde)]
    struct YangSettings {
        pair_id: u256,
        yang: starknet::ContractAddress
    }
}
