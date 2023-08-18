use starknet::ContractAddress;

use aura::utils::wadray::Wad;

#[starknet::interface]
trait IEqualizer<TContractState> {
    // getter
    fn get_allocator(self: @TContractState) -> ContractAddress;
    fn get_surplus(self: @TContractState) -> Wad;
    // external
    fn set_allocator(ref self: TContractState, allocator: ContractAddress);
    fn equalize(ref self: TContractState) -> Wad;
}
