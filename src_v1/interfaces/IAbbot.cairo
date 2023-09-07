use array::SpanTrait;
use starknet::ContractAddress;

use aura::utils::serde;
use aura::utils::types::AssetBalance;
use aura::utils::wadray::Wad;


#[abi]
trait IAbbot {
    // getters
    fn get_trove_owner(trove_id: u64) -> ContractAddress;
    fn get_user_trove_ids(user: ContractAddress) -> Span<u64>;
    fn get_troves_count() -> u64;
    // external
    fn open_trove(
        yang_assets: Span<AssetBalance>, forge_amount: Wad, max_forge_fee_pct: Wad
    ) -> u64;
    fn close_trove(trove_id: u64);
    fn deposit(trove_id: u64, yang_asset: AssetBalance);
    fn withdraw(trove_id: u64, yang_asset: AssetBalance);
    fn forge(trove_id: u64, amount: Wad, max_forge_fee_pct: Wad);
    fn melt(trove_id: u64, amount: Wad);
}
