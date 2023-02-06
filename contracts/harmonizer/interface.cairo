%lang starknet

from contracts.lib.aliases import address, ray, ufelt, wad

@contract_interface
namespace IBeneficiaryRegistrar {
    //
    // view
    //
    func get_beneficiaries_count() -> (count: ufelt) {
    }

    func get_beneficiaries() -> (
        beneficiaries_len: ufelt, beneficiaries: address*, percentages_len: ufelt, percentages: ray*
    ) {
    }

    //
    // external
    //
    func set_beneficiaries(
        beneficiaries_len: ufelt, beneficiaries: address*, percentages_len: ufelt, percentages: ray*
    ) {
    }
}
