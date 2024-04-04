use opus::types::{RecoveryModeInfo, ShrineYangAssetInfo, TroveYangAssetInfo, YinInfo};
use starknet::ContractAddress;
use wadray::Wad;

#[starknet::interface]
pub trait IFrontendDataProvider<TContractState> {
    // getters
    fn get_yin_info(self: @TContractState) -> YinInfo;
    fn get_recovery_mode_info(self: @TContractState) -> RecoveryModeInfo;
    fn get_trove_deposits(self: @TContractState, trove_id: u64) -> Span<TroveYangAssetInfo>;
    fn get_shrine_deposits(self: @TContractState) -> Span<ShrineYangAssetInfo>;
}
