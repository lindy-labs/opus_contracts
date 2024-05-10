use core::array::ArrayTrait;
use core::integer::BoundedInt;
use deployment::constants::MAX_FEE;
use sncast_std::{DisplayContractAddress, invoke, InvokeResult};
use starknet::ContractAddress;


pub fn max_approve_token_for_gate(asset: ContractAddress, gate: ContractAddress) {
    let max_u128: u128 = BoundedInt::max();
    invoke(
        asset,
        selector!("approve"),
        array![gate.into(), max_u128.into(), max_u128.into()],
        Option::Some(MAX_FEE),
        Option::None,
    )
        .expect('max approve asset failed');
}
