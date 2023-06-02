use array::SpanTrait;
use starknet::ContractAddress;

use aura::utils::serde::SpanSerde;

#[starknet::interface]
trait IFlashBorrower<TStorage> {
    fn on_flash_loan(
        ref self: TStorage,
        initiator: ContractAddress,
        token: ContractAddress,
        amount: u256,
        fee: u256,
        call_data: Span<felt252>
    ) -> u256;
}
