use starknet::ContractAddress;

use aura::utils::wadray::Wad;

#[starknet::interface]
trait IEqualizer<TStorage> {
    // getter
    fn get_allocator(self: @TStorage) -> ContractAddress;
    fn get_surplus(self: @TStorage) -> Wad;
    // external
    fn set_allocator(ref self: TStorage, allocator: ContractAddress);
    fn equalize(ref self: TStorage) -> Wad;
}
