use aura::utils::types::Pragma::{DataType, PricesResponse};

#[abi]
trait IMockPragma {
    fn next_get_data_median(pair_id: u256, price_response: PricesResponse);
// Note that `get_data_median()` is part of the `IPragmaOracleDispatcher`
}

#[contract]
mod MockPragma {
    use aura::utils::types::Pragma::{DataType, PricesResponse};

    struct Storage {
        // Mapping from pair ID to price response data struct
        price_response: LegacyMap::<u256, PricesResponse>,
    }

    #[external]
    fn next_get_data_median(pair_id: u256, price_response: PricesResponse) {
        price_response::write(pair_id, price_response);
    }

    #[external]
    fn get_data_median(data_type: DataType) -> PricesResponse {
        match data_type {
            DataType::Spot(pair_id) => {
                price_response::read(pair_id)
            },
            DataType::Future(pair_id) => {
                price_response::read(pair_id)
            },
            DataType::Generic(pair_id) => {
                price_response::read(pair_id)
            }
        }
    }
}
