use sncast_std::{
    declare, deploy, invoke, call, DeclareResult, DeployResult, InvokeResult, CallResult, get_nonce,
    DisplayContractAddress, DisplayClassHash
};

fn main() {
    println!("hello world");

    let max_fee = 9999999999999999999;
    let salt = 0x3;

    let declare_result = declare("shrine", Option::Some(max_fee), Option::None).expect('failed shrine declare');

    let nonce = get_nonce('latest');
    let class_hash = declare_result.class_hash;

    println!("Class hash of the declared contract: {}", declare_result.class_hash);
}
