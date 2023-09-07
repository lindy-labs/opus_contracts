use starknet::ContractAddress;

#[abi]
trait IPragma {
    fn set_oracle(new_oracla: ContractAddress);
    fn set_price_validity_thresholds(freshness: u64, sources: u64);
    fn set_update_frequency(new_frequency: u64);
    fn add_yang(pair_id: u256, yang: ContractAddress);
    fn probe_task() -> bool;
}
