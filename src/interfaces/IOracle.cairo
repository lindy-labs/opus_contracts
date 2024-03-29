use starknet::ContractAddress;
use wadray::Wad;

#[starknet::interface]
pub trait IOracle<TContractState> {
    // human readable identifier
    fn get_name(self: @TContractState) -> felt252;

    fn get_oracles(self: @TContractState) -> Span<ContractAddress>;

    // has to be ref self to allow emitting events from the function
    fn fetch_price(ref self: TContractState, yang: ContractAddress) -> Result<Wad, felt252>;
}
