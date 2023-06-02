#[starknet::interface]
trait IOracle<TStorage> {
    fn update_prices(ref self: TStorage);
}
