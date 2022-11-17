%lang starknet

from contracts.lib.aliases import address, wad

@contract_interface
namespace IYin {
    func emit_on_forge(to: address, amount: wad) {
    }

    func emit_on_melt(from_: address, amount: wad) {
    }
}
