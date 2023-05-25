use starknet::ContractAddress;

use aura::utils::serde;
use aura::utils::wadray::{Ray, Wad};

#[abi]
trait IAbsorber {
    // view
    fn get_penalty(trove_id: u64) -> Ray;
    fn get_max_close_amount(trove_id: u64) -> Wad;
    // external
    fn liquidate(
        trove_id: u64, amt: Wad, recipient: ContractAddress
    ) -> (Span<ContractAddress>, Span<u128>);
    fn absorb(trove_id: u64) -> (Span<ContractAddress>, Span<u128>);
}
