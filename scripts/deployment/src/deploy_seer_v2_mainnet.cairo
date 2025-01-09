use deployment::{core_deployment, periphery_deployment, utils};
use opus::core::roles::{purger_roles, seer_roles, sentinel_roles, shrine_roles};
use opus::periphery::roles::frontend_data_provider_roles;
use scripts::addresses;
use scripts::constants;
use sncast_std::{invoke, InvokeResult, DisplayContractAddress};
use starknet::ContractAddress;

fn main() {
    let admin: ContractAddress = addresses::mainnet::admin();

    let abbot = addresses::mainnet::abbot();
    let shrine = addresses::mainnet::shrine();
    let sentinel = addresses::mainnet::sentinel();
    let absorber = addresses::mainnet::absorber();

    println!("Deploying contracts");

    let seer: ContractAddress = core_deployment::deploy_seer_v2(admin, shrine, sentinel);
    let purger: ContractAddress = core_deployment::deploy_purger(admin, shrine, sentinel, absorber, seer);

    // TODO: Uncomment after Pragma v2 has been deployed
    //utils::set_oracles_to_seer(seer, array![address::mainnet::pragma_v2()].span());

    utils::grant_role(seer, purger, seer_roles::purger(), "SEER -> PU");

    // Note: To be performed by multisig
    // utils::grant_role(absorber, purger, absorber_roles::purger(), "ABS -> PU");
    // utils::grant_role(sentinel, purger, sentinel_roles::purger(), "SE -> PU");
    // utils::grant_role(shrine, purger, shrine_roles::purger(), "SHR -> PU");
    // utils::grant_role(shrine, seer, shrine_roles::seer(), "SHR -> SEER");

    // Update prices
    println!("Updating prices");
    let _update_prices = invoke(
        seer, selector!("execute_task"), array![], Option::Some(constants::MAX_FEE), Option::None
    )
        .expect('update prices failed');

    // Peripheral deployment
    println!("Deploying periphery contracts");
    let frontend_data_provider: ContractAddress = periphery_deployment::deploy_frontend_data_provider(
        admin, shrine, sentinel, abbot, purger
    );

    // Transfer admin role to multisig
    let multisig: ContractAddress = addresses::mainnet::multisig();
    utils::transfer_admin_and_role(purger, multisig, purger_roles::default_admin_role(), "Purger");
    utils::transfer_admin_and_role(seer, multisig, seer_roles::default_admin_role(), "Seer");
    utils::transfer_admin_and_role(
        frontend_data_provider, multisig, frontend_data_provider_roles::default_admin_role(), "FDP"
    );

    // Print summary table of deployed contracts
    println!("-------------------------------------------------\n");
    println!("Deployed addresses");
    println!("Frontend Data Provider: {}", frontend_data_provider);
    println!("Purger: {}", purger);
    println!("Seer: {}", seer);
}
