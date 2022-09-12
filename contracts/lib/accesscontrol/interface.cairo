%lang starknet

from contracts.shared.aliases import bool, address, ufelt

@contract_interface
namespace IAccessControl {
    //
    // getters
    //

    func get_roles(account: address) -> (roles: ufelt) {
    }

    func has_role(role: ufelt, account: address) -> (has_role: bool) {
    }

    func get_admin() -> (admin: address) {
    }

    //
    // setters
    //

    func grant_role(role: ufelt, account: address) {
    }

    func revoke_role(role: ufelt, account: address) {
    }

    func renounce_role(role: ufelt, account: address) {
    }

    func change_admin(new_admin: address) {
    }
}
