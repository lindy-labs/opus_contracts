%lang starknet

from starkware.cairo.common.uint256 import Uint256

@contract_interface
namespace IERC20 {
    func name() -> (name: felt) {
    }

    func symbol() -> (symbol: felt) {
    }

    func decimals() -> (decimals: felt) {
    }

    func totalSupply() -> (totalSupply: Uint256) {
    }

    func balanceOf(account: felt) -> (balance: Uint256) {
    }

    func allowance(owner: felt, spender: felt) -> (remaining: Uint256) {
    }

    func transfer(recipient: felt, amount: Uint256) -> (success: felt) {
    }

    func transferFrom(sender: felt, recipient: felt, amount: Uint256) -> (success: felt) {
    }

    func approve(spender: felt, amount: Uint256) -> (success: felt) {
    }
}

@contract_interface
namespace IERC20Mintable {
    func mint(recipient: felt, amount: Uint256) -> (success: felt) {
    }
}

@contract_interface
namespace IERC20Burnable {
    func burn(owner: felt, amount: Uint256) -> (success: felt) {
    }
}

// TODO: not even sure if these methods should be on USDa
@contract_interface
namespace IUSDa {
    func get_collateralization_ratio() -> (ratio: felt) {
    }

    func get_total_collateral() -> (total: felt) {
    }
}
