%lang starknet

from contracts.lib.aliases import address, ray, ufelt, wad

@contract_interface
namespace IAllocator {
    //
    // view
    //
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
namespace IEqualizer {
    //
    // view
    //
    func get_allocator() -> (allocator: address) {
    }

    func get_surplus() -> (amount: wad) {
    }

    //
    // external
    //
    func set_allocator(allocator: address) {
    }

    func equalize() -> (minted_surplus: wad) {
    }
}
