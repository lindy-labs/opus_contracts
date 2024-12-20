use deployment::{core_deployment, utils};
use opus::external::roles::pragma_roles;
use scripts::addresses;
use scripts::constants;
use sncast_std::{invoke, InvokeResult, DisplayContractAddress};
use starknet::ContractAddress;

fn main() {
    let admin: ContractAddress = addresses::mainnet::admin();

    // Deploy gates
    let eth: ContractAddress = addresses::eth_addr();
    let strk: ContractAddress = addresses::strk_addr();
    let wbtc: ContractAddress = addresses::mainnet::wbtc();
    let wsteth: ContractAddress = addresses::mainnet::wsteth();
    let xstrk: ContractAddress = addresses::mainnet::xstrk();
    let sstrk: ContractAddress = addresses::mainnet::sstrk();

    println!("Deploying Pragma v2");
    let pragma: ContractAddress = core_deployment::deploy_pragma(
        admin,
        addresses::mainnet::pragma_spot_oracle(),
        addresses::mainnet::pragma_twap_oracle(),
        constants::PRAGMA_FRESHNESS_THRESHOLD,
        constants::PRAGMA_SOURCES_THRESHOLD
    );

    // This needs to be done with multisig
    //utils::set_oracles_to_seer(seer, array![pragma].span());

    // Set up oracles
    println!("Setting up oracles");
    utils::set_yang_pair_settings_for_oracle(pragma, eth, constants::pragma_eth_pair_settings());
    utils::set_yang_pair_settings_for_oracle(pragma, strk, constants::pragma_strk_pair_settings());
    utils::set_yang_pair_settings_for_oracle(pragma, wbtc, constants::pragma_wbtc_pair_settings());
    utils::set_yang_pair_settings_for_oracle(pragma, wsteth, constants::pragma_wsteth_pair_settings());
    utils::set_yang_pair_settings_for_oracle(pragma, xstrk, constants::pragma_xstrk_pair_settings());
    utils::set_yang_pair_settings_for_oracle(pragma, sstrk, constants::pragma_sstrk_pair_settings());

    // Transfer admin role to multisig
    let multisig: ContractAddress = addresses::mainnet::multisig();
    utils::transfer_admin_and_role(pragma, multisig, pragma_roles::default_admin_role(), "Pragma");

    // Print summary table of deployed contracts
    println!("-------------------------------------------------\n");
    println!("Deployed addresses");
    println!("Pragma v2: {}", pragma);
}
