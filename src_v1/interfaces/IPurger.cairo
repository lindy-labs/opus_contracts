use starknet::ContractAddress;

use aura::utils::serde;
use aura::utils::types::AssetBalance;
use aura::utils::wadray::{Ray, Wad};

#[abi]
trait IPurger {
    // view
    fn preview_liquidate(trove_id: u64) -> (Ray, Wad);
    fn preview_absorb(trove_id: u64) -> (Ray, Wad, Wad);
    fn is_absorbable(trove_id: u64) -> bool;
    fn get_penalty_scalar() -> Ray;
    // external
    fn set_penalty_scalar(new_scalar: Ray);
    fn liquidate(trove_id: u64, amt: Wad, recipient: ContractAddress) -> Span<AssetBalance>;
    fn absorb(trove_id: u64) -> Span<AssetBalance>;
}
