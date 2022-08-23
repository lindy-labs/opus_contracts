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

    func get_deposit(trove_id, yang_address) -> (wad):
    end

    func get_debt() -> (wad):
    end

    func get_total_yin() -> (wad):
    end

    func get_yang_price(yang_address, interval) -> (wad):
    end

    func get_ceiling() -> (wad):
    end

    func get_multiplier(interval) -> (ray):
    end

    func get_threshold(yang_address) -> (ray):
    end

    func get_live() -> (bool):
    end

    func get_role(user) -> (ufelt):
    end

    func has_role(role, user) -> (bool):
    end

    func get_admin() -> (address):
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

    func get_current_yang_price(yang_address) -> (wad):
    end

    func get_current_multiplier() -> (ray):
    end

    func estimate(trove_id) -> (wad):
    end

    func is_healthy(trove_id) -> (bool):
    end

    func is_within_limits(trove_id) -> (bool):
    end

    func grant_role(role, address):
    end

    func revoke_role(role, address):
    end

    func renounce_role(role, address):
    end

    func change_admin(new_admin):
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
