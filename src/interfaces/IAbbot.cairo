use array::SpanTrait;
use starknet::ContractAddress;

use aura::utils::serde;
use aura::utils::wadray::Wad;


#[abi]
trait IAbbot {
    // getters
    fn get_trove_owner(trove_id: u64) -> ContractAddress;
    fn get_user_trove_ids(user: ContractAddress) -> Span<u64>;
    fn get_troves_count() -> u64;
    // external
    fn open_trove(
        forge_amount: Wad, yangs: Span<ContractAddress>, amounts: Span<u128>, max_forge_fee_pct: Wad
    );
    fn close_trove(trove_id: u64);
    fn deposit(yang: ContractAddress, trove_id: u64, amount: u128);
    fn withdraw(yang: ContractAddress, trove_id: u64, amount: Wad);
    fn forge(trove_id: u64, amount: Wad, max_forge_fee_pct: Wad);
    fn melt(trove_id: u64, amount: Wad);
}
