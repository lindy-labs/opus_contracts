use starknet::{ContractAddress, StorePacking};

use opus::interfaces::IAbsorber::IBlesserDispatcher;
use opus::utils::wadray;
use opus::utils::wadray::Wad;

const TWO_POW_32: u256 = 0x100000000;
const MASK_32: u256 = 0xffffffff;

const TWO_POW_64: u256 = 0x10000000000000000;
const MASK_64: u256 = 0xffffffffffffffff;

const TWO_POW_128: u256 = 0x100000000000000000000000000000000;
const MASK_128: u256 = 0xffffffffffffffffffffffffffffffff;

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

#[derive(Copy, Drop, PartialEq, Serde)]
struct Trove {
    charge_from: u64, // Time ID (timestamp // TIME_ID_INTERVAL) for start of next accumulated interest calculation
    last_rate_era: u64,
    debt: Wad, // Normalized debt
}

impl TroveStorePacking of StorePacking<Trove, u256> {
    fn pack(value: Trove) -> u256 {
        (value.charge_from.into()
            + (value.last_rate_era.into() * TWO_POW_64)
            + (value.debt.into() * TWO_POW_128))
    }

    fn unpack(value: u256) -> Trove {
        let charge_from = value & MASK_64;
        let last_rate_era = (value / TWO_POW_64) & MASK_64;
        let debt = value / TWO_POW_128;

        Trove {
            charge_from: charge_from.try_into().unwrap(),
            last_rate_era: last_rate_era.try_into().unwrap(),
            debt: debt.try_into().unwrap(),
        }
    }
}

#[derive(Copy, Drop, Serde)]
struct YangRedistribution {
    unit_debt: Wad, // Amount of debt in wad to be distributed to each wad unit of yang
    error: Wad, // Amount of debt to be added to the next redistribution to calculate `debt_per_yang`
    exception: bool, // Whether the exception flow is triggered to redistribute the yang across all yangs
}

#[derive(Copy, Drop, starknet::Store)]
struct PackedYangRedistribution {
    packed: u256, // Packed value of unit debt and error
    exception: bool, // Whether the exception flow is triggered to redistribute the yang across all yangs
}

impl YangRedistributionStorePacking of StorePacking<YangRedistribution, PackedYangRedistribution> {
    fn pack(value: YangRedistribution) -> PackedYangRedistribution {
        PackedYangRedistribution {
            packed: value.unit_debt.into() + (value.error.into() * TWO_POW_128),
            exception: value.exception
        }
    }

    fn unpack(value: PackedYangRedistribution) -> YangRedistribution {
        let unit_debt = value.packed & MASK_128;
        let error = value.packed / TWO_POW_128;

        YangRedistribution {
            unit_debt: unit_debt.try_into().unwrap(),
            error: error.try_into().unwrap(),
            exception: value.exception
        }
    }
}

#[derive(Copy, Drop, Serde)]
struct ExceptionalYangRedistribution {
    unit_debt: Wad, // Amount of debt to be distributed to each wad unit of recipient yang
    unit_yang: Wad, // Amount of redistributed yang to be distributed to each wad unit of recipient yang
}

impl ExceptionalYangRedistributionStorePacking of StorePacking<
    ExceptionalYangRedistribution, u256
> {
    fn pack(value: ExceptionalYangRedistribution) -> u256 {
        value.unit_debt.into() + (value.unit_yang.into() * TWO_POW_128)
    }

    fn unpack(value: u256) -> ExceptionalYangRedistribution {
        let unit_debt = value & MASK_128;
        let unit_yang = value / TWO_POW_128;

        ExceptionalYangRedistribution {
            unit_debt: unit_debt.try_into().unwrap(), unit_yang: unit_yang.try_into().unwrap()
        }
    }
}

//
// Absorber
//

// For absorptions, the `asset_amt_per_share` is tied to an absorption ID and is not changed once set.
// For blessings, the `asset_amt_per_share` is a cumulative value that is updated until the given epoch ends
#[derive(Copy, Drop, Serde)]
struct DistributionInfo {
    asset_amt_per_share: u128, // Amount of asset in its decimal precision per share wad
    error: u128, // Error to be added to next absorption
}

impl DistributionInfoStorePacking of StorePacking<DistributionInfo, u256> {
    fn pack(value: DistributionInfo) -> u256 {
        value.asset_amt_per_share.into() + (value.error.into() * TWO_POW_128)
    }

    fn unpack(value: u256) -> DistributionInfo {
        let asset_amt_per_share = value & MASK_128;
        let error = value / TWO_POW_128;

        DistributionInfo {
            asset_amt_per_share: asset_amt_per_share.try_into().unwrap(),
            error: error.try_into().unwrap()
        }
    }
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct Reward {
    asset: ContractAddress, // ERC20 address of token
    blesser: IBlesserDispatcher, // Address of contract implementing `IBlesser` for distributing the token to the absorber
    is_active: bool, // Whether the blesser (vesting contract) should be called
}

#[derive(Copy, Drop, Serde)]
struct Provision {
    epoch: u32, // Epoch in which shares are issued
    shares: Wad, // Amount of shares for provider in the above epoch
}

impl ProvisionStorePacking of StorePacking<Provision, u256> {
    fn pack(value: Provision) -> u256 {
        value.epoch.into() + (value.shares.into() * TWO_POW_32)
    }

    fn unpack(value: u256) -> Provision {
        let epoch = value & MASK_32;
        let shares = value / TWO_POW_32;

        Provision { epoch: epoch.try_into().unwrap(), shares: shares.try_into().unwrap() }
    }
}

#[derive(Copy, Drop, Serde)]
struct Request {
    timestamp: u64, // Timestamp of request
    timelock: u64, // Amount of time that needs to elapse after the timestamp before removal
    has_removed: bool, // Whether provider has called `remove`
}

impl RequestStorePacking of StorePacking<Request, u256> {
    fn pack(value: Request) -> u256 {
        let has_removed: u256 = if value.has_removed {
            1
        } else {
            0
        };
        value.timestamp.into()
            + (value.timelock.into() * TWO_POW_64)
            + (has_removed.into() * TWO_POW_128)
    }

    fn unpack(value: u256) -> Request {
        let timestamp = value & MASK_64;
        let timelock = (value / TWO_POW_64) & MASK_64;
        let has_removed = value / TWO_POW_128;

        Request {
            timestamp: timestamp.try_into().unwrap(),
            timelock: timelock.try_into().unwrap(),
            has_removed: has_removed == 1
        }
    }
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
