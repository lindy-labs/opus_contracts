use opus::types::AssetBalance;
use starknet::ContractAddress;
use wadray::Wad;

#[starknet::interface]
pub trait IFrontendDataProvider<TContractState> {
    // getters
    fn get_trove_deposits(self: @TContractState, trove_id: u64) -> (Span<AssetBalance>, Span<Wad>);
    fn get_shrine_deposits(self: @TContractState) -> (Span<AssetBalance>, Span<Wad>, Span<u128>);
}
