#[starknet::interface]
trait IMockTwapPragma<TContractState> {
    // Note that `calculate_twap()` is part of `ISummaryStatsABIDispatcher`
    fn next_calculate_twap(ref self: TContractState, pair_id: felt252, price: u128, decimals: u32);
}

#[starknet::contract]
mod mock_twap_pragma {
    use opus::interfaces::external::ISummaryStatsABI;
    use opus::types::pragma::{DataType, AggregationMode};
    use super::IMockTwapPragma;

    #[storage]
    struct Storage {
        // Mapping from pair ID to price and decimals
        twap_price_info: LegacyMap::<felt252, (u128, u32)>,
    }

    #[abi(embed_v0)]
    impl IMockTwapPragmaImpl of IMockTwapPragma<ContractState> {
        fn next_calculate_twap(ref self: ContractState, pair_id: felt252, price: u128, decimals: u32) {
            self.twap_price_info.write(pair_id, (price, decimals));
        }
    }

    #[abi(embed_v0)]
    impl ISummaryStatsABIImpl of ISummaryStatsABI<ContractState> {
        fn calculate_twap(
            self: @ContractState, data_type: DataType, aggregation_mode: AggregationMode, time: u64, start_time: u64
        ) -> (u128, u32) {
            match data_type {
                DataType::SpotEntry(pair_id) => { self.twap_price_info.read(pair_id) },
                DataType::FutureEntry(_) => { panic_with_felt252('only spot') },
                DataType::GenericEntry(_) => { panic_with_felt252('only spot') },
            }
        }
    }
}
