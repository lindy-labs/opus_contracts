use array::SpanTrait;
use starknet::ContractAddress;

use aura::utils::serde;
use aura::utils::wadray::Wad;

#[starknet::interface]
trait ICaretaker<TStorage> {
    // getter
    fn get_live(self: @TStorage) -> bool;
    fn preview_release(self: @TStorage, trove_id: u64) -> (Span<ContractAddress>, Span<u128>);
    fn preview_reclaim(self: @TStorage, yin: Wad) -> (Span<ContractAddress>, Span<u128>);
    // external
    fn shut(ref self: TStorage);
    fn release(ref self: TStorage, trove_id: u64) -> (Span<ContractAddress>, Span<u128>);
    fn reclaim(ref self: TStorage, yin: Wad) -> (Span<ContractAddress>, Span<u128>);
}
