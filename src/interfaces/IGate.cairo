#[abi]
trait IGate {
    // getters
    fn get_live() -> bool;
    fn get_shrine() -> ContractAddress;
    fn get_asset() -> ContractAddress;
    // external
    fn enter(user: ContractAddress, trove_id: u64, asset_amt: u64) -> Wad;
    fn exit(user: ContractAddress, trove_id: u64, yang_amt: Wad) -> u64;
    fn kill();
    // view
    fn get_total_assets() -> u64;
    fn get_total_yang() -> Wad;
    fn get_asset_amt_per_yang() -> Wad;
    fn preview_enter(asset_amt: u64) -> Wad;
    fn preview_exit(yang_amt: Wad) -> u64;
}
