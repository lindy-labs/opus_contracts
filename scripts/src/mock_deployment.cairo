use deployment::constants::{MAX_FEE, SALT};
use deployment::constants;
use sncast_std::{
    declare, DeclareResult, deploy, DeployResult, DisplayClassHash, DisplayContractAddress, get_nonce, invoke,
    InvokeResult
};
use starknet::{ClassHash, ContractAddress};


//
// Deployment helpers
//

pub fn deploy_mock_pragma() -> ContractAddress {
    let declare_mock_pragma = declare("mock_pragma", Option::Some(MAX_FEE), Option::None)
        .expect('failed mock_pragma declare');

    println!("Class hash of mock Pragma: {}", declare_mock_pragma.class_hash);

    let nonce = get_nonce('latest');
    let deploy_mock_pragma = deploy(
        declare_mock_pragma.class_hash, array![], Option::Some(SALT), true, Option::Some(MAX_FEE), Option::Some(nonce)
    )
        .expect('failed mock pragma deploy');

    println!("Deployed mock Pragma to address: {}", deploy_mock_pragma.contract_address);

    deploy_mock_pragma.contract_address
}

pub fn deploy_mock_switchboard() -> ContractAddress {
    let declare_mock_switchboard = declare("mock_switchboard", Option::Some(MAX_FEE), Option::None)
        .expect('failed mock_switchboard declare');

    println!("Class hash of mock Switchboard: {}", declare_mock_switchboard.class_hash);

    let nonce = get_nonce('latest');
    let deploy_mock_switchboard = deploy(
        declare_mock_switchboard.class_hash,
        array![],
        Option::Some(SALT),
        true,
        Option::Some(MAX_FEE),
        Option::Some(nonce)
    )
        .expect('failed mock switchboard deploy');

    println!("Deployed mock Switchboard to address: {}", deploy_mock_switchboard.contract_address);

    deploy_mock_switchboard.contract_address
}

pub fn declare_erc20_mintable() -> ClassHash {
    let declare_erc20_mintable = declare("erc20_mintable", Option::Some(MAX_FEE), Option::None)
        .expect('failed mock_switchboard declare');

    println!("Class hash of mock Switchboard: {}", declare_erc20_mintable.class_hash);

    declare_erc20_mintable.class_hash
}

pub fn deploy_erc20_mintable(
    class_hash: ClassHash,
    name: felt252,
    symbol: felt252,
    decimals: u8,
    initial_supply: u128,
    recipient: ContractAddress
) -> ContractAddress {
    let nonce = get_nonce('latest');
    let calldata: Array<felt252> = array![name, symbol, decimals.into(), initial_supply.into(), 0, recipient.into()];
    let declare_erc20_mintable = deploy(
        class_hash, calldata, Option::Some(SALT), true, Option::Some(MAX_FEE), Option::Some(nonce)
    )
        .expect('failed erc20 mintable deploy');

    println!("Deployed ERC20 {} to address: {}", symbol, declare_erc20_mintable.contract_address);

    declare_erc20_mintable.contract_address
}
