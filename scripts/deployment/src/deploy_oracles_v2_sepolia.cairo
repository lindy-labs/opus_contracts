use deployment::{core_deployment, periphery_deployment, utils};
use opus::core::roles::{absorber_roles, seer_roles, sentinel_roles, shrine_roles};
use scripts::addresses;
use scripts::constants;
use sncast_std::{DisplayContractAddress, FeeSettingsTrait, invoke};
use starknet::ContractAddress;

fn main() {
    let deployment_addr: ContractAddress = addresses::sepolia::admin();
    let admin: ContractAddress = addresses::sepolia::admin();

    let abbot = addresses::sepolia::abbot();
    let shrine = addresses::sepolia::shrine();
    let sentinel = addresses::sepolia::sentinel();
    let absorber = addresses::sepolia::absorber();

    println!("Deploying contracts");

    // Skip Ekubo deployment for Sepolia - see comments for `core_deployment::deploy_ekubo(...)`.
    // let ekubo: ContractAddress = core_deployment::deploy_ekubo(admin, addresses::sepolia::ekubo_oracle_extension());

    let pragma: ContractAddress = core_deployment::deploy_pragma_v2(
        admin,
        addresses::sepolia::pragma_spot_oracle(),
        addresses::sepolia::pragma_twap_oracle(),
        constants::PRAGMA_FRESHNESS_THRESHOLD,
        constants::PRAGMA_SOURCES_THRESHOLD,
    );
    let seer: ContractAddress = core_deployment::deploy_seer_v2(deployment_addr, shrine, sentinel);
    let purger: ContractAddress = core_deployment::deploy_purger(admin, shrine, sentinel, absorber, seer);

    // Set up oracles
    println!("Setting up oracles");
    let eth: ContractAddress = addresses::eth_addr();
    let strk: ContractAddress = addresses::strk_addr();
    // let wbtc: ContractAddress = addresses::sepolia::wbtc();
    // let wsteth: ContractAddress = addresses::sepolia::wsteth();
    // let xstrk: ContractAddress = addresses::sepolia::xstrk();
    // let sstrk: ContractAddress = addresses::sepolia::sstrk();

    utils::set_yang_pair_settings_for_oracle(pragma, eth, constants::pragma_eth_pair_settings());
    utils::set_yang_pair_settings_for_oracle(pragma, strk, constants::pragma_strk_pair_settings());
    // utils::set_yang_pair_settings_for_oracle(pragma, wbtc, constants::pragma_wbtc_pair_settings());
    // utils::set_yang_pair_settings_for_oracle(pragma, wsteth, constants::pragma_wsteth_pair_settings());
    // utils::set_yang_pair_settings_for_oracle(pragma, xstrk, constants::pragma_xstrk_pair_settings());
    // utils::set_yang_pair_settings_for_oracle(pragma, sstrk, constants::pragma_sstrk_pair_settings());

    // Exclude Ekubo
    utils::set_oracles_to_seer(seer, array![pragma].span());

    utils::grant_role(seer, purger, seer_roles::purger(), "SEER -> PU");

    // Note: To be performed by admin
    //       The same roles should also be revoked from existing contracts
    utils::grant_role(absorber, purger, absorber_roles::purger(), "ABS -> PU");
    utils::grant_role(sentinel, purger, sentinel_roles::purger(), "SE -> PU");
    utils::grant_role(shrine, purger, shrine_roles::purger(), "SHR -> PU");
    utils::grant_role(shrine, seer, shrine_roles::seer(), "SHR -> SEER");

    // Revoke the same roles from existing contracts
    utils::revoke_role(absorber, addresses::sepolia::purger(), absorber_roles::purger(), "ABS -> PU");
    utils::revoke_role(sentinel, addresses::sepolia::purger(), sentinel_roles::purger(), "SE -> PU");
    utils::revoke_role(shrine, addresses::sepolia::purger(), shrine_roles::purger(), "SHR -> PU");
    utils::revoke_role(shrine, addresses::sepolia::seer(), shrine_roles::seer(), "SHR -> SEER");

    // Update prices
    println!("Updating prices");
    let _update_prices = invoke(
        seer, selector!("execute_task"), array![], FeeSettingsTrait::max_fee(constants::MAX_FEE), Option::None,
    )
        .expect('update prices failed');

    // Peripheral deployment
    println!("Deploying periphery contracts");
    let frontend_data_provider: ContractAddress = periphery_deployment::deploy_frontend_data_provider(
        Option::Some(addresses::frontend_data_provider_class_hash()), admin, shrine, sentinel, abbot, purger,
    );

    // Transfer admin role to admin
    // utils::transfer_admin_and_role(pragma, admin, pragma_roles::default_admin_role(), "Pragma");
    // utils::transfer_admin_and_role(seer, admin, seer_roles::default_admin_role(), "Seer");

    // Print summary table of deployed contracts
    println!("-------------------------------------------------\n");
    println!("Deployed addresses");
    //println!("Ekubo: {}", ekubo);
    println!("Frontend Data Provider: {}", frontend_data_provider);
    println!("Pragma v2: {}", pragma);
    println!("Purger: {}", purger);
    println!("Seer v2: {}", seer);
}
