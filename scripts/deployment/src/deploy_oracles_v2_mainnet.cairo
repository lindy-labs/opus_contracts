use deployment::{core_deployment, periphery_deployment, utils};
use opus::core::roles::{purger_roles, seer_roles, sentinel_roles, shrine_roles};
use opus::external::roles::pragma_roles;
use opus::periphery::roles::frontend_data_provider_roles;
use scripts::addresses;
use scripts::constants;
use sncast_std::{deploy, DeployResult, invoke, InvokeResult, DisplayContractAddress};
use starknet::{ClassHash, ContractAddress};

fn main() {
    let deployment_addr: ContractAddress = addresses::mainnet::admin();
    let multisig: ContractAddress = addresses::mainnet::multisig();

    let abbot = addresses::mainnet::abbot();
    let shrine = addresses::mainnet::shrine();
    let sentinel = addresses::mainnet::sentinel();
    let absorber = addresses::mainnet::absorber();

    println!("Deploying contracts");

    let ekubo: ContractAddress = core_deployment::deploy_ekubo(multisig, addresses::mainnet::ekubo_oracle_extension());

    let pragma: ContractAddress = core_deployment::deploy_pragma_v2(
        deployment_addr,
        addresses::mainnet::pragma_spot_oracle(),
        addresses::mainnet::pragma_twap_oracle(),
        constants::PRAGMA_FRESHNESS_THRESHOLD,
        constants::PRAGMA_SOURCES_THRESHOLD
    );
    let seer: ContractAddress = core_deployment::deploy_seer_v2(deployment_addr, shrine, sentinel);

    let purger_class_hash: ClassHash = 0x020edc26d65626a79f17d96e07d638b790c57435f9ffe0b1c446cc617a1b2d82
        .try_into()
        .unwrap();
    let purger_calldata: Array<felt252> = array![
        multisig.into(), shrine.into(), sentinel.into(), absorber.into(), seer.into()
    ];
    let purger = deploy(
        purger_class_hash, purger_calldata, Option::None, true, Option::Some(constants::MAX_FEE), Option::None
    )
        .expect('failed purger deploy')
        .contract_address;

    // Set up oracles
    println!("Setting up oracles");
    let eth: ContractAddress = addresses::eth_addr();
    let strk: ContractAddress = addresses::strk_addr();
    let wbtc: ContractAddress = addresses::mainnet::wbtc();
    let wsteth: ContractAddress = addresses::mainnet::wsteth();
    let xstrk: ContractAddress = addresses::mainnet::xstrk();
    let sstrk: ContractAddress = addresses::mainnet::sstrk();

    utils::set_yang_pair_settings_for_oracle(pragma, eth, constants::pragma_eth_pair_settings());
    utils::set_yang_pair_settings_for_oracle(pragma, strk, constants::pragma_strk_pair_settings());
    utils::set_yang_pair_settings_for_oracle(pragma, wbtc, constants::pragma_wbtc_pair_settings());
    utils::set_yang_pair_settings_for_oracle(pragma, wsteth, constants::pragma_wsteth_pair_settings());
    utils::set_yang_pair_settings_for_oracle(pragma, xstrk, constants::pragma_xstrk_pair_settings());
    utils::set_yang_pair_settings_for_oracle(pragma, sstrk, constants::pragma_sstrk_pair_settings());

    utils::set_oracles_to_seer(seer, array![pragma, ekubo].span());

    utils::grant_role(seer, purger, seer_roles::purger(), "SEER -> PU");

    // Note: To be performed by multisig
    //       The same roles should also be revoked from existing contracts
    // utils::grant_role(absorber, purger, absorber_roles::purger(), "ABS -> PU");
    // utils::grant_role(sentinel, purger, sentinel_roles::purger(), "SE -> PU");
    // utils::grant_role(shrine, purger, shrine_roles::purger(), "SHR -> PU");
    // utils::grant_role(shrine, seer, shrine_roles::seer(), "SHR -> SEER");

    // utils::revoke_role(absorber, addresses::mainnet::purger(), absorber_roles::purger(), "ABS -> PU");
    // utils::revoke_role(sentinel, addresses::mainnet::purger(), sentinel_roles::purger(), "SE -> PU");
    // utils::revoke_role(shrine, addresses::mainnet::purger(), shrine_roles::purger(), "SHR -> PU");
    // utils::revoke_role(shrine, addresses::mainnet::seer(), shrine_roles::seer(), "SHR -> SEER");

    // Update prices
    // println!("Updating prices");
    // let _update_prices = invoke(
    //     seer, selector!("execute_task"), array![], Option::Some(constants::MAX_FEE), Option::None
    // )
    //     .expect('update prices failed');

    // Peripheral deployment
    println!("Deploying periphery contracts");
    let frontend_data_provider: ContractAddress = periphery_deployment::deploy_frontend_data_provider(
        Option::Some(addresses::frontend_data_provider_class_hash()), multisig, shrine, sentinel, abbot, purger
    );

    // Transfer admin role to multisig
    utils::transfer_admin_and_role(pragma, multisig, pragma_roles::default_admin_role(), "Pragma");
    utils::transfer_admin_and_role(seer, multisig, seer_roles::default_admin_role(), "Seer");

    // Print summary table of deployed contracts
    println!("-------------------------------------------------\n");
    println!("Deployed addresses");
    println!("Ekubo: {}", ekubo);
    println!("Frontend Data Provider: {}", frontend_data_provider);
    println!("Pragma v2: {}", pragma);
    println!("Purger: {}", purger);
    println!("Seer v2: {}", seer);
}
