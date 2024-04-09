use sncast_std::{
    declare, deploy, invoke, call, DeclareResult, DeployResult, InvokeResult, CallResult, get_nonce,
    DisplayContractAddress, DisplayClassHash
};


// The example below uses a contract deployed to the Goerli testnet
fn main() {
    println!("hello world");

    let max_fee = 99999999999999999;
    let salt = 0x3;

    println!("declaring");
    let declare_result = declare("shrine", Option::Some(max_fee), Option::None).expect('shrine already declared');
    let nonce = get_nonce('latest');
    let class_hash = declare_result.class_hash;

    println!("Class hash of the declared Shrine: {}", declare_result.class_hash);

    println!("declared");
}
