use array::SpanTrait;
use starknet::ContractAddress;

use aura::utils::serde;
use aura::utils::types::Trove;
use aura::utils::wadray::{Ray, Wad};

#[starknet::interface]
trait IShrine<TStorage> {
    // getters
    fn get_yin(self: @TStorage, user: ContractAddress) -> Wad;
    fn get_yang_total(self: @TStorage, yang: ContractAddress) -> Wad;
    fn get_yangs_count(self: @TStorage) -> u32;
    fn get_deposit(self: @TStorage, yang: ContractAddress, trove_id: u64) -> Wad;
    fn get_total_debt(self: @TStorage) -> Wad;
    fn get_total_yin(self: @TStorage) -> Wad;
    fn get_yang_price(self: @TStorage, yang: ContractAddress, interval: u64) -> (Wad, Wad);
    fn get_yang_rate(self: @TStorage, yang: ContractAddress, idx: u64) -> Ray;
    fn get_debt_ceiling(self: @TStorage) -> Wad;
    fn get_multiplier(self: @TStorage, interval: u64) -> (Ray, Ray);
    fn get_yang_threshold(self: @TStorage, yang: ContractAddress) -> Ray;
    fn get_redistributions_count(self: @TStorage) -> u64;
    fn get_trove_redistribution_id(self: @TStorage, trove_id: u64) -> u32;
    fn get_redistributed_unit_debt_for_yang(
        self: @TStorage, yang: ContractAddress, redistribution_id: u32
    ) -> Wad;
    fn get_live(self: @TStorage) -> bool;
    // external
    fn add_yang(
        ref self: TStorage,
        yang: ContractAddress,
        threshold: Ray,
        price: Wad,
        initial_rate: Ray,
        initial_yang_amt: Wad
    );
    fn set_debt_ceiling(ref self: TStorage, new_ceiling: Wad);
    fn set_threshold(ref self: TStorage, yang: ContractAddress, new_threshold: Ray);
    fn kill(ref self: TStorage);
    fn advance(ref self: TStorage, yang: ContractAddress, price: Wad);
    fn set_multiplier(ref self: TStorage, new_multiplier: Ray);
    fn update_rates(ref self: TStorage, yang: Span<ContractAddress>, new_rate: Span<Ray>);
    fn deposit(ref self: TStorage, yang: ContractAddress, trove_id: u64, amount: Wad);
    fn withdraw(ref self: TStorage, yang: ContractAddress, trove_id: u64, amount: Wad);
    fn forge(ref self: TStorage, user: ContractAddress, trove_id: u64, amount: Wad);
    fn melt(ref self: TStorage, user: ContractAddress, trove_id: u64, amount: Wad);
    fn seize(ref self: TStorage, yang: ContractAddress, trove_id: u64, amount: Wad);
    fn redistribute(ref self: TStorage, trove_id: u64);
    fn inject(ref self: TStorage, receiver: ContractAddress, amount: Wad);
    fn eject(ref self: TStorage, burner: ContractAddress, amount: Wad);
    // view
    fn get_shrine_threshold_and_value(self: @TStorage) -> (Ray, Wad);
    fn get_trove_info(self: @TStorage, trove_id: u64) -> (Ray, Ray, Wad, Wad);
    fn get_current_yang_price(self: @TStorage, yang: ContractAddress) -> (Wad, Wad, u64);
    fn get_current_multiplier(self: @TStorage) -> (Ray, Ray, u64);
    fn is_healthy(self: @TStorage, trove_id: u64) -> bool;
    fn get_max_forge(self: @TStorage, trove_id: u64) -> Wad;
}
