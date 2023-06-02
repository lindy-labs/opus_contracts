use array::SpanTrait;
use starknet::ContractAddress;

use aura::utils::serde::SpanSerde;
use aura::utils::wadray::{Ray, Wad};

#[starknet::interface]
trait ISentinel<TStorage> {
    // View
    fn get_gate_address(self: @TStorage, yang: ContractAddress) -> ContractAddress;
    fn get_gate_live(self: @TStorage, yang: ContractAddress) -> bool;
    fn get_yang_addresses(self: @TStorage) -> Span<ContractAddress>;
    fn get_yang_addresses_count(self: @TStorage) -> u64;
    fn get_yang(self: @TStorage, idx: u64) -> ContractAddress;
    fn get_yang_asset_max(self: @TStorage, yang: ContractAddress) -> u128;
    fn get_asset_amt_per_yang(self: @TStorage, yang: ContractAddress) -> Wad;
    fn preview_enter(self: @TStorage, yang: ContractAddress, asset_amt: u128) -> Wad;
    fn preview_exit(self: @TStorage, yang: ContractAddress, yang_amt: Wad) -> u128;
    // External
    fn add_yang(
        ref self: TStorage,
        yang: ContractAddress,
        yang_asset_max: u128,
        yang_threshold: Ray,
        yang_price: Wad,
        yang_rate: Ray,
        gate: ContractAddress
    );
    fn set_yang_asset_max(ref self: TStorage, yang: ContractAddress, new_asset_max: u128);
    fn enter(
        ref self: TStorage,
        yang: ContractAddress,
        user: ContractAddress,
        trove_id: u64,
        asset_amt: u128
    ) -> Wad;
    fn exit(
        ref self: TStorage,
        yang: ContractAddress,
        user: ContractAddress,
        trove_id: u64,
        yang_amt: Wad
    ) -> u128;
    fn kill_gate(ref self: TStorage, yang: ContractAddress);
}
