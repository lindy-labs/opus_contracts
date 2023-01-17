%lang starknet

from contracts.lib.aliases import address, ufelt, wad
from contracts.lib.types import AssetAbsorption, Provision

@contract_interface
namespace IAbsorber {
    //
    // view
    //

    func get_purger() -> (purger: address) {
    }

    func get_current_epoch() -> (epoch: ufelt) {
    }

    func get_absorptions_count() -> (count: ufelt) {
    }

    func get_absorption_epoch(absorption_id: ufelt) -> (epoch: ufelt) {
    }

    func get_total_shares_for_current_epoch() -> (total: wad) {
    }

    func get_provider_info(provider: address) -> (provision: Provision) {
    }

    func get_provider_last_absorption(provider: address) -> (absorption_id: ufelt) {
    }

    func get_provider_yin(provider: address) -> (amount: wad) {
    }

    func get_asset_absorption_info(absorption_id: ufelt, asset: address) -> (
        info: AssetAbsorption
    ) {
    }

    //
    // external
    //

    func set_purger(purger: address) {
    }

    func provide(amount: wad) {
    }

    func remove(amount: wad) {
    }

    func reap() {
    }

    func update(
        asset_addresses_len: ufelt,
        asset_addresses: address*,
        asset_amts_len: ufelt,
        asset_amts: ufelt*,
    ) {
    }
}
