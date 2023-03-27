%lang starknet

from contracts.lib.aliases import address, bool, ray, ufelt, wad
from contracts.lib.types import AssetAbsorption, Provision

@contract_interface
namespace IAbsorber {
    //
    // view
    //

    func get_purger() -> (purger: address) {
    }

    func get_pending_removal_yin() -> (amount: wad) {
    }

    func get_absorbable_yin() -> (amount: wad) {
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

    func get_provider_request_timestamp(provider: address) -> (timestamp: ufelt) {
    }

    func get_asset_absorption_info(asset: address, absorption_id: ufelt) -> (
        info: AssetAbsorption
    ) {
    }

    func get_removal_limit() -> (limit: ray) {
    }

    func get_live() -> (is_live: bool) {
    }

    func preview_remove(provider: address) -> (amount: wad) {
    }

    func preview_reap(provider: address) -> (
        assets_len: ufelt, assets: address*, asset_amts_len: ufelt, asset_amts: ufelt*
    ) {
    }

    //
    // external
    //

    func set_purger(purger: address) {
    }

    func set_removal_limit(limit: ray) {
    }

    func provide(amount: wad) {
    }

    func request() {
    }

    func remove(amount: wad) {
    }

    func reap() {
    }

    func update(assets_len: ufelt, assets: address*, asset_amts_len: ufelt, asset_amts: ufelt*) {
    }

    func kill() {
    }

    func compensate(
        recipient: address,
        assets_len: ufelt,
        assets: address*,
        asset_amts_len: ufelt,
        asset_amts: ufelt*,
    ) {
    }
}
