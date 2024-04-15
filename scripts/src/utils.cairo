use deployment::constants::MAX_FEE;
use sncast_std::{DisplayContractAddress, get_nonce, invoke, InvokeResult};
use starknet::{ContractAddress};


pub fn grant_role(target: ContractAddress, receiver: ContractAddress, role: u128, msg: ByteArray) {
    let invoke_nonce = get_nonce('pending');
    let _grant_role = invoke(
        target,
        selector!("grant_role"),
        array![role.into(), receiver.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role failed');

    println!("Role granted: {}", msg);
}


pub fn add_yang_to_sentinel(
    sentinel: ContractAddress,
    asset: ContractAddress,
    gate: ContractAddress,
    asset_name: ByteArray,
    initial_asset_amt: u128,
    initial_asset_max: u128,
    initial_threshold: u128,
    initial_price: u128,
    initial_base_rate: u128,
) {
    println!("Approving initial amount: {}", asset_name);

    let invoke_nonce = get_nonce('pending');
    let _approve_token = invoke(
        asset,
        selector!("approve"),
        array![sentinel.into(), initial_asset_amt.into(), 0],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce),
    )
        .expect('approve asset failed');

    let add_yang_calldata: Array<felt252> = array![
        asset.into(),
        initial_asset_max.into(),
        initial_threshold.into(),
        initial_price.into(),
        initial_base_rate.into(),
        gate.into(),
    ];
    let invoke_nonce = get_nonce('pending');
    let _add_yang = invoke(
        sentinel, selector!("add_yang"), add_yang_calldata, Option::Some(MAX_FEE), Option::Some(invoke_nonce)
    )
        .expect('add yang failed');

    println!("Yang successfully added: {}", asset_name)
}
