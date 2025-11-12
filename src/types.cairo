use core::cmp::min;
use core::fmt::{Debug, Display, Error, Formatter};
use core::traits::DivRem;
use opus::interfaces::IAbsorber::IBlesserDispatcher;
use starknet::ContractAddress;
use starknet::storage_access::StorePacking;
use wadray::{Ray, Wad};

const TWO_POW_32: felt252 = 0x100000000;
const TWO_POW_64: felt252 = 0x10000000000000000;
const TWO_POW_123: felt252 = 0x8000000000000000000000000000000;
const TWO_POW_128: felt252 = 0x100000000000000000000000000000000;

pub impl DislayUsingDebug<T, impl TDebug: Debug<T>> of Display<T> {
    fn fmt(self: @T, ref f: Formatter) -> Result<(), Error> {
        TDebug::fmt(self, ref f)
    }
}

#[derive(Copy, Drop, PartialEq, Serde)]
pub enum YangSuspensionStatus {
    None,
    Temporary,
    Permanent,
}

#[derive(Copy, Debug, Drop, Serde)]
pub struct Health {
    // In the case of a trove, either:
    // 1. the base threshold at which the trove can be liquidated in normal mode; or
    // 2. the threshold at which the trove can be liquidated based on current on-chain
    //    conditions.
    //
    // In the case of Shrine, the base threshold for calculating recovery mode status
    pub threshold: Ray,
    // Debt as a percentage of value
    pub ltv: Ray,
    // Total value of collateral
    pub value: Wad,
    // Total amount of debt
    pub debt: Wad,
}

#[generate_trait]
pub impl HealthImpl of HealthTrait {
    fn is_healthy(self: @Health) -> bool {
        (*self.ltv) <= (*self.threshold)
    }
}

#[derive(Copy, Debug, Drop, Serde)]
pub struct YangBalance {
    pub yang_id: u32, //  ID of yang in Shrine
    pub amount: Wad // Amount of yang in Wad
}

#[derive(Copy, Drop, PartialEq, Serde)]
pub struct AssetBalance {
    pub address: ContractAddress, // Address of the ERC-20 asset
    pub amount: u128 // Amount of the asset in the asset's decimals
}

#[derive(Copy, Debug, Drop, PartialEq, Serde)]
pub struct Trove {
    pub charge_from: u64, // Time ID (timestamp // TIME_ID_INTERVAL) for start of next accumulated interest calculation
    pub last_rate_era: u64,
    pub debt: Wad // Normalized debt
}

impl TroveStorePacking of StorePacking<Trove, u256> {
    fn pack(value: Trove) -> u256 {
        (value.charge_from.into()
            + (value.last_rate_era.into() * TWO_POW_64.into())
            + (value.debt.into() * TWO_POW_128.into()))
    }

    fn unpack(value: u256) -> Trove {
        let shift: u256 = TWO_POW_64.into();
        let shift: NonZero<u256> = shift.try_into().unwrap();
        let (rest, charge_from) = DivRem::div_rem(value, shift);
        let (debt, last_rate_era) = DivRem::div_rem(rest, shift);

        Trove {
            charge_from: charge_from.try_into().unwrap(),
            last_rate_era: last_rate_era.try_into().unwrap(),
            debt: debt.try_into().unwrap(),
        }
    }
}

//
// Absorber
//

// For blessings, the `asset_amt_per_share` is a cumulative value that is updated until the given epoch ends
#[derive(Copy, Debug, Drop, PartialEq, Serde)]
pub struct DistributionInfo {
    // Amount of asset in its decimal precision per share wad
    // This is packed into bits 0 to 127.
    pub asset_amt_per_share: u128,
    // Error to be added to next distribution of rewards
    // This is packed into bits 128 to 251.
    // Note that the error should never approach close to 2 ** 123, but it is capped to this value anyway
    // to prevent redistributions from failing in this unlikely scenario, at the expense of providers
    // losing out on some rewards.
    pub error: u128,
}

// 2 ** 123 - 1
const MAX_DISTRIBUTION_INFO_ERROR: u128 = 0x7ffffffffffffffffffffffffffffff;

impl DistributionInfoStorePacking of StorePacking<DistributionInfo, felt252> {
    fn pack(value: DistributionInfo) -> felt252 {
        let capped_error: u128 = min(value.error, MAX_DISTRIBUTION_INFO_ERROR);
        value.asset_amt_per_share.into() + (capped_error.into() * TWO_POW_128)
    }

    fn unpack(value: felt252) -> DistributionInfo {
        let value: u256 = value.into();
        let shift: u256 = TWO_POW_128.into();
        let shift: NonZero<u256> = shift.try_into().unwrap();
        let (error, asset_amt_per_share) = DivRem::div_rem(value, shift);

        DistributionInfo {
            asset_amt_per_share: asset_amt_per_share.try_into().unwrap(), error: error.try_into().unwrap(),
        }
    }
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Reward {
    pub asset: ContractAddress, // ERC20 address of token
    pub blesser: IBlesserDispatcher, // Address of contract implementing `IBlesser` for distributing the token to the absorber
    pub is_active: bool // Whether the blesser (vesting contract) should be called
}

#[derive(Copy, Debug, Drop, PartialEq, Serde)]
pub struct Provision {
    pub epoch: u32, // Epoch in which shares are issued
    pub shares: Wad // Amount of shares for provider in the above epoch
}

impl ProvisionStorePacking of StorePacking<Provision, felt252> {
    fn pack(value: Provision) -> felt252 {
        value.epoch.into() + (value.shares.into() * TWO_POW_32)
    }

    fn unpack(value: felt252) -> Provision {
        let value: u256 = value.into();
        let shift: u256 = TWO_POW_32.into();
        let shift: NonZero<u256> = shift.try_into().unwrap();
        let (shares, epoch) = DivRem::div_rem(value, shift);

        Provision { epoch: epoch.try_into().unwrap(), shares: shares.try_into().unwrap() }
    }
}

//
// Receptor
//

#[derive(Copy, Debug, Drop, PartialEq, Serde, starknet::Store)]
pub struct QuoteTokenInfo {
    pub address: ContractAddress,
    pub decimals: u8,
}

//
// Pragma
//

pub mod pragma {
    #[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
    pub enum AggregationMode {
        #[default]
        Median,
        Mean,
        ConversionRate,
        Error,
    }

    #[derive(Copy, Drop, Serde)]
    pub enum DataType {
        SpotEntry: felt252,
        FutureEntry: (felt252, u64),
        GenericEntry: felt252,
    }

    #[derive(Copy, Drop, Serde)]
    pub struct PragmaPricesResponse {
        pub price: u128,
        pub decimals: u32,
        pub last_updated_timestamp: u64,
        pub num_sources_aggregated: u32,
        pub expiration_timestamp: Option<u64>,
    }

    #[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
    pub struct PriceValidityThresholds {
        // the maximum number of seconds between block timestamp and
        // the last update timestamp (as reported by Pragma) for which
        // we consider a price update valid
        pub freshness: u64,
        // the minimum number of data publishers used to aggregate the
        // price value
        pub sources: u32,
    }

    #[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
    pub struct PairSettings {
        pub pair_id: felt252,
        pub aggregation_mode: AggregationMode,
    }
}

//
// Seer
//

#[derive(Copy, Default, Drop, Debug, PartialEq, Serde, starknet::Store)]
pub enum PriceType {
    #[default]
    Direct,
    Vault,
}

#[derive(Copy, Default, Drop, Debug, PartialEq, Serde, starknet::Store)]
pub enum InternalPriceType {
    #[default]
    Direct,
    Vault: ConversionRateInfo,
}


// Used for ERC-4626 vault assets with an underlying asset and a conversion
// rate
#[derive(Copy, Drop, Debug, PartialEq, Serde, starknet::Store)]
pub struct ConversionRateInfo {
    // Address of the underlying asset
    pub asset: ContractAddress,
    // Scale that must be multiplied with the conversion rate to assets
    // to get wad precision.
    pub conversion_rate_scale: u128,
}

