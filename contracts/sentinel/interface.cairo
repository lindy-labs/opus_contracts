%lang starknet
from contracts.lib.aliases import address, ray, ufelt, wad

@contract_interface
namespace ISentinel {
    //
    // View
    //

    func get_gate_address(yang: address) -> (gate: address) {
    }

    func get_yang_addresses() -> (addresses_len: ufelt, addresses: address*) {
    }

    func get_yang_addresses_count() -> (count: ufelt) {
    }

    func get_yang(idx: ufelt) -> (yang: address) {
    }

    func get_asset_amt_per_yang(yang: address) -> (amt: wad) {
    }

    func preview_enter(yang: address, asset_amt: ufelt) -> (preview: wad) {
    }

    func preview_exit(yang: address, yang_amt: wad) -> (preview: ufelt) {
    }

    //
    // External
    //

    func add_yang(
        yang: address, yang_max: wad, yang_threshold: ray, yang_price: wad, gate: address
    ) {
    }

    func enter(yang: address, user: address, trove_id: ufelt, asset_amt: ufelt) -> (yang_amt: wad) {
    }

    func exit(yang: address, user: address, trove_id: ufelt, yang_amt: wad) -> (asset_amt: ufelt) {
    }
}
