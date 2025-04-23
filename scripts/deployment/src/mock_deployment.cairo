use scripts::constants::MAX_FEE;
use sncast_std::{DeclareResultTrait, DisplayClassHash, DisplayContractAddress, FeeSettingsTrait, declare, deploy};
use starknet::{ClassHash, ContractAddress};


//
// Deployment helpers
//

pub fn deploy_mock_pragma() -> ContractAddress {
    let declare_mock_pragma = declare("mock_pragma", FeeSettingsTrait::max_fee(MAX_FEE), Option::None)
        .expect('failed mock_pragma declare');

    let deploy_mock_pragma = deploy(
        *declare_mock_pragma.class_hash(),
        array![],
        Option::None,
        true,
        FeeSettingsTrait::max_fee(MAX_FEE),
        Option::None,
    )
        .expect('failed mock pragma deploy');

    deploy_mock_pragma.contract_address
}

pub fn declare_erc20_mintable() -> ClassHash {
    *declare("erc20_mintable", FeeSettingsTrait::max_fee(MAX_FEE), Option::None)
        .expect('failed erc20 mintable declare')
        .class_hash()
}

pub fn deploy_erc20_mintable(
    class_hash: ClassHash,
    name: felt252,
    symbol: felt252,
    decimals: u8,
    initial_supply: u128,
    recipient: ContractAddress,
) -> ContractAddress {
    let calldata: Array<felt252> = array![name, symbol, decimals.into(), initial_supply.into(), 0, recipient.into()];
    let declare_erc20_mintable = deploy(
        class_hash, calldata, Option::None, true, FeeSettingsTrait::max_fee(MAX_FEE), Option::None,
    )
        .expect('failed erc20 mintable deploy');

    declare_erc20_mintable.contract_address
}
