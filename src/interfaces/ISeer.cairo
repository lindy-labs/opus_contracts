use opus::types::PriceType;
use starknet::ContractAddress;

#[starknet::interface]
pub trait ISeer<TContractState> {
    fn get_oracles(self: @TContractState) -> Span<ContractAddress>;
    fn get_update_frequency(self: @TContractState) -> u64;
    fn get_yang_price_type(self: @TContractState, yang: ContractAddress) -> PriceType;
    fn set_oracles(ref self: TContractState, oracles: Span<ContractAddress>);
    fn set_update_frequency(ref self: TContractState, new_frequency: u64);
    fn set_yang_price_type(ref self: TContractState, yang: ContractAddress, price_type: PriceType);
    fn update_prices(ref self: TContractState);
}
