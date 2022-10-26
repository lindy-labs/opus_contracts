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

    //
    // External
    //

    func add_yang(
        yang: address, yang_max: wad, yang_threshold: ray, yang_price: wad, gate: address
    ) {
    }
}
