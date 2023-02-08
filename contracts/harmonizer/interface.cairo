%lang starknet

from contracts.lib.aliases import address, ray, ufelt, wad

@contract_interface
namespace IAllocator {
    //
    // view
    //
    func get_recipients_count() -> (count: ufelt) {
    }

    func get_allocation() -> (
        recipients_len: ufelt, recipients: address*, percentages_len: ufelt, percentages: ray*
    ) {
    }

    //
    // external
    //
    func set_allocation(
        recipients_len: ufelt, recipients: address*, percentages_len: ufelt, percentages: ray*
    ) {
    }
}

@contract_interface
namespace IHarmonizer {
    //
    // view
    //
    func get_allocator() -> (allocator: address) {
    }

    //
    // external
    //
    func set_allocator(allocator: address) {
    }

    func restore() {
    }
}
