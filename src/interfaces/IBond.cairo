use starknet::ContractAddress;

use opus::types::BondStatus;
use opus::utils::wadray::{Ray, Wad};

#[starknet::interface]
trait IBond<TContractState> {
    // getters
    fn get_equalizer(self: @TContractState) -> ContractAddress;
    fn get_liquidator(self: @TContractState) -> ContractAddress;
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
    fn set_equalizer(ref self: TContractState, equalizer: ContractAddress);
    fn set_liquidator(ref self: TContractState, liquidator: ContractAddress);
    fn set_ceiling(ref self: TContractState, ceiling: Wad);
    fn set_price(ref self: TContractState, price: Wad);
    fn set_rate(ref self: TContractState, rate: Ray);
    fn set_threshold(ref self: TContractState, threshold: Ray);
    fn add_asset(ref self: TContractState, asset: ContractAddress);
    // core functions
    fn borrow(ref self: TContractState, yin_amt: Wad);
    fn repay(ref self: TContractState);
    fn charge(ref self: TContractState);
    fn liquidate(ref self: TContractState);
    fn settle(ref self: TContractState, recipient: ContractAddress);
    fn close(ref self: TContractState, recipient: ContractAddress);
    // shutdown
    fn kill(ref self: TContractState);
    fn reclaim(ref self: TContractState, amount: Wad);
}

