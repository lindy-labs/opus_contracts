use array::SpanTrait;
use starknet::ContractAddress;

use aura::utils::serde;
use aura::utils::types::{
    ExceptionalYangRedistribution, Trove, YangBalance, YangRedistribution, YangSuspensionStatus
};
use aura::utils::wadray::{Ray, Wad};

#[abi]
trait IShrine {
    // getters
    fn get_yin(user: ContractAddress) -> Wad;
    fn get_yang_total(yang: ContractAddress) -> Wad;
    fn get_initial_yang_amt(yang: ContractAddress) -> Wad;
    fn get_yangs_count() -> u32;
    fn get_deposit(yang: ContractAddress, trove_id: u64) -> Wad;
    fn get_total_debt() -> Wad;
    fn get_total_yin() -> Wad;
    fn get_yang_price(yang: ContractAddress, interval: u64) -> (Wad, Wad);
    fn get_yang_rate(yang: ContractAddress, idx: u64) -> Ray;
    fn get_debt_ceiling() -> Wad;
    fn get_multiplier(interval: u64) -> (Ray, Ray);
    fn get_yang_suspension_status(yang: ContractAddress) -> YangSuspensionStatus;
    fn get_yang_threshold(yang: ContractAddress) -> Ray;
    fn get_raw_yang_threshold(yang: ContractAddress) -> Ray;
    fn get_redistributions_count() -> u32;
    fn get_trove_redistribution_id(trove_id: u64) -> u32;
    fn get_redistribution_for_yang(
        yang: ContractAddress, redistribution_id: u32
    ) -> YangRedistribution;
    fn get_exceptional_redistribution_for_yang_to_yang(
        recipient_yang: ContractAddress, redistribution_id: u32, redistributed_yang: ContractAddress
    ) -> ExceptionalYangRedistribution;
    fn get_live() -> bool;
    // external
    fn add_yang(
        yang: ContractAddress, threshold: Ray, price: Wad, initial_rate: Ray, initial_yang_amt: Wad
    );
    fn set_debt_ceiling(new_ceiling: Wad);
    fn set_threshold(yang: ContractAddress, new_threshold: Ray);
    fn kill();
    fn advance(yang: ContractAddress, price: Wad);
    fn set_multiplier(new_multiplier: Ray);
    fn update_yin_spot_price(new_price: Wad);
    fn update_rates(yang: Span<ContractAddress>, new_rate: Span<Ray>);
    fn deposit(yang: ContractAddress, trove_id: u64, amount: Wad);
    fn withdraw(yang: ContractAddress, trove_id: u64, amount: Wad);
    fn forge(user: ContractAddress, trove_id: u64, amount: Wad, max_forge_fee_pct: Wad);
    fn melt(user: ContractAddress, trove_id: u64, amount: Wad);
    fn seize(yang: ContractAddress, trove_id: u64, amount: Wad);
    fn redistribute(trove_id: u64);
    fn inject(receiver: ContractAddress, amount: Wad);
    fn eject(burner: ContractAddress, amount: Wad);
    fn update_yang_suspension(yang: ContractAddress, ts: u64);
    // view
    fn get_shrine_threshold_and_value() -> (Ray, Wad);
    fn get_recovery_mode_threshold() -> (Ray, Ray);
    fn get_trove_info(trove_id: u64) -> (Ray, Ray, Wad, Wad);
    fn get_redistributions_attributed_to_trove(trove_id: u64) -> (Span<YangBalance>, Wad);
    fn get_current_yang_price(yang: ContractAddress) -> (Wad, Wad, u64);
    fn get_current_multiplier() -> (Ray, Ray, u64);
    fn get_yin_spot_price() -> Wad;
    fn get_forge_fee_pct() -> Wad;
    fn is_healthy(trove_id: u64) -> bool;
    fn get_max_forge(trove_id: u64) -> Wad;
}
