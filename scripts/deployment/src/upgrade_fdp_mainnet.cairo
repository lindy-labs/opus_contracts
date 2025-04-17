use deployment::periphery_deployment;
use scripts::addresses;
use scripts::constants::MAX_FEE;
use sncast_std::{DeclareResultTrait, DisplayContractAddress, InvokeResult, declare, invoke};
use starknet::{ClassHash, ContractAddress};

fn main() {
    println!("Declaring new frontend data provider contract");

    let declare_frontend_data_provider = declare(
        "frontend_data_provider", FeeSettingsTrait::max_fee(MAX_FEE), Option::None,
    )
        .expect('failed FDP declare');

    println!("Upgrading frontend data provider with new class hash");

    let deployment_addr: ContractAddress = addresses::mainnet::ADMIN;
    let shrine: ContractAddress = addresses::mainnet::SHRINE;
    let sentinel: ContractAddress = addresses::mainnet::SENTINEL;
    let abbot: ContractAddress = addresses::mainnet::ABBOT;
    let purger: ContractAddress = addresses::mainnet::PURGER;

    let frontend_data_provider: ContractAddress = periphery_deployment::deploy_frontend_data_provider(
        Option::Some(*declare_frontend_data_provider.class_hash()), deployment_addr, shrine, sentinel, abbot, purger,
    );

    println!("Frontend Data Provider: {}", frontend_data_provider);
}
