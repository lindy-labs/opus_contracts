use opus::constants::{
    ETH_USD_PAIR_ID, SSTRK_USD_PAIR_ID, STRK_USD_PAIR_ID, WBTC_USD_PAIR_ID, WSTETH_USD_PAIR_ID, XSTRK_USD_PAIR_ID,
};
use opus::types::pragma::{AggregationMode, PairSettings};
use starknet::ClassHash;

pub const MAX_FEE: felt252 = 9999999999999999999999;

// Constants for Shrine
pub const INITIAL_DEBT_CEILING: u128 = 1000000000000000000000000; // 1_000_000 (Wad)
pub const MINIMUM_TROVE_VALUE: u128 = 100000000000000000000; // 100 (Wad)

// Constants for Pragma spot
pub const PRAGMA_FRESHNESS_THRESHOLD: u64 = 3600; // 1 hour
pub const PRAGMA_SOURCES_THRESHOLD: u32 = 3;

// Constants for yangs
pub const INITIAL_ETH_AMT: u128 = 1000000000; // 10 ** 9
pub const INITIAL_STRK_AMT: u128 = 1000000000; // 10 ** 9
pub const INITIAL_WBTC_AMT: u128 = 10000; // 10 ** 4
pub const INITIAL_WSTETH_AMT: u128 = 1000000000; // 10 ** 9

pub const INITIAL_ETH_ASSET_MAX: u128 = 600000000000000000000; // 600 (Wad)
pub const INITIAL_ETH_THRESHOLD: u128 = 850000000000000000000000000; // 85% (Ray)
pub const INITIAL_ETH_PRICE: u128 = 3400000000000000000000; // 3_400 (Wad)
pub const INITIAL_ETH_BASE_RATE: u128 = 30000000000000000000000000; // 3% (Ray)

pub const INITIAL_STRK_ASSET_MAX: u128 = 600000000000000000000000; // 600_000 (Wad)
pub const INITIAL_STRK_THRESHOLD: u128 = 630000000000000000000000000; // 63% (Ray)
pub const INITIAL_STRK_PRICE: u128 = 700000000000000000; // 0.70 (Wad)
pub const INITIAL_STRK_BASE_RATE: u128 = 70000000000000000000000000; // 7% (Ray)

pub const INITIAL_WBTC_ASSET_MAX: u128 = 500000000; // 5 (10 ** 8)
pub const INITIAL_WBTC_THRESHOLD: u128 = 780000000000000000000000000; // 78% (Ray)
pub const INITIAL_WBTC_PRICE: u128 = 62000000000000000000000; // 62_000 (Wad)
pub const INITIAL_WBTC_BASE_RATE: u128 = 40000000000000000000000000; // 4% (Ray)

pub const INITIAL_WSTETH_ASSET_MAX: u128 = 40000000000000000000; // 40 (Wad)
pub const INITIAL_WSTETH_THRESHOLD: u128 = 790000000000000000000000000; // 79% (Ray)
pub const INITIAL_WSTETH_PRICE: u128 = 4000000000000000000000; // 4_000 (Wad)
pub const INITIAL_WSTETH_BASE_RATE: u128 = 47500000000000000000000000; // 4.75% (Ray)

// Constants for restricted Transmuter
pub const USDC_TRANSMUTER_RESTRICTED_DEBT_CEILING: u128 = 250000000000000000000000; // 250,000 (Wad)

// Constants for mocks
pub const USDC_INITIAL_SUPPLY: u128 = 1000000000000; // 1,000,000 (10**6)
pub const WBTC_INITIAL_SUPPLY: u128 = 2099999997690000; // approx. 21_000_000 * 10 ** 8

// Chain constants
pub fn erc20_class_hash() -> ClassHash {
    0x11374319A6E07B4F2738FA3BFA8CF2181BFB0DBB4D800215BAA87B83A57877E.try_into().expect('invalid ERC20 class hash')
}

pub fn pragma_eth_pair_settings() -> PairSettings {
    PairSettings { pair_id: ETH_USD_PAIR_ID, aggregation_mode: AggregationMode::Median }
}

pub fn pragma_strk_pair_settings() -> PairSettings {
    PairSettings { pair_id: STRK_USD_PAIR_ID, aggregation_mode: AggregationMode::Median }
}

pub fn pragma_wbtc_pair_settings() -> PairSettings {
    PairSettings { pair_id: WBTC_USD_PAIR_ID, aggregation_mode: AggregationMode::Median }
}

pub fn pragma_wsteth_pair_settings() -> PairSettings {
    PairSettings { pair_id: WSTETH_USD_PAIR_ID, aggregation_mode: AggregationMode::Median }
}

pub fn pragma_xstrk_pair_settings() -> PairSettings {
    PairSettings { pair_id: XSTRK_USD_PAIR_ID, aggregation_mode: AggregationMode::ConversionRate }
}

pub fn pragma_sstrk_pair_settings() -> PairSettings {
    PairSettings { pair_id: SSTRK_USD_PAIR_ID, aggregation_mode: AggregationMode::ConversionRate }
}
