%lang starknet

from contracts.shared.types import Trove, Yang
from contracts.shared.aliases import wad, ray, str, bool, ufelt, sfelt, address, packed

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

@contract_interface
namespace IGate {
    //
    // getters
    //
    func get_live() -> (is_live: bool) {
    }

    func get_shrine() -> (shrine: address) {
    }

    func get_asset() -> (asset: address) {
    }

    //
    // external
    //
    func deposit(user: address, trove_id: ufelt, assets: wad) -> (yang: wad) {
    }

    func withdraw(user: address, trove_id: ufelt, yang: wad) -> (assets: wad) {
    }

    func kill() {
    }

    //
    // view
    //
    func get_total_assets() -> (total: wad) {
    }

    func get_total_yang() -> (total: wad) {
    }

    func get_exchange_rate() -> (rate: wad) {
    }

    func preview_deposit(assets: wad) -> (preview: wad) {
    }

    func preview_withdraw(yang: wad) -> (preview: wad) {
    }
}

@contract_interface
namespace IAbbot {
    //
    // getters
    //

    func get_trove_owner(trove_id: ufelt) -> (owner: address) {
    }

    func get_user_trove_ids(user: address) -> (trove_ids_len: ufelt, trove_ids: ufelt*) {
    }

    func get_gate_address(yang: address) -> (gate: address) {
    }

    func get_yang_addresses() -> (yangs_len: ufelt, yangs: address*) {
    }

    func get_troves_count() -> (count: ufelt) {
    }

    //
    // external
    //

    func open_trove(
        forge_amount: wad, yangs_len: ufelt, yangs: address*, amounts_len: ufelt, amounts: wad*
    ) {
    }

    func close_trove(trove_id: ufelt) {
    }

    func deposit(yang: address, trove_id: ufelt, amount: wad) {
    }

    func withdraw(yang: address, trove_id: ufelt, amount: wad) {
    }

    func forge(trove_id: ufelt, amount: wad) {
    }

    func melt(trove_id: ufelt, amount: wad) {
    }

    func add_yang(
        yang: address, yang_max: wad, yang_threshold: ray, yang_price: wad, gate: address
    ) {
    }
}

@contract_interface
namespace IYin {
    func name() -> (str: felt) {
    }

    func symbol() -> (str: felt) {
    }

    func decimals() -> (ufelt: felt) {
    }

    func totalSupply() -> (totalSupply: felt) {
    }

    func balanceOf(account: felt) -> (wad: felt) {
    }

    func allowance(owner: felt, spender: felt) -> (wad: felt) {
    }

    func transfer(recipient: felt, amount: felt) -> (bool: felt) {
    }

    func transferFrom(sender: felt, recipient: felt, amount: felt) -> (bool: felt) {
    }

    func approve(spender: felt, amount: felt) -> (bool: felt) {
    }
}

@contract_interface
namespace IPurger {
    //
    // view
    //

    func get_purge_penalty(trove_id: felt) -> (ray: felt) {
    }

    func get_max_close_amount(trove_id: felt) -> (wad: felt) {
    }

    //
    // external
    //

    func purge(trove_id: felt, purge_amt_wad: felt, recipient_address: felt) -> (
        yang_addresses_len: felt,
        yang_addresses: felt*,
        freed_assets_amt_len: felt,
        freed_assets_amt: felt*,
    ) {
    }
}
