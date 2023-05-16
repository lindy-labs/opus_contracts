use array::SpanTrait;
use starknet::ContractAddress;

use aura::utils::serde::SpanSerde;
use aura::utils::wadray::Ray;

#[abi]
trait IAllocator {
    // getter
    fn get_allocation() -> (Span<ContractAddress>, Span<Ray>);
    // external
    fn set_allocation(recipients: Span<ContractAddress>, percentages: Span<Ray>);
}
