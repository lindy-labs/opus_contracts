use array::ArrayTrait;
use starknet::ContractAddress;

use aura::utils::wadray::Ray;

#[abi]
trait IAllocator {
    // getter
    fn get_allocation() -> (Array<ContractAddress>, Array<Ray>);
    // external
    fn set_allocation(recipients: Array<ContractAddress>, percentages: Array<Ray>);
}
