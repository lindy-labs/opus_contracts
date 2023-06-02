use starknet::ContractAddress;

use aura::utils::serde;
use aura::utils::wadray::{Ray, Wad};

#[starknet::interface]
trait IPurger<TStorage> {
    // view
    fn get_penalty(self: @TStorage, trove_id: u64) -> Ray;
    fn get_max_close_amount(self: @TStorage, trove_id: u64) -> Wad;
    // external
    fn liquidate(
        ref self: TStorage, trove_id: u64, amt: Wad, recipient: ContractAddress
    ) -> (Span<ContractAddress>, Span<u128>);
    fn absorb(ref self: TStorage, trove_id: u64) -> (Span<ContractAddress>, Span<u128>);
}
