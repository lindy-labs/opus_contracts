use aura::utils::types::Pragma;

#[starknet::interface]
trait IPragmaOracle<TContractState> {
    fn get_data_median(
        self: @TContractState, data_type: Pragma::DataType
    ) -> Pragma::PricesResponse;
}
