%lang starknet

from contracts.lib.aliases import address, ufelt, wad

@contract_interface
namespace IYin {
    func forge(user: address, trove_id: ufelt, amount: wad) {
    }

    func melt(user: address, trove_id: ufelt, amount: wad) {
    }
}
