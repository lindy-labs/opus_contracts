use opus::types::QuoteTokenInfo;
use starknet::ContractAddress;
use wadray::Wad;

#[starknet::interface]
pub trait IReceptor<TContractState> {
    // getters
    fn get_oracle_extension(self: @TContractState) -> ContractAddress;
    fn get_quote_tokens(self: @TContractState) -> Span<QuoteTokenInfo>;
    fn get_quotes(self: @TContractState) -> Span<Wad>;
    fn get_twap_duration(self: @TContractState) -> u64;
    fn get_update_frequency(self: @TContractState) -> u64;
    // setters
    fn set_oracle_extension(ref self: TContractState, oracle_extension: ContractAddress);
    fn set_quote_tokens(ref self: TContractState, quote_tokens: Span<QuoteTokenInfo>);
    fn set_twap_duration(ref self: TContractState, twap_duration: u64);
    fn set_update_frequency(ref self: TContractState, new_frequency: u64);
    fn update_yin_price(ref self: TContractState);
}
