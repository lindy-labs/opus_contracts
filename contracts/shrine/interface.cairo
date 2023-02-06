%lang starknet

from contracts.lib.aliases import address, bool, ray, ufelt, wad
from contracts.lib.types import Trove

@contract_interface
namespace IShrine {
    //
    // getters
    //
    func get_trove(trove_id) -> (trove: Trove) {
    }

    func get_yin(user: address) -> (balance: wad) {
    }

    func get_yang_total(yang: address) -> (total: wad) {
    }

    func get_yangs_count() -> (count: ufelt) {
    }

    func get_deposit(yang: address, trove_id: ufelt) -> (balance: wad) {
    }

    func get_total_debt() -> (total_debt: wad) {
    }

    func get_total_yin() -> (total_yin: wad) {
    }

    func get_yang_price(yang: address, interval) -> (price: wad, cumulative_price: wad) {
    }

    func get_ceiling() -> (ceiling: wad) {
    }

    func get_multiplier(interval: ufelt) -> (multiplier: ray, cumulative_multiplier: ray) {
    }

    func get_yang_threshold(yang: address) -> (threshold: ray) {
    }

    func get_redistributions_count() -> (count: ufelt) {
    }

    func get_trove_redistribution_id(trove_id: ufelt) -> (redistribution_id: ufelt) {
    }

    func get_redistributed_unit_debt_for_yang(yang: address, redistribution_id: ufelt) -> (
        unit_debt: wad
    ) {
    }

    func get_live() -> (is_live: bool) {
    }

    //
    // external
    //
    func add_yang(yang: address, threshold: ray, price: wad) {
    }

    func set_yang_max(yang: address, new_max: wad) {
    }

    func set_ceiling(new_ceiling: wad) {
    }

    func set_threshold(yang: address, new_threshold: wad) {
    }

    func kill() {
    }

    func advance(yang: address, price: wad) {
    }

    func set_multiplier(new_multiplier: ray) {
    }

    func move_yang(yang: address, src_trove_id: ufelt, dst_trove_id: ufelt, amount: wad) {
    }

    func deposit(yang: address, trove_id: ufelt, amount: wad) {
    }

    func withdraw(yang: address, trove_id: ufelt, amount: wad) {
    }

    func forge_with_trove(user: address, trove_id: ufelt, amount: wad) {
    }

    func melt_with_trove(user: address, trove_id: ufelt, amount: wad) {
    }

    func seize(yang: address, trove_id: ufelt, amount: wad) {
    }

    func redistribute(trove_id: ufelt) {
    }

    func forge_without_trove(receiver: address, amount: wad) {
    }

    func melt_without_trove(receiver: address, amount: wad) {
    }

    //
    // view
    //
    func get_trove_info(trove_id: ufelt) -> (threshold: ray, ltv: ray, value: wad, debt: wad) {
    }

    func get_current_yang_price(yang: address) -> (
        price: wad, cumulative_price: wad, interval: ufelt
    ) {
    }

    func get_current_multiplier() -> (
        multiplier: ray, cumulative_multiplier: ray, interval: ufelt
    ) {
    }

    func is_healthy(trove_id: ufelt) -> (healthy: bool) {
    }

    func get_max_forge(trove_id: ufelt) -> (max: wad) {
    }
}
