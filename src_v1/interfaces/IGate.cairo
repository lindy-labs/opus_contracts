use starknet::ContractAddress;

use aura::utils::wadray::Wad;

#[abi]
trait IGate {
    // getter
    fn get_shrine() -> ContractAddress;
    fn get_sentinel() -> ContractAddress;
    fn get_asset() -> ContractAddress;
    fn get_total_assets() -> u128;
    fn get_total_yang() -> Wad;
    fn get_asset_amt_per_yang() -> Wad;
    // external
    fn enter(user: ContractAddress, trove_id: u64, asset_amt: u128) -> Wad;
    fn exit(user: ContractAddress, trove_id: u64, yang_amt: Wad) -> u128;
    // view
    fn convert_to_yang(asset_amt: u128) -> Wad;
    fn convert_to_assets(yang_amt: Wad) -> u128;
}
