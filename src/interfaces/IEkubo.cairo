use starknet::ContractAddress;
use wadray::Wad;

#[starknet::interface]
pub trait IEkubo<TContractState> {
    fn get_quotes(self: @TContractState, yang: ContractAddress) -> Span<Wad>;
}
