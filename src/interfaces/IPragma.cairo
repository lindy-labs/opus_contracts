use starknet::ContractAddress;

#[starknet::interface]
trait IPragma<TContractState> {
    fn add_yang(ref self: TContractState, yang: ContractAddress, pair_id: u256,);
    fn set_price_validity_thresholds(ref self: TContractState, freshness: u64, sources: u64);
}
