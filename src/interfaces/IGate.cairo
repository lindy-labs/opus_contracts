use starknet::ContractAddress;
use wadray::Wad;

#[starknet::interface]
pub trait IGate<TContractState> {
    // getter
    fn get_shrine(self: @TContractState) -> ContractAddress;
    fn get_sentinel(self: @TContractState) -> ContractAddress;
    fn get_asset(self: @TContractState) -> ContractAddress;
    fn get_total_assets(self: @TContractState) -> u128;
    fn get_total_yang(self: @TContractState) -> Wad;
    // external
    fn enter(ref self: TContractState, user: ContractAddress, asset_amt: u128) -> Wad;
    fn exit(ref self: TContractState, user: ContractAddress, yang_amt: Wad) -> u128;
    // view
    fn get_asset_amt_per_yang(self: @TContractState) -> Wad;
    fn convert_to_yang(self: @TContractState, asset_amt: u128) -> Wad;
    fn convert_to_assets(self: @TContractState, yang_amt: Wad) -> u128;
}
