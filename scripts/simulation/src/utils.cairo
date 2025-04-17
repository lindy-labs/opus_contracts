use core::num::traits::Bounded;
use scripts::constants::MAX_FEE;
use sncast_std::{FeeSettingsTrait, invoke};
use starknet::ContractAddress;


pub fn max_approve_token_for_gate(asset: ContractAddress, gate: ContractAddress) {
    let max_u128: u128 = Bounded::MAX;
    invoke(
        asset,
        selector!("approve"),
        array![gate.into(), max_u128.into(), max_u128.into()],
        FeeSettingsTrait::max_fee(MAX_FEE),
        Option::None,
    )
        .expect('max approve asset failed');
}
