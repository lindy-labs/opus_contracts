use starknet::ContractAddress;

#[starknet::interface]
pub trait IMockEkuboOracleExtension<TContractState> {
    // Timestamps are ignored
    fn next_get_price_x128_over_last(
        ref self: TContractState, base_token: ContractAddress, quote_token: ContractAddress, price: u256
    );
}

#[starknet::contract]
pub mod mock_ekubo_oracle_extension {
    use opus::external::interfaces::IEkuboOracleExtension;
    use starknet::ContractAddress;
    use super::IMockEkuboOracleExtension;

    #[storage]
    struct Storage {
        // Mapping from (base token, quote token) to x128 price
        price: LegacyMap::<(ContractAddress, ContractAddress), u256>,
    }

    #[abi(embed_v0)]
    impl IMockEkuboOracleExtensionImpl of IMockEkuboOracleExtension<ContractState> {
        fn next_get_price_x128_over_last(
            ref self: ContractState, base_token: ContractAddress, quote_token: ContractAddress, price: u256
        ) {
            self.price.write((base_token, quote_token), price);
        }
    }

    #[abi(embed_v0)]
    impl IEkuboOracleExtensionImpl of IEkuboOracleExtension<ContractState> {
        fn get_price_x128_over_last(
            self: @ContractState, base_token: ContractAddress, quote_token: ContractAddress, period: u64
        ) -> u256 {
            self.price.read((base_token, quote_token))
        }
    }
}
