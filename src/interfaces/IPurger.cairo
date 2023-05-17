use array::ArrayTrait;
use starknet::ContractAddress;

use aura::utils::wadray::{Ray, Wad};

#[abi]
trait IPurger {
    // view
    fn get_penalty(trove_id: u64) -> Ray;
    fn get_max_close_amount(trove_id: u64) -> u128;
    // external
    fn liquidate(
        trove_id: u64, purge_amt: Wad, recipient: ContractAddress
    ) -> (Array<ContractAddress>, Array<u128>);
    fn absorb(trove_id: u64) -> (Array<ContractAddress>, Array<u128>);
}
