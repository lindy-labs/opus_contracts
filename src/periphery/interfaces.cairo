use opus::types::{ShrineYangAssetInfo, TroveYangAssetInfo};
use starknet::ContractAddress;
use wadray::Wad;

#[starknet::interface]
pub trait IFrontendDataProvider<TContractState> {
    // getters
    fn get_trove_deposits(self: @TContractState, trove_id: u64) -> Span<TroveYangAssetInfo>;
    fn get_shrine_deposits(self: @TContractState) -> Span<ShrineYangAssetInfo>;
}
