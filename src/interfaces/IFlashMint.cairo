use array::ArrayTrait;
use starknet::ContractAddress;

#[abi]
trait IFlashMint {
    fn max_flash_loan(token: ContractAddress) -> u256;
    fn flash_fee(token: ContractAddress, amount: u256) -> u256;
    fn flash_loan(
        receiver: ContractAddress,
        token: ContractAddress,
        amount: u256,
        calldata_arr: Array<felt252>
    ) -> bool;
}
