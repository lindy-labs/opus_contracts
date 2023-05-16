use array::ArrayTrait;
use starknet::ContractAddress;

use aura::utils::wadray::{Ray, Wad};

#[abi]
trait ISentinel {
    // View
    fn get_gate_address(yang: ContractAddress) -> ContractAddress;
    fn get_yang_addresses() -> Array<ContractAddress>;
    fn get_yang_addresses_count() -> u64;
    fn get_yang(idx: u64) -> ContractAddress;
    fn get_yang_asset_max(yang: ContractAddress) -> u128;
    fn get_asset_amt_per_yang(yang: ContractAddress) -> Wad;
    fn preview_enter(yang: ContractAddress, asset_amt: u128) -> Wad;
    fn preview_exit(yang: ContractAddress, yang_amt: Wad) -> u128;
    // External
    fn add_yang(
        yang: ContractAddress,
        yang_max: Wad,
        yang_threshold: Ray,
        yang_price: Wad,
        gate: ContractAddress
    );
    fn set_yang_asset_max(yang: ContractAddress, new_asset_max: u128);
    fn enter(yang: ContractAddress, user: ContractAddress, trove_id: u64, asset_amt: u128) -> Wad;
    fn exit(yang: ContractAddress, user: ContractAddress, trove_id: u64, yang_amt: Wad) -> u128;
}
