use opus::constants::{
    ETH_USD_PAIR_ID, SSTRK_USD_PAIR_ID, STRK_USD_PAIR_ID, WBTC_USD_PAIR_ID, WSTETH_USD_PAIR_ID, XSTRK_USD_PAIR_ID,
};
use opus::types::pragma::{AggregationMode, PairSettings};
use starknet::ClassHash;
use wadray::{RAY_PERCENT, WAD_ONE};

pub const MAX_FEE: felt252 = 9999999999999999999999;

// Constants for Shrine
pub const INITIAL_DEBT_CEILING: u128 = 1000000 * WAD_ONE; // 1_000_000 (Wad)
pub const MINIMUM_TROVE_VALUE: u128 = 100 * WAD_ONE; // 100 (Wad)

// Constants for Pragma spot
pub const PRAGMA_FRESHNESS_THRESHOLD: u64 = 3600; // 1 hour
pub const PRAGMA_SOURCES_THRESHOLD: u32 = 3;

// Constants for yangs
pub const INITIAL_ETH_AMT: u128 = 1000000000; // 10 ** 9
pub const INITIAL_STRK_AMT: u128 = 1000000000; // 10 ** 9
pub const INITIAL_WBTC_AMT: u128 = 10000; // 10 ** 4
pub const INITIAL_WSTETH_AMT: u128 = 1000000000; // 10 ** 9

pub const INITIAL_ETH_ASSET_MAX: u128 = 600 * WAD_ONE; // 600 (Wad)
pub const INITIAL_ETH_THRESHOLD: u128 = 85 * RAY_PERCENT; // 85% (Ray)
pub const INITIAL_ETH_PRICE: u128 = 3400 * WAD_ONE; // 3_400 (Wad)
pub const INITIAL_ETH_BASE_RATE: u128 = 3 * RAY_PERCENT; // 3% (Ray)

pub const INITIAL_STRK_ASSET_MAX: u128 = 600000 * WAD_ONE; // 600_000 (Wad)
pub const INITIAL_STRK_THRESHOLD: u128 = 63 * RAY_PERCENT; // 63% (Ray)
pub const INITIAL_STRK_PRICE: u128 = 700000000000000000; // 0.70 (Wad)
pub const INITIAL_STRK_BASE_RATE: u128 = 7 * RAY_PERCENT; // 7% (Ray)

pub const INITIAL_WBTC_ASSET_MAX: u128 = 500000000; // 5 (10 ** 8)
pub const INITIAL_WBTC_THRESHOLD: u128 = 78 * RAY_PERCENT; // 78% (Ray)
pub const INITIAL_WBTC_PRICE: u128 = 62000 * WAD_ONE; // 62_000 (Wad)
pub const INITIAL_WBTC_BASE_RATE: u128 = 4 * RAY_PERCENT; // 4% (Ray)

pub const INITIAL_WSTETH_ASSET_MAX: u128 = 40 * WAD_ONE; // 40 (Wad)
pub const INITIAL_WSTETH_THRESHOLD: u128 = 79 * RAY_PERCENT; // 79% (Ray)
pub const INITIAL_WSTETH_PRICE: u128 = 4000 * WAD_ONE; // 4_000 (Wad)
pub const INITIAL_WSTETH_BASE_RATE: u128 = 47500000000000000000000000; // 4.75% (Ray)

// Constants for restricted Transmuter
pub const USDC_TRANSMUTER_RESTRICTED_DEBT_CEILING: u128 = 250000 * WAD_ONE; // 250,000 (Wad)

// Constants for mocks
pub const USDC_INITIAL_SUPPLY: u128 = 1000000000000; // 1,000,000 (10**6)
pub const WBTC_INITIAL_SUPPLY: u128 = 2099999997690000; // approx. 21_000_000 * 10 ** 8

// Constants for Pragma oracle adapter
pub const PRAGMA_ETH_PAIR_SETTINGS: PairSettings = PairSettings {
    pair_id: ETH_USD_PAIR_ID, aggregation_mode: AggregationMode::Median,
};
pub const PRAGMA_STRK_PAIR_SETTINGS: PairSettings = PairSettings {
    pair_id: STRK_USD_PAIR_ID, aggregation_mode: AggregationMode::Median,
};
pub const PRAGMA_WBTC_PAIR_SETTINGS: PairSettings = PairSettings {
    pair_id: WBTC_USD_PAIR_ID, aggregation_mode: AggregationMode::Median,
};
pub const PRAGMA_WSTETH_PAIR_SETTINGS: PairSettings = PairSettings {
    pair_id: WSTETH_USD_PAIR_ID, aggregation_mode: AggregationMode::Median,
};
pub const PRAGMA_XSTRK_PAIR_SETTINGS: PairSettings = PairSettings {
    pair_id: XSTRK_USD_PAIR_ID, aggregation_mode: AggregationMode::ConversionRate,
};
pub const PRAGMA_SSTRK_PAIR_SETTINGS: PairSettings = PairSettings {
    pair_id: SSTRK_USD_PAIR_ID, aggregation_mode: AggregationMode::ConversionRate,
};

// Chain constants
pub const ERC20_CLASS_HASH: ClassHash = 0x11374319A6E07B4F2738FA3BFA8CF2181BFB0DBB4D800215BAA87B83A57877E
    .try_into()
    .unwrap();
