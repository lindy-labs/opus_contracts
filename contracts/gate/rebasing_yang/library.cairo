%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_contract_address

from contracts.shrine.interface import IShrine

from contracts.lib.aliases import address, ufelt, wad
from contracts.lib.interfaces import IERC20
from contracts.lib.types import Yang
from contracts.lib.wad_ray import WadRay

//
// Storage
//

@storage_var
func gate_shrine() -> (shrine: address) {
}

@storage_var
func gate_asset() -> (asset: address) {
}

namespace Gate {
    //
    // Constructor
    //

    func initializer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        shrine: address, asset: address
    ) {
        gate_shrine.write(shrine);
        gate_asset.write(asset);
        return ();
    }

    // Getters

    func get_shrine{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> address {
        let (shrine: address) = gate_shrine.read();
        return shrine;  // gate_shrine.read returns a tuple with a single element
    }

    func get_asset{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> address {
        let (asset: address) = gate_asset.read();
        return asset;
    }

    func get_total_assets{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        ) -> wad {
        let asset: address = get_asset();
        let (gate: address) = get_contract_address();
        let (total_uint: Uint256) = IERC20.balanceOf(contract_address=asset, account=gate);

        let total: wad = WadRay.from_uint(total_uint);
        return total;
    }

    func get_total_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> wad {
        let shrine: address = get_shrine();
        let asset: address = get_asset();
        let (yang_info: Yang) = IShrine.get_yang(contract_address=shrine, yang=asset);
        return yang_info.total;
    }

    func get_asset_amt_per_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        ) -> wad {
        let amt: wad = convert_to_assets(WadRay.WAD_ONE);

        // Scale assets with less than 18 decimals to wad
        let asset: address = get_asset();
        let decimals: ufelt = IERC20.decimals(contract_address=asset);

        // Assumes 0 <= decimals < 18
        let decimals_offset: ufelt = WadRay.WAD_DECIMALS - decimals;
        if (decimals_offset == 0) {
            return amt;
        }

        return amt * decimals_offset;
    }

    //
    // Internal
    //

    func convert_to_assets{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        yang: wad
    ) -> wad {
        alloc_locals;

        let total_supply: wad = get_total_yang();

        if (total_supply == 0) {
            return yang;
        } else {
            let total_assets: wad = get_total_assets();
            let assets: wad = WadRay.wunsigned_div_unchecked(
                WadRay.wmul(yang, total_assets), total_supply
            );
            return assets;
        }
    }

    func convert_to_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        assets: wad
    ) -> wad {
        alloc_locals;

        let total_supply: wad = get_total_yang();

        if (total_supply == 0) {
            return assets;
        } else {
            let product: wad = WadRay.wmul(assets, total_supply);
            let total_assets: wad = get_total_assets();
            let yang: wad = WadRay.wunsigned_div_unchecked(product, total_assets);
            return yang;
        }
    }
}
