use array::SpanTrait;
use starknet::ContractAddress;

use aura::utils::serde;
use aura::utils::wadray::Wad;


#[starknet::interface]
trait IAbbot<TStorage> {
    // getters
    fn get_trove_owner(self: @TStorage, trove_id: u64) -> ContractAddress;
    fn get_user_trove_ids(self: @TStorage, user: ContractAddress) -> Span<u64>;
    fn get_troves_count(self: @TStorage) -> u64;
    // external
    fn open_trove(
        ref self: TStorage, forge_amount: Wad, yangs: Span<ContractAddress>, amounts: Span<u128>
    );
    fn close_trove(ref self: TStorage, trove_id: u64);
    fn deposit(ref self: TStorage, yang: ContractAddress, trove_id: u64, amount: u128);
    fn withdraw(ref self: TStorage, yang: ContractAddress, trove_id: u64, amount: Wad);
    fn forge(ref self: TStorage, trove_id: u64, amount: Wad);
    fn melt(ref self: TStorage, trove_id: u64, amount: Wad);
}
