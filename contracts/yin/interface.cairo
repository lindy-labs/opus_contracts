%lang starknet

from contracts.lib.aliases import bool, str, ufelt, wad

@contract_interface
namespace IYin {
    func name() -> (str: felt) {
    }

    func symbol() -> (str: felt) {
    }

    func decimals() -> (ufelt: felt) {
    }

    func totalSupply() -> (totalSupply: felt) {
    }

    func balanceOf(account: felt) -> (wad: felt) {
    }

    func allowance(owner: felt, spender: felt) -> (wad: felt) {
    }

    func transfer(recipient: felt, amount: felt) -> (bool: felt) {
    }

    func transferFrom(sender: felt, recipient: felt, amount: felt) -> (bool: felt) {
    }

    func approve(spender: felt, amount: felt) -> (bool: felt) {
    }
}
