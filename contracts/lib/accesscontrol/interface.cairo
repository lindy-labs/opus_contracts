%lang starknet

@contract_interface
namespace IAccessControl:
    #
    # getters
    #

    func get_role(address) -> (ufelt):
    end

    func has_role(role, address) -> (bool):
    end

    func get_admin() -> (address):
    end

    #
    # setters
    #

    func grant_role(role, address):
    end

    func revoke_role(role, address):
    end

    func renounce_role(role, address):
    end

    func change_admin(address):
    end
end
