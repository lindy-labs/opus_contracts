use aura::types::Pragma;

#[starknet::interface]
trait IPragmaOracle<TContractState> {
    // getters
    fn get_data_median(
        self: @TContractState, data_type: Pragma::DataType
    ) -> Pragma::PricesResponse;
}
