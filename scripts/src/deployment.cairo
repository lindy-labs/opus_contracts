use opus::core::roles::shrine_roles;
use sncast_std::{
    declare, deploy, invoke, call, DeclareResult, DeployResult, InvokeResult, CallResult, get_nonce,
    DisplayContractAddress, DisplayClassHash
};
use starknet::ContractAddress;

fn main() {
    println!("hello world");

    let admin: ContractAddress = 0x42044b3252fcdaeccfc2514c2b72107aed76855f7251469e2f105d97ec6b6e5
        .try_into()
        .expect('invalid address');

    let max_fee = 9999999999999999999;
    let salt = 0x3;

    // Declare and deploy Shrine

    let declare_shrine = declare("shrine", Option::Some(max_fee), Option::None).expect('failed shrine declare');
    let shrine_class_hash = declare_shrine.class_hash;

    println!("Class hash of Shrine: {}", shrine_class_hash);

    let nonce = get_nonce('latest');
    let shrine_calldata: Array<felt252> = array![admin.into(), 'Cash', 'CASH',];
    let deploy_shrine = deploy(
        shrine_class_hash, shrine_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    )
        .expect('failed shrine deploy');
    let shrine: ContractAddress = deploy_shrine.contract_address;

    println!("Deployed Shrine to address: {}", shrine);

    // Declare and deploy Flashmint

    let declare_flash_mint = declare("flash_mint", Option::Some(max_fee), Option::None)
        .expect('failed flash mint deploy');
    let flash_mint_class_hash = declare_flash_mint.class_hash;

    println!("Class hash of Flash Mint: {}", flash_mint_class_hash);

    let nonce = get_nonce('latest');
    let flash_mint_calldata: Array<felt252> = array![shrine.into()];
    let deploy_flash_mint = deploy(
        flash_mint_class_hash, flash_mint_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    )
        .expect('failed flash mint deploy');
    let flash_mint: ContractAddress = deploy_flash_mint.contract_address;

    println!("Deployed Flash Mint to address: {}", flash_mint);

    // Grant roles

    let invoke_nonce = get_nonce('pending');
    let grant_flash_mint_roles = invoke(
        shrine,
        selector!("grant_role"),
        array![shrine_roles::flash_mint().into(), flash_mint.into()],
        Option::Some(max_fee),
        Option::Some(invoke_nonce)
    )
        .expect('grant flash mint roles failed');

    println!("Flash Mint roles granted: {}", grant_flash_mint_roles.transaction_hash);
}
