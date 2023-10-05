use starknet::ContractAddress;

use opus::interfaces::IAbsorber::IBlesserDispatcher;
use opus::interfaces::IStabilizer::IStrategyManagerDispatcher;
use opus::utils::wadray::Wad;

#[derive(Copy, Drop, PartialEq, Serde)]
enum YangSuspensionStatus {
    None: (),
    Temporary: (),
    Permanent: ()
}

#[derive(Copy, Drop, Serde)]
struct YangBalance {
    yang_id: u32, //  ID of yang in Shrine
    amount: Wad, // Amount of yang in Wad
}

#[derive(Copy, Drop, PartialEq, Serde)]
struct AssetBalance {
    address: ContractAddress, // Address of the ERC-20 asset
    amount: u128, // Amount of the asset in the asset's decimals
}

#[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
struct Trove {
    charge_from: u64, // Time ID (timestamp // TIME_ID_INTERVAL) for start of next accumulated interest calculation
    debt: Wad, // Normalized debt
    last_rate_era: u64,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct YangRedistribution {
    unit_debt: Wad, // Amount of debt in wad to be distributed to each wad unit of yang
    error: Wad, // Amount of debt to be added to the next redistribution to calculate `debt_per_yang`
    exception: bool, // Whether the exception flow is triggered to redistribute the yang across all yangs
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct ExceptionalYangRedistribution {
    unit_debt: Wad, // Amount of debt to be distributed to each wad unit of recipient yang
    unit_yang: Wad, // Amount of redistributed yang to be distributed to each wad unit of recipient yang
}


//
// Absorber
//

// For absorptions, the `asset_amt_per_share` is tied to an absorption ID and is not changed once set.
// For blessings, the `asset_amt_per_share` is a cumulative value that is updated until the given epoch ends
#[derive(Copy, Drop, Serde, starknet::Store)]
struct DistributionInfo {
    asset_amt_per_share: u128, // Amount of asset in its decimal precision per share wad
    error: u128, // Error to be added to next absorption
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct Reward {
    asset: ContractAddress, // ERC20 address of token
    blesser: IBlesserDispatcher, // Address of contract implementing `IBlesser` for distributing the token to the absorber
    is_active: bool, // Whether the blesser (vesting contract) should be called
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct Provision {
    epoch: u32, // Epoch in which shares are issued
    shares: Wad, // Amount of shares for provider in the above epoch
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct Request {
    timestamp: u64, // Timestamp of request
    timelock: u64, // Amount of time that needs to elapse after the timestamp before removal
    has_removed: bool, // Whether provider has called `remove`
}

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

    #[derive(Copy, Drop, Serde, starknet::Store)]
    struct PricesResponse {
        price: u256,
        decimals: u256,
        last_updated_timestamp: u256,
        num_sources_aggregated: u256,
    }

    #[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
    struct PriceValidityThresholds {
        // the maximum number of seconds between block timestamp and
        // the last update timestamp (as reported by Pragma) for which
        // we consider a price update valid
        freshness: u64,
        // the minimum number of data publishers used to aggregate the
        // price value
        sources: u64
    }

    #[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
    struct YangSettings {
        // a Pragma value identifying a certain feed, e.g. `ETH/USD`
        pair_id: u256,
        // address of the Yang (token) corresponding to the pair ID
        yang: starknet::ContractAddress
    }
}

//
// Stabilizer
//

#[derive(Copy, Drop, Serde, starknet::Store)]
struct Strategy {
    // the strategy manager instance executing the strategy
    manager: IStrategyManagerDispatcher,
    // the maximum amount of assets from the Stabilizer that can be deployed
    // to this strategy
    ceiling: u128,
    // the amount of assets from the Stabilizer deployed to date
    deployed_amount: u128
}
