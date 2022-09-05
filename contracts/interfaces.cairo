%lang starknet

from contracts.shared.types import Trove, Yang

@contract_interface
namespace IShrine:
    #
    # getters
    #
    func get_trove(trove_id) -> (trove : Trove):
    end

    func get_yin(user_address) -> (wad):
    end

    func get_yang(yang_address) -> (yang : Yang):
    end

    func get_yangs_count() -> (ufelt):
    end

    func get_deposit(yang_address, trove_id) -> (wad):
    end

    func get_total_debt() -> (wad):
    end

    func get_total_yin() -> (wad):
    end

    func get_yang_price(yang_address, interval) -> (price_wad, cumulative_price_wad):
    end

    func get_ceiling() -> (wad):
    end

    func get_multiplier(interval) -> (multiplier_ray, cumulative_multiplier_ray):
    end

    func get_threshold(yang_address) -> (ray):
    end

    func get_live() -> (bool):
    end

    #
    # external
    #
    func add_yang(yang_address, max, threshold, price):
    end

    func update_yang_max(yang_address, new_max):
    end

    func set_ceiling(new_ceiling):
    end

    func set_threshold(yang_address, new_threshold):
    end

    func kill():
    end

    func advance(yang_address, price):
    end

    func update_multiplier(new_multiplier):
    end

    func move_yang(yang_address, src_trove_id, dst_trove_id, amount):
    end

    func move_yin(src_address, dst_address, amount):
    end

    func deposit(yang_address, trove_id, amount):
    end

    func withdraw(yang_address, trove_id, amount):
    end

    func forge(user_address, trove_id, amount):
    end

    func melt(user_address, trove_id, amount):
    end

    func seize(trove_id):
    end

    #
    # view
    #
    func get_trove_threshold(trove_id) -> (threshold_ray, value_wad):
    end

    func get_current_trove_ratio(trove_id) -> (ray):
    end

    func get_current_yang_price(yang_address) -> (price_wad, cumulative_price_wad, interval_ufelt):
    end

    func get_current_multiplier() -> (multiplier_ray, cumulative_multiplier_ray, interval_ufelt):
    end

    func estimate(trove_id) -> (wad):
    end

    func is_healthy(trove_id) -> (bool):
    end

    func is_within_limits(trove_id) -> (bool):
    end
end

@contract_interface
namespace IGate:
    #
    # getters
    #
    func get_live() -> (bool):
    end

    func get_shrine() -> (address):
    end

    func get_asset() -> (address):
    end

    #
    # external
    #
    func deposit(user_address, trove_id, assets_wad) -> (wad):
    end

    func withdraw(user_address, trove_id, yang_wad) -> (wad):
    end

    func kill():
    end

    #
    # view
    #
    func get_total_assets() -> (wad):
    end

    func get_total_yang() -> (wad):
    end

    func get_exchange_rate() -> (wad):
    end

    func preview_deposit(assets_wad) -> (wad):
    end

    func preview_withdraw(yang_wad) -> (wad):
    end
end

@contract_interface
namespace IAbbot:
    #
    # getters
    #

    func get_trove_owner(trove_id) -> (address):
    end

    func get_user_trove_ids(address) -> (trove_ids_len, trove_ids : felt*):
    end

    func get_yang_addresses() -> (addresses_len, addresses : felt*):
    end

    func get_troves_count() -> (ufelt):
    end

    #
    # external
    #

    func open_trove(forge_amount, yang_addrs_len, yang_addrs : felt*, amounts_len, amounts : felt*):
    end

    func close_trove(trove_id):
    end

    func deposit(yang_address, trove_id, amount):
    end

    func withdraw(yang_address, trove_id, amount):
    end

    func forge(trove_id, amount):
    end

    func melt(trove_id, amount):
    end

    func add_yang(yang_address, yang_max, yang_threshold, yang_price, gate_address):
    end
end
