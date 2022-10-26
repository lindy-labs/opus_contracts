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

@contract_interface
namespace IEmpiricOracle {
    // https://docs.empiric.network/using-empiric/consuming-data#function-get_spot_median
    func get_spot_median(pair_id: felt) -> (
        price: felt, decimals: felt, last_updated_ts: felt, num_sources: felt
    ) {
    }
}

@contract_interface
namespace IFlashLender {
    func maxFlashLoan(token: felt) -> (amount: Uint256) {
    }

    func flashFee(token: felt, amount: Uint256) -> (fee: Uint256) {
    }

    func flashLoan(
        receiver: felt, token: felt, amount: Uint256, calldata_len: felt, calldata: felt*
    ) {
    }
}

@contract_interface
namespace IFlashBorrower {
    func onFlashLoan(
        initiator: felt,
        token: felt,
        amount: Uint256,
        fee: Uint256,
        calldata_len: felt,
        calldata: felt*,
    ) -> (hash: Uint256) {
    }
}
