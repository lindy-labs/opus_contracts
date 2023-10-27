use starknet::ContractAddress;

use opus::types::BondStatus;
use opus::utils::wadray::{Ray, Wad};

#[starknet::interface]
trait IBond<TContractState> {
    // getters
    fn get_assets_count(self: @TContractState) -> u8;
    fn get_assets(self: @TContractState) -> Span<ContractAddress>;
    fn get_ceiling(self: @TContractState) -> Wad;
    fn get_price(self: @TContractState) -> Wad;
    fn get_rate(self: @TContractState) -> Ray;
    fn get_threshold(self: @TContractState) -> Ray;
    fn get_borrowed(self: @TContractState) -> Wad;
    fn get_status(self: @TContractState) -> BondStatus;
    // view
    fn is_healthy(self: @TContractState) -> bool;
    // setters
    fn set_ceiling(ref self: TContractState, ceiling: Wad);
    fn set_price(ref self: TContractState, price: Wad);
    fn set_rate(ref self: TContractState, rate: Ray);
    fn set_threshold(ref self: TContractState, threshold: Ray);
    fn add_asset(ref self: TContractState, asset: ContractAddress);
    // core functions
    fn borrow(ref self: TContractState, yin_amt: Wad);
    fn repay(ref self: TContractState);
    fn charge(ref self: TContractState);
    fn liquidate(ref self: TContractState, recipient: ContractAddress);
    fn settle(ref self: TContractState, recipient: ContractAddress);
    fn close(ref self: TContractState, recipient: ContractAddress);
    // shutdown
    fn kill(ref self: TContractState, recipient: ContractAddress);
    fn reclaim(ref self: TContractState, amount: Wad);
}

#[starknet::interface]
trait IBondRegistry<TContractState> {
    // getters
    fn get_bonds_count(self: @TContractState) -> u32;
    fn get_bonds(self: @TContractState) -> Span<ContractAddress>;
    // setters
    fn add_bond(ref self: TContractState, bond: ContractAddress);
    fn remove_bond(ref self: TContractState, bond: ContractAddress);
}
