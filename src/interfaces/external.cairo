use opus::types::pragma;

#[starknet::interface]
trait IPragmaOracle<TContractState> {
    // getters
    fn get_data_median(self: @TContractState, data_type: pragma::DataType) -> pragma::PricesResponse;
}

// TODO: currently a made up interface modelled after
//       Yagi v0; fix up
#[starknet::interface]
trait IYagi<TContractState> {
    fn probe_task(self: @TContractState) -> bool;
    fn execute_task(ref self: TContractState);
}
