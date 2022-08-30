%lang starknet

@contract_interface
namespace IAccessControl {
    //
    // getters
    //

    func get_role(address) -> (ufelt: felt) {
    }

    func has_role(role, address) -> (bool: felt) {
    }

    func get_admin() -> (address: felt) {
    }

    //
    // setters
    //

    func grant_role(role, address) {
    }

    func revoke_role(role, address) {
    }

    func renounce_role(role, address) {
    }

    func change_admin(address) {
    }
}
