use core::array::ArrayTrait;
use scripts::constants::MAX_FEE;
use sncast_std::{DisplayContractAddress, invoke, InvokeResult};
use starknet::ContractAddress;

pub fn grant_role(target: ContractAddress, receiver: ContractAddress, role: u128, msg: ByteArray) {
    let _grant_role = invoke(
        target, selector!("grant_role"), array![role.into(), receiver.into()], Option::Some(MAX_FEE), Option::None
    )
        .expect('grant role failed');

    println!("Role granted: {}", msg);
}

pub fn transfer_admin_and_role(
    target: ContractAddress, new_admin: ContractAddress, role: u128, module_name: ByteArray
) {
    let _grant_admin_role = invoke(
        target, selector!("grant_role"), array![role.into(), new_admin.into()], Option::Some(MAX_FEE), Option::None
    )
        .expect('grant role to new admin failed');

    let _renounce_admin_role = invoke(
        target, selector!("renounce_role"), array![role.into()], Option::Some(MAX_FEE), Option::None
    )
        .expect('renounce role failed');

    let _transfer_admin = invoke(
        target, selector!("set_pending_admin"), array![new_admin.into()], Option::Some(MAX_FEE), Option::None
    )
        .expect('set pending admin failed');

    println!("Set pending admin for: {}", module_name);
}

pub fn set_oracles_to_seer(seer: ContractAddress, mut oracles: Span<ContractAddress>) {
    let mut calldata: Array<felt252> = Default::default();
    calldata.append(oracles.len().into());
    while let Option::Some(oracle) = oracles.pop_front() {
        calldata.append((*oracle).into());
    };

    let _set_oracles = invoke(seer, selector!("set_oracles"), calldata, Option::Some(MAX_FEE), Option::None)
        .expect('set oracles failed');

    println!("Oracles set");
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

    let _approve_token = invoke(
        asset,
        selector!("approve"),
        array![sentinel.into(), initial_asset_amt.into(), 0],
        Option::Some(MAX_FEE),
        Option::None,
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
    let _add_yang = invoke(sentinel, selector!("add_yang"), add_yang_calldata, Option::Some(MAX_FEE), Option::None)
        .expect('add yang failed');

    println!("Yang successfully added: {}", asset_name)
}

pub fn set_yang_pair_id_for_oracle(oracle: ContractAddress, yang: ContractAddress, pair_id: felt252) {
    let _set_yang_pair_id = invoke(
        oracle, selector!("set_yang_pair_id"), array![yang.into(), pair_id], Option::Some(MAX_FEE), Option::None,
    )
        .expect('set yang pair id failed');
}

