use starknet::ContractAddress;

use opus::types::Strategy;
use opus::utils::wadray::{Ray, Wad};

#[starknet::interface]
trait ITransmuter<TContractState> {
    // getters
    fn get_asset(self: @TContractState) -> ContractAddress;
    fn get_caretaker(self: @TContractState) -> ContractAddress;
    fn get_trove_id(self: @TContractState) -> u64;
    fn get_ceiling(self: @TContractState) -> u128;
    fn get_percentage_cap(self: @TContractState) -> Ray;
    fn get_strategies_count(self: @TContractState) -> u8;
    fn get_strategy(self: @TContractState, strategy_id: u8) -> Strategy;
    fn get_receiver(self: @TContractState) -> ContractAddress;
    fn get_reversibility(self: @TContractState) -> bool;
    fn get_reverse_fee(self: @TContractState) -> Ray;
    fn get_live(self: @TContractState) -> bool;
    // setters
    fn initialize(ref self: TContractState, gate: ContractAddress, ceiling: u128) -> u64;
    fn set_caretaker(ref self: TContractState, caretaker: ContractAddress);
    fn set_ceiling(ref self: TContractState, ceiling: u128);
    fn set_percentage_cap(ref self: TContractState, cap: Ray);
    fn set_receiver(ref self: TContractState, receiver: ContractAddress);
    fn toggle_reversibility(ref self: TContractState);
    fn set_reverse_fee(ref self: TContractState, fee: Ray);
    // core functions
    fn transmute(ref self: TContractState, asset_amt: u128);
    fn reverse(ref self: TContractState, yin_amt: Wad);
    fn sweep(ref self: TContractState);
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
    // core functions
    fn execute(ref self: TContractState, execute_amt: u128);
    fn unwind(ref self: TContractState, deployed_amt: u128, unwind_amt: u128);
}
