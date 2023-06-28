use starknet::ContractAddress;

use aura::utils::wadray::Wad;

#[abi]
trait ISettler {
    // View
    fn get_outstanding_debt() -> Wad;
    // External
    fn record();
    fn settle(amt: Wad);
    fn recall();
}
