use starknet::ContractAddress;

use aura::utils::types::AssetBalance;
use aura::utils::wadray::{Ray, Wad};

#[starknet::interface]
trait IPurger {
    // getter
    fn get_penalty_scalar(self: TContractState) -> Ray;
    // external
    fn set_penalty_scalar(ref self: TContractState, new_scalar: Ray);
    fn liquidate(
        ref self: TContractState, trove_id: u64, amt: Wad, recipient: ContractAddress
    ) -> Span<AssetBalance>;
    fn absorb(ref self: TContractState, trove_id: u64) -> Span<AssetBalance>;
    // view
    fn get_liquidation_penalty(self: @TContractState, trove_id: u64) -> Ray;
    fn get_absorption_penalty(self: @TContractState, trove_id: u64) -> Ray;
    fn get_max_liquidation_amount(self: @TContractState, trove_id: u64) -> Wad;
    fn get_max_absorption_amount(self: @TContractState, trove_id: u64) -> Wad;
    fn get_compensation(self: @TContractState, trove_id: u64) -> Wad;
    fn is_absorbable(self: @TContractState, trove_id: u64) -> bool;
}
