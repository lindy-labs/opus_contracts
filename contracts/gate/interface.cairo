%lang starknet

from contracts.lib.aliases import address, bool, ray, ufelt, wad

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
    func enter(user: address, trove_id: ufelt, assets: ufelt) -> (yang: wad) {
    }

    func exit(user: address, trove_id: ufelt, yang: wad) -> (assets: ufelt) {
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

    func get_asset_amt_per_yang() -> (amt: wad) {
    }

    func preview_enter(assets: ufelt) -> (preview: wad) {
    }

    func preview_exit(yang: wad) -> (preview: ufelt) {
    }
}

@contract_interface
namespace IGateTax {
    //
    // getters
    //
    func get_tax() -> (tax: ray) {
    }

    func get_tax_collector() -> (tax_collector: address) {
    }

    // external
    func set_tax(tax: ray) {
    }

    func set_tax_collector(new_collector: address) {
    }

    func levy() {
    }
}
