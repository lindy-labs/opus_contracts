use opus::types::AssetBalance;
use opus::utils::wadray::Wad;

#[starknet::interface]
trait ICaretaker<TContractState> {
    // view
    fn preview_release(self: @TContractState, trove_id: u64) -> Span<AssetBalance>;
    fn preview_reclaim(self: @TContractState, yin: Wad) -> Span<AssetBalance>;
    // external
    fn shut(ref self: TContractState);
    fn release(ref self: TContractState, trove_id: u64) -> Span<AssetBalance>;
    fn reclaim(ref self: TContractState, yin: Wad) -> Span<AssetBalance>;
}
