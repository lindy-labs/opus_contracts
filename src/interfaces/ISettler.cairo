use starknet::ContractAddress;

use aura::utils::wadray::Wad;

#[abi]
trait ISettler {
    // View
    fn get_outstanding_debt() -> Wad;
    // External
    fn add_yang(yang: ContractAddress, initial_yang_amt: Wad, initial_asset_amt: u128);
    fn record();
    fn settle(amt: Wad);
    fn recall();
}
