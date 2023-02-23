%lang starknet

from contracts.lib.aliases import address, bool, ufelt, wad
from contracts.lib.types import AssetApportion, Provision

// TODO: update interface
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

    func get_rewards_count() -> (count: ufelt) {
    }

    func get_blessings_count() -> (count: ufelt) {
    }

    func get_absorption_epoch(absorption_id: ufelt) -> (epoch: ufelt) {
    }

    func get_blessing_epoch(blessing_id: ufelt) -> (epoch: ufelt) {
    }

    func get_total_shares_for_current_epoch() -> (total: wad) {
    }

    func get_provider_info(provider: address) -> (provision: Provision) {
    }

    func get_provider_last_absorption(provider: address) -> (absorption_id: ufelt) {
    }

    func get_asset_absorption_info(asset: address, absorption_id: ufelt) -> (info: AssetApportion) {
    }

    func get_asset_blessing_info(asset: address, blessing_id: ufelt) -> (info: AssetApportion) {
    }

    func get_rewards() -> (
        assets_len: ufelt,
        assets: address*,
        blessers_len: ufelt,
        blessers: address*,
        is_active_len: ufelt,
        is_active: bool*,
    ) {
    }

    func preview_remove(provider: address) -> (amount: wad) {
    }

    func preview_reap(provider: address) -> (
        absorbed_assets_len: ufelt,
        absorbed_assets: address*,
        absorbed_asset_amts_len: ufelt,
        absorbed_asset_amts: ufelt*,
        blessed_assets_len: ufelt,
        blessed_assets: address*,
        blessed_asset_amts_len: ufelt,
        blessed_asset_amts: ufelt*,
    ) {
    }

    //
    // external
    //

    func set_purger(purger: address) {
    }

    func set_reward(asset: address, blesser: address, is_active: bool) {
    }

    func provide(amount: wad) {
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

@contract_interface
namespace IBlesser {
    // If no reward tokens are transferred to the absorber, `bless` should return 0
    // instead of reverting.
    func bless() -> (amount: wad) {
    }
}
