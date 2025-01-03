use opus::types::QuoteTokenInfo;
use starknet::ContractAddress;

#[starknet::interface]
pub trait IEkubo<TContractState> {
    // getters
    fn get_quote_tokens(self: @TContractState) -> Span<QuoteTokenInfo>;
    fn get_twap_duration(self: @TContractState) -> u64;
    // setters
    fn set_quote_tokens(ref self: TContractState, quote_tokens: Span<ContractAddress>);
    fn set_twap_duration(ref self: TContractState, twap_duration: u64);
}
