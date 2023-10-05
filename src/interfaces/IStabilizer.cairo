use starknet::ContractAddress;

use opus::types::Strategy;
use opus::utils::wadray::{Ray, Wad};

#[starknet::interface]
trait IStabilizer<TContractState> {
    // getters
    fn get_asset(self: @TContractState) -> ContractAddress;
    fn get_trove_id(self: @TContractState) -> u64;
    fn get_percentage_cap(self: @TContractState) -> Ray;
    fn get_strategies_count(self: @TContractState) -> u8;
    fn get_strategy(self: @TContractState, strategy_id: u8) -> Strategy;
    fn get_receiver(self: @TContractState) -> ContractAddress;
    fn get_live(self: @TContractState) -> bool;
    // setters
    fn initialize(
        ref self: TContractState, abbot: ContractAddress, gate: ContractAddress, asset_max: u128
    );
    fn set_percentage_cap(ref self: TContractState, cap: Ray);
    fn set_receiver(ref self: TContractState, receiver: ContractAddress);
    // core functions
    fn swap_asset_for_yin(ref self: TContractState, asset_amt: u128);
    // strategy
    fn add_strategy(ref self: TContractState, strategy_manager: ContractAddress, ceiling: u128);
    fn set_strategy_ceiling(ref self: TContractState, strategy_id: u8, ceiling: u128);
    fn execute_strategy(ref self: TContractState, strategy_id: u8, amount: u128);
    fn unwind_strategy(ref self: TContractState, strategy_id: u8, amount: u128);
    // shutdown
    fn kill(ref self: TContractState);
    fn claim(ref self: TContractState, amount: Wad);
    fn extract(ref self: TContractState, recipient: ContractAddress);
}


#[starknet::interface]
trait IStrategyManager<TContractState> {
    // getters
    fn get_deployed_amount(self: @TContractState) -> u128;
    // core functions
    fn execute(ref self: TContractState, amount: u128);
    fn unwind(ref self: TContractState, amount: u128);
}
