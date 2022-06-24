%lang starknet

from starkware.cairo.common.uint256 import Uint256

@contract_interface
namespace IERC20:
    func name() -> (name : felt):
    end

    func symbol() -> (symbol : felt):
    end

    func decimals() -> (decimals : felt):
    end

    func totalSupply() -> (totalSupply : Uint256):
    end

    func balanceOf(account : felt) -> (balance : Uint256):
    end

    func allowance(owner : felt, spender : felt) -> (remaining : Uint256):
    end

    func transfer(recipient : felt, amount : Uint256) -> (success : felt):
    end

    func transferFrom(sender : felt, recipient : felt, amount : Uint256) -> (success : felt):
    end

    func approve(spender : felt, amount : Uint256) -> (success : felt):
    end
end

@contract_interface
namespace IERC20Mintable:
    func mint(recipient : felt, amount : Uint256) -> (success : felt):
    end
end

@contract_interface
namespace IERC20Burnable:
    func burn(owner : felt, amount : Uint256) -> (success : felt):
    end
end

@contract_interface
namespace IShrine:
    func deposit(gage_id : felt, amount : felt, user_address : felt, trove_id : felt):
    end

    func withdraw(gage_id : felt, amount : felt, user_address : felt, trove_id : felt):
    end
end

# TODO: not even sure if these methods should be on USDa
@contract_interface
namespace IUSDa:
    func get_collateralization_ratio() -> (ratio : felt):
    end

    func get_total_collateral() -> (total : felt):
    end
end
