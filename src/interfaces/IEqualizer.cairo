use starknet::ContractAddress;

use opus::utils::wadray::Wad;

#[starknet::interface]
trait IEqualizer<TContractState> {
    // getter
    fn get_allocator(self: @TContractState) -> ContractAddress;
    // external
    fn set_allocator(ref self: TContractState, allocator: ContractAddress);
    fn equalize(ref self: TContractState) -> Wad;
}
