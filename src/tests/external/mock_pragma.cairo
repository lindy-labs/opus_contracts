use opus::types::pragma::PricesResponse;

#[starknet::interface]
trait IMockPragma<TContractState> {
    // Note that `get_data_median()` is part of `IPragmaOracleDispatcher`
    fn next_get_data_median(
        ref self: TContractState, pair_id: u256, price_response: PricesResponse
    );
}

#[starknet::contract]
mod mock_pragma {
    use opus::interfaces::external::IPragmaOracle;
    use opus::types::pragma::{DataType, PricesResponse};
    use super::IMockPragma;

    #[storage]
    struct Storage {
        // Mapping from pair ID to price response data struct
        price_response: LegacyMap::<u256, PricesResponse>,
    }

    #[abi(embed_v0)]
    impl IMockPragmaImpl of IMockPragma<ContractState> {
        fn next_get_data_median(
            ref self: ContractState, pair_id: u256, price_response: PricesResponse
        ) {
            self.price_response.write(pair_id, price_response);
        }
    }

    #[abi(embed_v0)]
    impl IPragmaOracleImpl of IPragmaOracle<ContractState> {
        fn get_data_median(self: @ContractState, data_type: DataType) -> PricesResponse {
            match data_type {
                DataType::Spot(pair_id) => { self.price_response.read(pair_id) },
                DataType::Future(pair_id) => { self.price_response.read(pair_id) },
                DataType::Generic(pair_id) => { self.price_response.read(pair_id) }
            }
        }
    }
}
