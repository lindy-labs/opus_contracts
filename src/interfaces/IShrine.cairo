use starknet::ContractAddress;

use aura::utils::types::Trove;
use aura::utils::wadray::Ray;
use aura::utils::wadray::Wad;

#[abi]
trait IShrine {
    // getters
    fn get_trove(trove_id: u64) -> Trove;
    fn get_yin(user: ContractAddress) -> Wad;
    fn get_yang_total(yang: ContractAddress) -> Wad;
    fn get_yangs_count() -> u64;
    fn get_deposit(yang: ContractAddress, trove_id: u64) -> Wad;
    fn get_total_debt() -> Wad;
    fn get_total_yin() -> Wad;
    fn get_yang_price(yang: ContractAddress, interval: u64) -> (Wad, Wad);
    fn get_ceiling() -> Wad;
    fn get_multiplier(interval: u64) -> (Ray, Ray);
    fn get_yang_threshold(yang: ContractAddress) -> Ray;
    fn get_redistributions_count() -> u64;
    fn get_trove_redistribution_id(trove_id: u64) -> u64;
    fn get_redistributed_unit_debt_for_yang(yang: ContractAddress, redistribution_id: u64) -> Wad;
    fn get_live() -> bool;
    // external
    fn add_yang(
        yang: ContractAddress, threshold: Ray, price: Wad, initial_rate: Ray, initial_yang_amt: Wad
    );
    fn set_yang_max(yang: ContractAddress, new_max: Wad);
    fn set_ceiling(new_ceiling: Wad);
    fn set_threshold(yang: ContractAddress, new_threshold: Wad);
    fn kill();
    fn advance(yang: ContractAddress, price: Wad);
    fn set_multiplier(new_multiplier: Ray);
    fn move_yang(yang: ContractAddress, src_trove_id: u64, dst_trove_id: u64, amount: Wad);
    fn deposit(yang: ContractAddress, trove_id: u64, amount: Wad);
    fn withdraw(yang: ContractAddress, trove_id: u64, amount: Wad);
    fn forge(user: ContractAddress, trove_id: u64, amount: Wad);
    fn melt(user: ContractAddress, trove_id: u64, amount: Wad);
    fn seize(yang: ContractAddress, trove_id: u64, amount: Wad);
    fn redistribute(trove_id: u64);
    fn inject(receiver: ContractAddress, amount: Wad);
    fn eject(receiver: ContractAddress, amount: Wad);
    // view
    fn get_shrine_threshold_and_value() -> (Ray, Wad);
    fn get_trove_info(trove_id: u64) -> (Ray, Ray, Wad, Wad);
    fn get_current_yang_price(yang: ContractAddress) -> (Wad, Wad, u64);
    fn get_current_multiplier() -> (Ray, Ray, u64);
    fn is_healthy(trove_id: u64) -> bool;
    fn get_max_forge(trove_id: u64) -> Wad;
}
