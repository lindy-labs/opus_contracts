%lang starknet

from contracts.lib.aliases import address, bool, ufelt, wad

@contract_interface
namespace IGate {
    //
    // getters
    //
    func get_live() -> (is_live: bool) {
    }

    func get_shrine() -> (shrine: address) {
    }

    func get_asset() -> (asset: address) {
    }

    //
    // external
    //
    func enter(user: address, trove_id: ufelt, assets: wad) -> (yang: wad) {
    }

    func exit(user: address, trove_id: ufelt, yang: wad) -> (assets: wad) {
    }

    func kill() {
    }

    //
    // view
    //
    func get_total_assets() -> (total: wad) {
    }

    func get_total_yang() -> (total: wad) {
    }

    func get_exchange_rate() -> (rate: wad) {
    }

    func preview_enter(assets: wad) -> (preview: wad) {
    }

    func preview_exit(yang: wad) -> (preview: wad) {
    }
}
