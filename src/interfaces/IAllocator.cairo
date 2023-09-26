use starknet::ContractAddress;

use opus::utils::wadray::Ray;

#[starknet::interface]
trait IAllocator<TContractState> {
    // getter
    fn get_allocation(self: @TContractState) -> (Span<ContractAddress>, Span<Ray>);
    // external
    fn set_allocation(
        ref self: TContractState, recipients: Span<ContractAddress>, percentages: Span<Ray>
    );
}
