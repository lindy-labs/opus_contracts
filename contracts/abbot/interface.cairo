%lang starknet

from contracts.lib.aliases import address, ufelt, wad

@contract_interface
namespace IAbbot {
    //
    // getters
    //

    func get_trove_owner(trove_id: ufelt) -> (owner: address) {
    }

    func get_user_trove_ids(user: address) -> (trove_ids_len: ufelt, trove_ids: ufelt*) {
    }

    func get_gate_address(yang: address) -> (gate: address) {
    }

    func get_yang_addresses() -> (yangs_len: ufelt, yangs: address*) {
    }

    func get_troves_count() -> (count: ufelt) {
    }

    //
    // external
    //

    func open_trove(
        forge_amount: wad, yangs_len: ufelt, yangs: address*, amounts_len: ufelt, amounts: wad*
    ) {
    }

    func close_trove(trove_id: ufelt) {
    }

    func deposit(yang: address, trove_id: ufelt, amount: wad) {
    }

    func withdraw(yang: address, trove_id: ufelt, amount: wad) {
    }

    func forge(trove_id: ufelt, amount: wad) {
    }

    func melt(trove_id: ufelt, amount: wad) {
    }
}
