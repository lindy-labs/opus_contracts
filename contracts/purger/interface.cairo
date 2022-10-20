%lang starknet

from contracts.lib.aliases import address, ray, ufelt, wad

@contract_interface
namespace IPurger {
    //
    // view
    //

    func get_penalty(trove_id: ufelt) -> (penalty: ray) {
    }

    func get_max_close_amount(trove_id: ufelt) -> (amount: wad) {
    }

    //
    // external
    //

    func liquidate(trove_id: ufelt, purge_amt: wad, recipient: address) -> (
        yangs_len: ufelt, yangs: address*, freed_assets_amt_len: ufelt, freed_assets_amt: wad*
    ) {
    }

    func absorb(trove_id: ufelt) -> (
        yangs_len: ufelt, yangs: address*, freed_assets_amt_len: ufelt, freed_assets_amt: wad*
    ) {
    }
}
