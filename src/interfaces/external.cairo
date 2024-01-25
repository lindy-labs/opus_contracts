use opus::types::pragma;

#[starknet::interface]
pub trait IPragmaOracle<TContractState> {
    // getters
    fn get_data_median(self: @TContractState, data_type: pragma::DataType) -> pragma::PragmaPricesResponse;
}

#[starknet::interface]
pub trait ITask<TContractState> {
    fn probe_task(self: @TContractState) -> bool;
    fn execute_task(ref self: TContractState);
}

pub trait ISwitchboardOracle<TContractState> {}
