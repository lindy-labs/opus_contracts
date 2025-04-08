use opus::types::Health;
use starknet::ContractAddress;
use wadray::{Ray, Wad};


#[derive(Copy, Debug, Drop, Serde)]
pub struct YinInfo {
    pub spot_price: Wad, // Spot price of yin
    pub total_supply: Wad, // Total supply of yin
    pub ceiling: Wad // Maximum amount of yin allowed
}

#[derive(Copy, Debug, Drop, Serde)]
pub struct RecoveryModeInfo {
    pub is_recovery_mode: bool,
    pub target_ltv: Ray, // Recovery mode is triggered once Shrine's LTV exceeds this
    pub buffer_ltv: Ray // Thresholds are scaled once Shrine's LTV exceeds this
}

#[derive(Copy, Debug, Drop, Serde)]
pub struct TroveInfo {
    pub trove_id: u64,
    pub owner: ContractAddress,
    pub max_forge_amt: Wad,
    pub is_liquidatable: bool,
    pub is_absorbable: bool,
    pub health: Health,
    pub assets: Span<TroveAssetInfo>,
}

#[derive(Copy, Debug, Drop, Serde)]
pub struct TroveAssetInfo {
    pub shrine_asset_info: ShrineAssetInfo,
    pub amount: u128, // Amount of the yang's asset in the asset's decimals for the trove
    pub value: Wad // Value of the yang in the trove
}

#[derive(Copy, Debug, Drop, Serde)]
pub struct ShrineAssetInfo {
    pub address: ContractAddress, // Address of the yang's ERC-20 asset
    pub price: Wad, // Price of the yang's asset
    pub threshold: Ray, // Base threshold of the yang
    pub base_rate: Ray, // Base rate of the yang
    pub deposited: u128, // Amount of yang's asset in the asset's decimals deposited in Shrine
    pub ceiling: u128, // Maximum amount of yang's asset in Shrine
    pub deposited_value: Wad // Value of yang deposited in Shrine
}

