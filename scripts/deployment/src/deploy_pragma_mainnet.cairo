use deployment::{core_deployment, utils};
use scripts::{addresses, constants};
use sncast_std::DisplayContractAddress;
use starknet::ContractAddress;

fn main() {
    let admin: ContractAddress = addresses::mainnet::ADMIN;

    println!("Deploying Pragma adapter");

    let pragma: ContractAddress = core_deployment::deploy_pragma(
        admin,
        addresses::mainnet::PRAGMA_SPOT_ORACLE,
        addresses::mainnet::PRAGMA_TWAP_ORACLE,
        constants::PRAGMA_FRESHNESS_THRESHOLD,
    );

    println!("Pragma deployed at: {}", pragma);

    // Set yang pair settings for all onboarded collateral
    println!("Setting yang pair settings");

    // Core collateral
    utils::set_yang_pair_settings_for_oracle(pragma, addresses::ETH, constants::PRAGMA_ETH_PAIR_SETTINGS);
    utils::set_yang_pair_settings_for_oracle(pragma, addresses::STRK, constants::PRAGMA_STRK_PAIR_SETTINGS);
    utils::set_yang_pair_settings_for_oracle(pragma, addresses::mainnet::WBTC, constants::PRAGMA_WBTC_PAIR_SETTINGS);
    utils::set_yang_pair_settings_for_oracle(
        pragma, addresses::mainnet::WSTETH, constants::PRAGMA_WSTETH_PAIR_SETTINGS,
    );
    utils::set_yang_pair_settings_for_oracle(
        pragma, addresses::mainnet::WSTETH_CANONICAL, constants::PRAGMA_WSTETH_PAIR_SETTINGS,
    );
    utils::set_yang_pair_settings_for_oracle(pragma, addresses::mainnet::XSTRK, constants::PRAGMA_XSTRK_PAIR_SETTINGS);
    utils::set_yang_pair_settings_for_oracle(pragma, addresses::mainnet::SSTRK, constants::PRAGMA_SSTRK_PAIR_SETTINGS);
    utils::set_yang_pair_settings_for_oracle(
        pragma, addresses::mainnet::EKUBO_TOKEN, constants::PRAGMA_EKUBO_PAIR_SETTINGS,
    );
    utils::set_yang_pair_settings_for_oracle(
        pragma, addresses::mainnet::LORDS_TOKEN, constants::PRAGMA_LORDS_PAIR_SETTINGS,
    );
    utils::set_yang_pair_settings_for_oracle(
        pragma, addresses::mainnet::SURVIVOR_TOKEN, constants::PRAGMA_SURVIVOR_PAIR_SETTINGS,
    );
    utils::set_yang_pair_settings_for_oracle(
        pragma, addresses::mainnet::TBTC_TOKEN, constants::PRAGMA_TBTC_PAIR_SETTINGS,
    );
    utils::set_yang_pair_settings_for_oracle(
        pragma, addresses::mainnet::SOLVBTC_TOKEN, constants::PRAGMA_SOLVBTC_PAIR_SETTINGS,
    );
    utils::set_yang_pair_settings_for_oracle(
        pragma, addresses::mainnet::LBTC_TOKEN, constants::PRAGMA_LBTC_PAIR_SETTINGS,
    );
    utils::set_yang_pair_settings_for_oracle(
        pragma, addresses::mainnet::UNIBTC_TOKEN, constants::PRAGMA_UNIBTC_PAIR_SETTINGS,
    );
    utils::set_yang_pair_settings_for_oracle(
        pragma, addresses::mainnet::XWBTC_TOKEN, constants::PRAGMA_XWBTC_PAIR_SETTINGS,
    );
    utils::set_yang_pair_settings_for_oracle(
        pragma, addresses::mainnet::XTBTC_TOKEN, constants::PRAGMA_XTBTC_PAIR_SETTINGS,
    );
    utils::set_yang_pair_settings_for_oracle(
        pragma, addresses::mainnet::XSBTC_TOKEN, constants::PRAGMA_XSBTC_PAIR_SETTINGS,
    );
    utils::set_yang_pair_settings_for_oracle(
        pragma, addresses::mainnet::XLBTC_TOKEN, constants::PRAGMA_XLBTC_PAIR_SETTINGS,
    );

    println!("Yang pair settings configured");
    println!("Pragma: {}", pragma);
}
