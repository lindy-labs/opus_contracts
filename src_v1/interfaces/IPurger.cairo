use starknet::ContractAddress;

use aura::utils::serde;
use aura::utils::types::AssetBalance;
use aura::utils::wadray::{Ray, Wad};

#[abi]
trait IPurger {
    // view
    fn get_liquidation_penalty(trove_id: u64) -> Ray;
    fn get_absorption_penalty(trove_id: u64) -> Ray;
    fn get_max_liquidation_amount(trove_id: u64) -> Wad;
    fn get_max_absorption_amount(trove_id: u64) -> Wad;
    fn get_compensation(trove_id: u64) -> Wad;
    fn is_absorbable(trove_id: u64) -> bool;
    fn get_penalty_scalar() -> Ray;
    // external
    fn set_penalty_scalar(new_scalar: Ray);
    fn liquidate(trove_id: u64, amt: Wad, recipient: ContractAddress) -> Span<AssetBalance>;
    fn absorb(trove_id: u64) -> Span<AssetBalance>;
}