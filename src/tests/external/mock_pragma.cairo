#[contract]
mod MockPragma {
    use aura::utils::types::Pragma::{DataType, PricesResponse};

    struct Storage {
        // Mapping from pair ID to price response data struct
        price_response: LegacyMap::<u256, PricesResponse>,
    }

    #[external]
    fn next_get_data_median(pair_id: u256, price_response: PricesResponse, ) {
        price_response::write(pair_id, price_response);
    }

    #[external]
    fn get_data_median(data_type: DataType) -> PricesResponse {
        match data_type {
            DataType::Spot(pair_id) => {
                price_response::read(pair_id)
            },
            DataType::Future(pair_id) => {
                panic_with_felt252('only spot');
                price_response::read(pair_id) // unreachable
            },
            DataType::Generic(pair_id) => {
                panic_with_felt252('only spot');
                price_response::read(pair_id) // unreachable
            }
        }
    }
}
