use starknet::ContractAddress;

#[starknet::interface]
trait ISwitchboard<TContractState> {
    fn set_yang_pair_id(ref self: TContractState, yang: ContractAddress, pair_id: felt252);
}
