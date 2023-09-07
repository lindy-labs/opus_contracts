use starknet::ContractAddress;

#[starknet::interface]
trait IPragma<TContractState> {
    fn set_oracle(ref self: TContractState, new_oracle: ContractAddress);
    fn set_price_validity_thresholds(ref self: TContractState, freshness: u64, sources: u64);
    fn set_update_frequency(ref self: TContractState, new_frequency: u64);
    fn add_yang(ref self: TContractState, pair_id: u256, yang: ContractAddress);
    fn probe_task(self: @TContractState) -> bool;
}
