use opus::periphery::types::{RecoveryModeInfo, ShrineAssetInfo, TroveInfo, YinInfo};


#[starknet::interface]
pub trait IFrontendDataProvider<TContractState> {
    // getters
    fn get_yin_info(self: @TContractState) -> YinInfo;
    fn get_recovery_mode_info(self: @TContractState) -> RecoveryModeInfo;
    fn get_trove_info(self: @TContractState, trove_id: u64) -> TroveInfo;
    fn get_shrine_assets_info(self: @TContractState) -> Span<ShrineAssetInfo>;
}
