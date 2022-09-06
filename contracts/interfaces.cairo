%lang starknet

from contracts.shared.types import Trove, Yang

@contract_interface
namespace IShrine {
    //
    // getters
    //
    func get_trove(trove_id) -> (trove: Trove) {
    }

    func get_yin(user_address) -> (wad: felt) {
    }

    func get_yang(yang_address) -> (yang: Yang) {
    }

    func get_yangs_count() -> (ufelt: felt) {
    }

    func get_deposit(yang_address, trove_id) -> (wad: felt) {
    }

    func get_total_debt() -> (wad: felt) {
    }

    func get_total_yin() -> (wad: felt) {
    }

    func get_yang_price(yang_address, interval) -> (price_wad: felt, cumulative_price_wad: felt) {
    }

    func get_ceiling() -> (wad: felt) {
    }

    func get_multiplier(interval) -> (multiplier_ray: felt, cumulative_multiplier_ray: felt) {
    }

    func get_threshold(yang_address) -> (ray: felt) {
    }

    func get_live() -> (bool: felt) {
    }

    //
    // external
    //
    func add_yang(yang_address, max, threshold, price) {
    }

    func update_yang_max(yang_address, new_max) {
    }

    func set_ceiling(new_ceiling) {
    }

    func set_threshold(yang_address, new_threshold) {
    }

    func kill() {
    }

    func advance(yang_address, price) {
    }

    func update_multiplier(new_multiplier) {
    }

    func move_yang(yang_address, src_trove_id, dst_trove_id, amount) {
    }

    func move_yin(src_address, dst_address, amount) {
    }

    func deposit(yang_address, trove_id, amount) {
    }

    func withdraw(yang_address, trove_id, amount) {
    }

    func forge(user_address, trove_id, amount) {
    }

    func melt(user_address, trove_id, amount) {
    }

    func seize(yang_address, trove_id, amount) {
    }

    //
    // view
    //
    func get_trove_threshold(trove_id) -> (threshold_ray: felt, value_wad: felt) {
    }

    func get_current_trove_ratio(trove_id) -> (ray: felt) {
    }

    func get_current_yang_price(yang_address) -> (
        price_wad: felt, cumulative_price_wad: felt, interval_ufelt: felt
    ) {
    }

    func get_current_multiplier() -> (
        multiplier_ray: felt, cumulative_multiplier_ray: felt, interval_ufelt: felt
    ) {
    }

    func estimate(trove_id) -> (wad: felt) {
    }

    func is_healthy(trove_id) -> (bool: felt) {
    }

    func is_within_limits(trove_id) -> (bool: felt) {
    }
}

@contract_interface
namespace IGate {
    //
    // getters
    //
    func get_live() -> (bool: felt) {
    }

    func get_shrine() -> (address: felt) {
    }

    func get_asset() -> (address: felt) {
    }

    //
    // external
    //
    func deposit(user_address, trove_id, assets_wad) {
    }

    func withdraw(user_address, trove_id, assets_wad) {
    }

    func kill() {
    }

    //
    // view
    //
    func get_total_assets() -> (wad: felt) {
    }

    func get_total_yang() -> (wad: felt) {
    }

    func get_exchange_rate() -> (wad: felt) {
    }

    func preview_deposit(assets_wad) -> (wad: felt) {
    }

    func preview_withdraw(yang_wad) -> (wad: felt) {
    }
}

@contract_interface
namespace IAbbot {
    //
    // getters
    //

    func get_trove_owner(trove_id) -> (address: felt) {
    }

    func get_user_trove_ids(address) -> (trove_ids_len: felt, trove_ids: felt*) {
    }

    func get_gate_address(yang_address) -> (address: felt) {
    }

    func get_yang_addresses() -> (addresses_len: felt, addresses: felt*) {
    }

    func get_troves_count() -> (ufelt: felt) {
    }

    //
    // external
    //

    func open_trove(forge_amount, yang_addrs_len, yang_addrs: felt*, amounts_len, amounts: felt*) {
    }

    func close_trove(trove_id) {
    }

    func deposit(yang_address, trove_id, amount) {
    }

    func withdraw(yang_address, trove_id, amount) {
    }

    func forge(trove_id, amount) {
    }

    func add_yang(yang_address, yang_max, yang_threshold, yang_price, gate_address) {
    }
}

@contract_interface
namespace IStabilityPool {

    /////////////////////////////////////////////
    //                EXTERNAL                 //
    /////////////////////////////////////////////
    
    func provide(amount: felt) {
    }

    func withdraw(amount: felt) {
    }

    func liquidate(trove_id: felt) {
    }
    
    /////////////////////////////////////////////
    //                GETTERS                  //
    /////////////////////////////////////////////
    
    func get_provider_owed_yangs(provider: felt) -> (yangs_len : felt, yangs : felt*) {
    }
    
    func get_provider_owed_yin(provider: felt) -> (yin : felt) {
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

    func purge(trove_id: felt, purge_amt_wad: felt, recipient_address: felt) {
    }

    func restricted_purge(
        trove_id: felt, purge_amt_wad: felt, recipient_address: felt, funder_address: felt
    ) {
    }
}
