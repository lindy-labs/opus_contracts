use scripts::addresses;
use scripts::constants::MAX_FEE;
use sncast_std::{DeclareResult, DisplayContractAddress, InvokeResult, declare, invoke};
use starknet::{ClassHash, ContractAddress};

fn main() {
    println!("Declaring new frontend data provider contract");

    let declare_frontend_data_provider = declare("frontend_data_provider", Option::Some(MAX_FEE), Option::None)
        .expect('failed FDP declare');

    println!("Upgrading frontend data provider with new class hash");

    let calldata: Array<felt252> = array![declare_frontend_data_provider.class_hash.into()];
    invoke(
        addresses::sepolia::frontend_data_provider(),
        selector!("upgrade"),
        calldata,
        Option::Some(MAX_FEE),
        Option::None,
    )
        .expect('upgrade failed');
}
