%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_contract_address

from contracts.interfaces import IShrine
from contracts.shared.interfaces import IERC20
from contracts.shared.types import Yang
from contracts.shared.wad_ray import WadRay

#
# Storage
#

@storage_var
func gate_shrine_storage() -> (address):
end

@storage_var
func gate_asset_storage() -> (address):
end

namespace Gate:
    #
    # Constructor
    #

    func initializer{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        shrine_address, asset_address
    ):
        gate_shrine_storage.write(shrine_address)
        gate_asset_storage.write(asset_address)
        return ()
    end

    # Getters

    func get_shrine{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        address
    ):
        return gate_shrine_storage.read()
    end

    func get_asset{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        address
    ):
        return gate_asset_storage.read()
    end

    func get_total_assets{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        wad
    ):
        let (asset_address) = get_asset()
        let (gate_address) = get_contract_address()
        let (total_uint : Uint256) = IERC20.balanceOf(
            contract_address=asset_address, account=gate_address
        )
        let (total_wad) = WadRay.from_uint(total_uint)
        return (total_wad)
    end

    func get_total_yang{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        wad
    ):
        let (shrine_address) = get_shrine()
        let (asset_address) = get_asset()
        let (yang_info : Yang) = IShrine.get_yang(
            contract_address=shrine_address, yang_address=asset_address
        )
        return (yang_info.total)
    end

    func get_exchange_rate{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        wad
    ):
        let (total_supply_wad) = get_total_yang()
        let (total_balance) = get_total_assets()

        # Catch division by zero errors
        if total_supply_wad == 0:
            return (0)
        end

        let (exchange_rate) = WadRay.wunsigned_div_unchecked(total_balance, total_supply_wad)
        return (exchange_rate)
    end

    #
    # Internal
    #

    func convert_to_assets{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        shares
    ) -> (wad):
        alloc_locals

        let (total_supply_wad) = get_total_yang()

        if total_supply_wad == 0:
            return (shares)
        else:
            let (total_assets_wad) = get_total_assets()
            let (product) = WadRay.wmul(shares, total_assets_wad)
            let (assets_wad) = WadRay.wunsigned_div_unchecked(product, total_supply_wad)
            return (assets_wad)
        end
    end

    func convert_to_shares{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        assets_wad
    ) -> (wad):
        alloc_locals

        let (total_supply_wad) = get_total_yang()

        if total_supply_wad == 0:
            return (assets_wad)
        else:
            let (product) = WadRay.wmul(assets_wad, total_supply_wad)
            let (total_assets_wad) = get_total_assets()
            let (shares) = WadRay.wunsigned_div_unchecked(product, total_assets_wad)
            return (shares)
        end
    end
end
