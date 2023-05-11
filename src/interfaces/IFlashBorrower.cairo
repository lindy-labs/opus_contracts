use starknet::ContractAddress;
use array::ArrayTrait;

#[abi]
trait IFlashBorrower {
    fn on_flash_loan(
        initiator: ContractAddress,
        token: ContractAddress,
        amount: u256,
        fee: u256,
        calldata_arr: Array<felt252>
    ) -> u256;
}
