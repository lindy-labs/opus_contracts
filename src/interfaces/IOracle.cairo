#[starknet::interface]
trait IOracle<TContractState> {
    // external
    fn update_prices(ref self: TContractState);
}
