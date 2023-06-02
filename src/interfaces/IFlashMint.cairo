use starknet::ContractAddress;

use aura::utils::serde;

#[starknet::interface]
trait IFlashMint<TStorage> {
    fn max_flash_loan(self: @TStorage, token: ContractAddress) -> u256;
    fn flash_fee(self: @TStorage, token: ContractAddress, amount: u256) -> u256;
    fn flash_loan(
        ref self: TStorage,
        receiver: ContractAddress,
        token: ContractAddress,
        amount: u256,
        call_data: Span<felt252>
    ) -> bool;
}
