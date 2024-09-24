use opus::types::pragma;
use starknet::ContractAddress;

#[starknet::interface]
pub trait IEkuboOracleExtension<TContractState> {
    // Returns the geomean average price of a token as a 128.128 between the given start and end
    // time
    fn get_price_x128_over_period(
        self: @TContractState, base_token: ContractAddress, quote_token: ContractAddress, start_time: u64, end_time: u64
    ) -> u256;
}

#[starknet::interface]
pub trait IPragmaSpotOracle<TContractState> {
    fn get_data_median(self: @TContractState, data_type: pragma::DataType) -> pragma::PragmaPricesResponse;
}

#[starknet::interface]
pub trait IPragmaTwapOracle<TContractState> {
    fn calculate_twap(
        self: @TContractState,
        data_type: pragma::DataType,
        aggregation_mode: pragma::AggregationMode,
        time: u64,
        start_time: u64
    ) -> (u128, u32);
}

#[starknet::interface]
pub trait ITask<TContractState> {
    fn probe_task(self: @TContractState) -> bool;
    fn execute_task(ref self: TContractState);
}

#[starknet::interface]
pub trait ISwitchboardOracle<TContractState> {
    // returns latest price and timestamp values for the given pair
    fn get_latest_result(self: @TContractState, pair_id: felt252) -> (u128, u64);
}
