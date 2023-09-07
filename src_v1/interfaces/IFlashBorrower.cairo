use array::SpanTrait;
use starknet::ContractAddress;

use aura::utils::serde::SpanSerde;

#[abi]
trait IFlashBorrower {
    fn on_flash_loan(
        initiator: ContractAddress,
        token: ContractAddress,
        amount: u256,
        fee: u256,
        call_data: Span<felt252>
    ) -> u256;
}
