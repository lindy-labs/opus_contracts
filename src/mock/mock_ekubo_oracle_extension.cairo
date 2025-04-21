use starknet::ContractAddress;

#[starknet::interface]
pub trait IMockEkuboOracleExtension<TContractState> {
    // Timestamps are ignored
    fn next_get_price_x128_over_last(
        ref self: TContractState, base_token: ContractAddress, quote_token: ContractAddress, price: u256,
    );
}

#[starknet::contract]
pub mod mock_ekubo_oracle_extension {
    use opus::external::interfaces::IEkuboOracleExtension;
    use starknet::ContractAddress;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};
    use super::IMockEkuboOracleExtension;

    #[storage]
    struct Storage {
        // Mapping from (base token, quote token) to x128 price
        price: Map<(ContractAddress, ContractAddress), u256>,
    }

    #[abi(embed_v0)]
    impl IMockEkuboOracleExtensionImpl of IMockEkuboOracleExtension<ContractState> {
        fn next_get_price_x128_over_last(
            ref self: ContractState, base_token: ContractAddress, quote_token: ContractAddress, price: u256,
        ) {
            self.price.write((base_token, quote_token), price);
        }
    }

    #[abi(embed_v0)]
    impl IEkuboOracleExtensionImpl of IEkuboOracleExtension<ContractState> {
        fn get_price_x128_over_last(
            self: @ContractState, base_token: ContractAddress, quote_token: ContractAddress, period: u64,
        ) -> u256 {
            self.price.read((base_token, quote_token))
        }
    }
}


pub fn set_next_ekubo_prices(
    mock_ekubo_oracle_extension: IMockEkuboOracleExtensionDispatcher,
    base_token: ContractAddress,
    quote_tokens: Span<ContractAddress>,
    mut prices: Span<u256>,
) {
    assert(quote_tokens.len() == prices.len(), 'unequal len');

    for quote_token in quote_tokens {
        mock_ekubo_oracle_extension
            .next_get_price_x128_over_last(base_token, *quote_token, *prices.pop_front().unwrap());
    }
}
