use wadray::Wad;

#[starknet::interface]
pub trait IReceptor<TContractState> {
    // getters
    fn get_quotes(self: @TContractState) -> Span<Wad>;
    fn get_update_frequency(self: @TContractState) -> u64;
    // setters
    fn set_update_frequency(ref self: TContractState, new_frequency: u64);
    fn update_yin_price(ref self: TContractState);
}
