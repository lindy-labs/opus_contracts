use starknet::ContractAddress;

use aura::utils::wadray::Wad;

#[abi]
trait IEqualizer {
    // getter
    fn get_allocator() -> ContractAddress;
    fn get_surplus() -> Wad;
    // external
    fn set_allocator(allocator: ContractAddress);
    fn equalize() -> Wad;
}
