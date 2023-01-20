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
    func enter(user: address, trove_id: ufelt, asset_amt: ufelt) -> (yang_amt: wad) {
    }

    func exit(user: address, trove_id: ufelt, yang_amt: wad) -> (asset_amt: ufelt) {
    }

    func kill() {
    }

    //
    // view
    //
    func get_total_assets() -> (total: ufelt) {
    }

    func get_total_yang() -> (total: wad) {
    }

    func get_asset_amt_per_yang() -> (amt: wad) {
    }

    func preview_enter(asset_amt: ufelt) -> (yang_amt: wad) {
    }

    func preview_exit(yang_amt: wad) -> (asset_amt: ufelt) {
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
