use starknet::ContractAddress;

#[abi]
trait IPragma {
    fn set_oracle(new_oracla: ContractAddress);
    fn set_price_validity_thresholds(freshness: u64, sources: u64);
    fn set_update_interval(new_interval: u64);
    fn add_yang(pragma_id: felt252, yang: ContractAddress);
}
