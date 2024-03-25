#[starknet::interface]
pub trait IMockSwitchboard<TContractState> {
    fn next_get_latest_result(ref self: TContractState, pair_id: felt252, price: u128, timestamp: u64);
}

#[starknet::contract]
pub mod mock_switchboard {
    use opus::interfaces::external::ISwitchboardOracle;
    use super::IMockSwitchboard;

    #[storage]
    struct Storage {
        next_result: LegacyMap<felt252, (u128, u64)>
    }

    #[abi(embed_v0)]
    impl IMockSwitchboardImpl of IMockSwitchboard<ContractState> {
        fn next_get_latest_result(ref self: ContractState, pair_id: felt252, price: u128, timestamp: u64) {
            self.next_result.write(pair_id, (price, timestamp));
        }
    }

    #[abi(embed_v0)]
    impl ISwitchboardOracleImpl of ISwitchboardOracle<ContractState> {
        fn get_latest_result(self: @ContractState, pair_id: felt252) -> (u128, u64) {
            self.next_result.read(pair_id)
        }
    }
}
