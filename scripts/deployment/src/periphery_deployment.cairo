use scripts::constants::MAX_FEE;
use sncast_std::{
    declare, DeclareResult, deploy, DeployResult, DisplayClassHash, DisplayContractAddress, invoke, InvokeResult,
    ScriptCommandError
};
use starknet::{ClassHash, ContractAddress};

//
// Deployment helpers
//

pub fn deploy_frontend_data_provider(
    admin: ContractAddress,
    shrine: ContractAddress,
    sentinel: ContractAddress,
    abbot: ContractAddress,
    purger: ContractAddress
) -> ContractAddress {
    let declare_frontend_data_provider = declare("frontend_data_provider", Option::Some(MAX_FEE), Option::None)
        .expect('failed FDP declare');
    let frontend_data_provider_calldata: Array<felt252> = array![
        admin.into(), shrine.into(), sentinel.into(), abbot.into(), purger.into()
    ];
    let deploy_frontend_data_provider = deploy(
        declare_frontend_data_provider.class_hash,
        frontend_data_provider_calldata,
        Option::None,
        true,
        Option::Some(MAX_FEE),
        Option::None
    )
        .expect('failed FDP deploy');

    deploy_frontend_data_provider.contract_address
}
