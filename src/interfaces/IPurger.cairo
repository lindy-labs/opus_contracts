use starknet::ContractAddress;

use aura::utils::serde;
use aura::utils::wadray::{Ray, Wad};

#[abi]
trait IPurger {
    // view
    fn get_penalty(trove_id: u64, is_absorption: bool) -> Ray;
    fn get_max_close_amount(trove_id: u64, is_absorption: bool) -> Wad;
    fn is_absorbable(trove_id: u64) -> bool;
    // external
    fn liquidate(
        trove_id: u64, amt: Wad, recipient: ContractAddress
    ) -> (Span<ContractAddress>, Span<u128>);
    fn absorb(trove_id: u64) -> (Span<ContractAddress>, Span<u128>);
}
