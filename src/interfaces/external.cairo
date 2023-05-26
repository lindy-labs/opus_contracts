use aura::utils::types::Pragma;

#[abi]
trait IPragmaOracle {
    fn get_data_median(data_type: Pragma::DataType) -> Pragma::PricesResponse;
}
