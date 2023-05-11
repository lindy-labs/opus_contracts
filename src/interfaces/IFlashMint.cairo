use array::ArrayTrait;
use starknet::ContractAddress;

#[abi]
trait IFlashMint {
    fn maxFlashLoan(token: ContractAddress) -> u256;
    fn flashFee(token: ContractAddress, amount: u256) -> u256;
    fn flashLoan(
        receiver: ContractAddress,
        token: ContractAddress,
        amount: u256,
        calldata_arr: Array<felt252>
    ) -> bool;
}
