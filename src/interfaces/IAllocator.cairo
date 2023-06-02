use array::SpanTrait;
use starknet::ContractAddress;

use aura::utils::serde::SpanSerde;
use aura::utils::wadray::Ray;

#[starknet::interface]
trait IAllocator<TStorage> {
    // getter
    fn get_allocation(self: @TStorage) -> (Span<ContractAddress>, Span<Ray>);
    // external
    fn set_allocation(
        ref self: TStorage, recipients: Span<ContractAddress>, percentages: Span<Ray>
    );
}
