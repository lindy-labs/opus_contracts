use starknet::ContractAddress;

#[starknet::interface]
trait IPragma<TStorage> {
    fn set_oracle(ref self: TStorage, new_oracla: ContractAddress);
    fn set_price_validity_thresholds(ref self: TStorage, freshness: u64, sources: u64);
    fn set_update_frequency(ref self: TStorage, new_frequency: u64);
    fn add_yang(ref self: TStorage, pragma_id: felt252, yang: ContractAddress);
}
