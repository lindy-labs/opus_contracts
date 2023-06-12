use array::SpanTrait;
use starknet::ContractAddress;

use aura::utils::serde;
use aura::utils::wadray::Wad;

#[abi]
trait ICaretaker {
    // getter
    fn preview_release(trove_id: u64) -> (Span<ContractAddress>, Span<u128>);
    fn preview_reclaim(yin: Wad) -> (Span<ContractAddress>, Span<u128>);
    // external
    fn shut();
    fn release(trove_id: u64) -> (Span<ContractAddress>, Span<u128>);
    fn reclaim(yin: Wad) -> (Span<ContractAddress>, Span<u128>);
}
