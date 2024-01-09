use opus::types::pragma;

#[starknet::interface]
trait IPragmaOracle<TContractState> {
    // getters
    fn get_data_median(self: @TContractState, data_type: pragma::DataType) -> pragma::PragmaPricesResponse;
}

#[starknet::interface]
trait ISummaryStatsABI<TContractState> {
    fn calculate_twap(
        self: @TContractState,
        data_type: pragma::DataType,
        aggregation_mode: pragma::AggregationMode,
        time: u64,
        start_time: u64,
    ) -> (u128, u32);
}

#[starknet::interface]
trait ITask<TContractState> {
    fn probe_task(self: @TContractState) -> bool;
    fn execute_task(ref self: TContractState);
}
