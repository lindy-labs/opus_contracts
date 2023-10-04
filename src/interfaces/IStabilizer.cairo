use starknet::ContractAddress;

#[starknet::interface]
trait IStabilizer<TContractState> {
    fn initialize(ref self: TContractState, gate: ContractAddress, asset_max: u128);
    fn swap_asset_for_yin(ref self: TContractState, asset_amt: u128);
    // strategy
    fn add_strategy(ref self: TContractState, strategy: ContractAddress);
    fn execute_strategy(ref self: TContractState, strategy: ContractAddress, amount: u128);
    fn unwind_strategy(ref self: TContractState, strategy: ContractAddress, amount: u128);
    // shutdown
    fn kill(ref self: TContractState);
    fn claim(ref self: TContractState, amount: u128);
    fn extract(ref self: TContractState, recipient: ContractAddress);
}


#[starknet::interface]
trait IStabilizerStrategy<TContractState> {
    fn execute(ref self: TContractState, amount: u128);
    fn unwind(ref self: TContractState, amount: u128);
}
