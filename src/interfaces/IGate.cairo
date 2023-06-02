use starknet::ContractAddress;

use aura::utils::wadray::Wad;

#[starknet::interface]
trait IGate<TStorage> {
    // getter
    fn get_shrine(self: @TStorage) -> ContractAddress;
    fn get_asset(self: @TStorage) -> ContractAddress;
    fn get_total_assets(self: @TStorage) -> u128;
    fn get_total_yang(self: @TStorage) -> Wad;
    fn get_asset_amt_per_yang(self: @TStorage) -> Wad;
    // external
    fn enter(ref self: TStorage, user: ContractAddress, trove_id: u64, asset_amt: u128) -> Wad;
    fn exit(ref self: TStorage, user: ContractAddress, trove_id: u64, yang_amt: Wad) -> u128;
    // view
    fn preview_enter(self: @TStorage, asset_amt: u128) -> Wad;
    fn preview_exit(self: @TStorage, yang_amt: Wad) -> u128;
}
