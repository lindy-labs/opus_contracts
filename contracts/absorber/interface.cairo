%lang starknet

from contracts.lib.aliases import address, bool, ray, ufelt, wad
from contracts.lib.types import AssetApportion, Provision, Request, Reward

// TODO: update interface
@contract_interface
namespace IAbsorber {
    //
    // view
    //

    func get_purger() -> (purger: address) {
    }

    func get_rewards_count() -> (count: ufelt) {
    }

    func get_rewards() -> (rewards_len: ufelt, rewards: Reward*) {
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

    func get_provider_request(provider: address) -> (request: Request) {
    }

    func get_asset_absorption_info(asset: address, absorption_id: ufelt) -> (info: AssetApportion) {
    }

    func get_asset_reward_info(asset: address, epoch: ufelt) -> (info: AssetApportion) {
    }

    func get_provider_last_reward_cumulative(provider: address, asset: address) -> (
        cumulative: ufelt
    ) {
    }

    func get_removal_limit() -> (limit: ray) {
    }

    func get_live() -> (is_live: bool) {
    }

    func preview_remove(provider: address) -> (amount: wad) {
    }

    func preview_reap(provider: address) -> (
        absorbed_assets_len: ufelt,
        absorbed_assets: address*,
        absorbed_asset_amts_len: ufelt,
        absorbed_asset_amts: ufelt*,
        reward_assets_len: ufelt,
        reward_assets: address*,
        reward_asset_amts_len: ufelt,
        reward_asset_amts: ufelt*,
    ) {
    }

    //
    // external
    //

    func set_purger(purger: address) {
    }

    func set_reward(asset: address, blesser: address, is_active: bool) {
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

@contract_interface
namespace IBlesser {
    // If no reward tokens are to be distributed to the absorber, `preview_bless` and `bless`
    // should return 0 instead of reverting.
    func bless() -> (amount: ufelt) {
    }

    func preview_bless() -> (amount: ufelt) {
    }
}
