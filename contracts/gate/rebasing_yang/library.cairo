%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import unsigned_div_rem
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_contract_address

from contracts.shrine.interface import IShrine

from contracts.lib.aliases import address, ufelt, wad
from contracts.lib.interfaces import IERC20
from contracts.lib.pow import pow10
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

    // Return value is `ufelt` because `asset` may not be 18 decimals
    func get_total_assets{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        ) -> ufelt {
        let asset: address = get_asset();
        let (gate: address) = get_contract_address();
        let (total_uint: Uint256) = IERC20.balanceOf(contract_address=asset, account=gate);

        let total: ufelt = WadRay.from_uint(total_uint);
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
        let amt: ufelt = convert_to_assets(WadRay.WAD_ONE);

        let (asset: address) = gate_asset.read();
        let (decimals: ufelt) = IERC20.decimals(asset);

        if (decimals == 18) {
            // `amt` is already scaled to `wad`
            return amt;
        }

        // Scale tokens with less than 18 decimals to wad
        let (scale: ufelt) = pow10(WadRay.WAD_DECIMALS - decimals);
        let scaled_amt: wad = amt * scale;

        return scaled_amt;
    }

    //
    // Internal
    //

    // Return value is `ufelt` because `asset` may not be 18 decimals
    func convert_to_assets{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        yang: wad
    ) -> ufelt {
        alloc_locals;

        let total_supply: wad = get_total_yang();

        if (total_supply == 0) {
            let (asset: address) = gate_asset.read();
            let (decimals: ufelt) = IERC20.decimals(asset);

            if (decimals == 18) {
                return yang;
            }

            // Scale by difference
            let (scale: ufelt) = pow10(WadRay.WAD_DECIMALS - decimals);
            let (scaled_assets: ufelt, _) = unsigned_div_rem(yang, scale);

            return scaled_assets;
        } else {
            let total_assets: ufelt = get_total_assets();
            let assets: ufelt = WadRay.wunsigned_div_unchecked(
                WadRay.wmul(yang, total_assets), total_supply
            );
            return assets;
        }
    }

    // `assets` is `ufelt` because it may not be 18 decimals
    func convert_to_yang{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        assets: ufelt
    ) -> wad {
        alloc_locals;

        let total_supply: wad = get_total_yang();

        if (total_supply == 0) {
            let (asset: address) = gate_asset.read();
            let (decimals: ufelt) = IERC20.decimals(asset);

            if (decimals == 18) {
                return assets;
            }

            // Scale by difference
            let (scale: ufelt) = pow10(WadRay.WAD_DECIMALS - decimals);
            let scaled_yang: wad = assets * scale;

            return scaled_yang;
        } else {
            let total_assets: ufelt = get_total_assets();
            let yang: wad = WadRay.wunsigned_div_unchecked(
                WadRay.wmul(assets, total_supply), total_assets
            );
            return yang;
        }
    }
}
