use starknet::ContractAddress;
use array::ArrayTrait;

#[abi]
trait IFlashBorrower {
    fn onFlashLoan(
        initiator: ContractAddress,
        token: ContractAddress,
        amount: u256,
        fee: u256,
        calldata_arr: Array<felt252>
    ) -> u256;
}
