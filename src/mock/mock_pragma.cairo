use opus::types::pragma::PragmaPricesResponse;

// A modified version of `PragmaPricesResponse` struct that drops `expiration_timestamp`,
// which is an `Option`. Otherwise, trying to write `expiration_timestamp` to storage
// when its value is `Option::None` causes the value of `price` to be zero.
#[derive(Copy, Drop, Serde, starknet::Store)]
struct PragmaPricesResponseWrapper {
    price: u128,
    decimals: u32,
    last_updated_timestamp: u64,
    num_sources_aggregated: u32,
}

#[starknet::interface]
pub trait IMockPragma<TContractState> {
    // Note that `get_data()` is part of `IPragmaSpotOracleDispatcher`
    fn next_get_data(ref self: TContractState, pair_id: felt252, response: PragmaPricesResponse);
    // Sets a valid price response based on price and number of sources
    fn next_get_valid_data(ref self: TContractState, pair_id: felt252, price: u128, num_sources: u32);
    // Note that `calculate_twap()` is part of `IPragmaTwapOracleDispatcher`
    fn next_calculate_twap(ref self: TContractState, pair_id: felt252, response: (u128, u32));
}

#[starknet::contract]
pub mod mock_pragma {
    use opus::constants::PRAGMA_DECIMALS;
    use opus::external::interfaces::{IPragmaSpotOracle, IPragmaTwapOracle};
    use opus::types::pragma::{AggregationMode, DataType, PragmaPricesResponse};
    use starknet::get_block_timestamp;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};
    use super::{IMockPragma, PragmaPricesResponseWrapper};

    #[storage]
    struct Storage {
        // Mapping from pair ID to price response data struct for get_data
        get_data_response: Map<felt252, PragmaPricesResponseWrapper>,
        // Mapping from pair ID to TWAP price response for calculate_twap
        calculate_twap_response: Map<felt252, (u128, u32)>,
    }

    #[abi(embed_v0)]
    impl IMockPragmaImpl of IMockPragma<ContractState> {
        fn next_get_data(ref self: ContractState, pair_id: felt252, response: PragmaPricesResponse) {
            self
                .get_data_response
                .write(
                    pair_id,
                    PragmaPricesResponseWrapper {
                        price: response.price,
                        decimals: response.decimals,
                        last_updated_timestamp: response.last_updated_timestamp,
                        num_sources_aggregated: response.num_sources_aggregated,
                    },
                );
        }

        fn next_get_valid_data(ref self: ContractState, pair_id: felt252, price: u128, num_sources: u32) {
            self
                .get_data_response
                .write(
                    pair_id,
                    PragmaPricesResponseWrapper {
                        price: price,
                        decimals: PRAGMA_DECIMALS.into(),
                        last_updated_timestamp: get_block_timestamp(),
                        num_sources_aggregated: num_sources,
                    },
                );
        }

        fn next_calculate_twap(ref self: ContractState, pair_id: felt252, response: (u128, u32)) {
            self.calculate_twap_response.write(pair_id, response);
        }
    }

    #[abi(embed_v0)]
    impl IPragmaSpotOracleImpl of IPragmaSpotOracle<ContractState> {
        fn get_data(
            self: @ContractState, data_type: DataType, aggregation_mode: AggregationMode,
        ) -> PragmaPricesResponse {
            match data_type {
                DataType::SpotEntry(pair_id) => {
                    let wrapper: PragmaPricesResponseWrapper = self.get_data_response.read(pair_id);

                    PragmaPricesResponse {
                        price: wrapper.price,
                        decimals: wrapper.decimals,
                        last_updated_timestamp: wrapper.last_updated_timestamp,
                        num_sources_aggregated: wrapper.num_sources_aggregated,
                        expiration_timestamp: Option::None,
                    }
                },
                _ => { core::panic_with_felt252('only spot') },
            }
        }
    }

    #[abi(embed_v0)]
    impl IPragmaTwapOracleImpl of IPragmaTwapOracle<ContractState> {
        fn calculate_twap(
            self: @ContractState, data_type: DataType, aggregation_mode: AggregationMode, time: u64, start_time: u64,
        ) -> (u128, u32) {
            match data_type {
                DataType::SpotEntry(pair_id) => { self.calculate_twap_response.read(pair_id) },
                _ => { core::panic_with_felt252('only spot') },
            }
        }
    }
}
