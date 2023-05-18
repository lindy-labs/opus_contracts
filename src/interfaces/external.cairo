#[abi]
trait IPragmaOracle {
    // returns value, decimals, last updated timestamp and number of sources aggregated
    // https://docs.pragmaoracle.com/docs/starknet/data-feeds/consuming-data#function-get_spot_median
    fn get_spot_median(pragma_id: felt252) -> (felt252, felt252, u64, u64);
}

// TODO: is this needed?
#[abi]
trait Yagi {
    fn probe_task() -> bool;
    fn execute_task();
}
