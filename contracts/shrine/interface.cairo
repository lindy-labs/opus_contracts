%lang starknet

from contracts.shared.types import Trove, Yang
from contracts.shared.aliases import wad, ray, bool, ufelt, address

@contract_interface
namespace IShrine {
    //
    // getters
    //
    func get_trove(trove_id) -> (trove: Trove) {
    }

    func get_yin(user: address) -> (balance: wad) {
    }

    func get_yang(yang: address) -> (yang: Yang) {
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

    func get_threshold(yang: address) -> (threshold: ray) {
    }

    func get_live() -> (is_live: bool) {
    }

    //
    // external
    //
    func add_yang(yang: address, max: wad, threshold: ray, price: wad) {
    }

    func update_yang_max(yang: address, new_max: wad) {
    }

    func set_ceiling(new_ceiling: wad) {
    }

    func set_threshold(yang: address, new_threshold: wad) {
    }

    func kill() {
    }

    func advance(yang: address, price: wad) {
    }

    func update_multiplier(new_multiplier: ray) {
    }

    func move_yang(yang: address, src_trove_id: ufelt, dst_trove_id: ufelt, amount: wad) {
    }

    func move_yin(src: address, dst: address, amount: wad) {
    }

    func deposit(yang: address, trove_id: ufelt, amount: wad) {
    }

    func withdraw(yang: address, trove_id: ufelt, amount: wad) {
    }

    func forge(user: address, trove_id: ufelt, amount: wad) {
    }

    func melt(user: address, trove_id: ufelt, amount: wad) {
    }

    func seize(yang: address, trove_id: ufelt, amount: wad) {
    }

    //
    // view
    //
    func get_trove_threshold(trove_id: ufelt) -> (threshold: ray, value: wad) {
    }

    func get_current_trove_ltv(trove_id: ufelt) -> (ltv: ray) {
    }

    func get_current_yang_price(yang: address) -> (
        price: wad, cumulative_price: wad, interval: ufelt
    ) {
    }

    func get_current_multiplier() -> (
        multiplier: ray, cumulative_multiplier: ray, interval: ufelt
    ) {
    }

    func estimate(trove_id: ufelt) -> (debt: wad) {
    }

    func is_healthy(trove_id: ufelt) -> (healthy: bool) {
    }

    func is_within_limits(trove_id: ufelt) -> (within_limits: bool) {
    }

    func has_role(role: ufelt, user: address) -> (has_role: bool) {
    }
}
