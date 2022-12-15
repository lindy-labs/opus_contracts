%lang starknet

from contracts.lib.aliases import address, bool, ufelt, wad

@contract_interface
namespace IEmpiric {
    //
    // view
    //

    func probeTask() -> (is_task_ready: bool) {
    }

    //
    // external
    //

    func set_oracle_address(oracle: address) {
    }

    func set_price_validity_thresholds(freshness: ufelt, sources: ufelt) {
    }

    func set_update_interval(new_interval: ufelt) {
    }

    func add_yang(empiric_id: ufelt, yang: address) {
    }

    func update_prices() {
    }

    func force_update_prices() {
    }

    func executeTask() {
    }
}
