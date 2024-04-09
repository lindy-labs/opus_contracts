use sncast_std::{
    declare, deploy, invoke, call, DeclareResult, DeployResult, InvokeResult, CallResult, get_nonce,
    DisplayContractAddress, DisplayClassHash
};
use starknet::ContractAddress;

fn main() {
    println!("hello world");

    let admin: ContractAddress = 0x42044b3252fcdaeccfc2514c2b72107aed76855f7251469e2f105d97ec6b6e5.try_into().unwrap();

    let max_fee = 9999999999999999999;
    let salt = 0x3;

    let declare_shrine = declare("shrine", Option::Some(max_fee), Option::None).expect('failed shrine declare');
    let shrine_class_hash = declare_shrine.class_hash;

    println!("Class hash of Shrine: {}", shrine_class_hash);

    let nonce = get_nonce('latest');
    let shrine_calldata: Array<felt252> = array![admin.into(), 'Cash', 'CASH',];
    let deploy_shrine = deploy(
        shrine_class_hash, shrine_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    )
        .expect('failed shrine deploy');

    println!("Deployed Shrine to address: {}", deploy_shrine.contract_address);
}
