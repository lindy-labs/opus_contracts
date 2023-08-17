use array::SpanTrait;

use aura::utils::serde;
use aura::utils::types::AssetBalance;
use aura::utils::wadray::Wad;

#[abi]
trait ICaretaker {
    // getter
    fn preview_release(trove_id: u64) -> Span<AssetBalance>;
    fn preview_reclaim(yin: Wad) -> Span<AssetBalance>;
    // external
    fn shut();
    fn release(trove_id: u64) -> Span<AssetBalance>;
    fn reclaim(yin: Wad) -> Span<AssetBalance>;
}
