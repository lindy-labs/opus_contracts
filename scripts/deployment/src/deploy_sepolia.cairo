use deployment::{core_deployment, periphery_deployment, utils};
use opus::constants::{ETH_USD_PAIR_ID, STRK_USD_PAIR_ID};
use opus::core::roles;
use scripts::addresses;
use scripts::constants;
use sncast_std::{
    declare, DeclareResult, deploy, DeployResult, DisplayClassHash, DisplayContractAddress, invoke, InvokeResult,
    ScriptCommandError
};
use starknet::{ClassHash, ContractAddress};

fn main() {
    let admin: ContractAddress = addresses::sepolia::admin();

    println!("Deploying core contracts");
    //let shrine: ContractAddress = core_deployment::deploy_shrine(admin);
    let shrine: ContractAddress = core_deployment::deploy_shrine(admin);
    let flash_mint: ContractAddress = core_deployment::deploy_flash_mint(shrine);
    let sentinel: ContractAddress = core_deployment::deploy_sentinel(admin, shrine);
    let seer: ContractAddress = core_deployment::deploy_seer(admin, shrine, sentinel);
    let abbot: ContractAddress = core_deployment::deploy_abbot(shrine, sentinel);
    let absorber: ContractAddress = core_deployment::deploy_absorber(admin, shrine, sentinel);
    let purger: ContractAddress = core_deployment::deploy_purger(admin, shrine, sentinel, absorber, seer);
    let allocator: ContractAddress = core_deployment::deploy_allocator(admin);
    let equalizer: ContractAddress = core_deployment::deploy_equalizer(admin, shrine, allocator);
    let caretaker: ContractAddress = core_deployment::deploy_caretaker(admin, shrine, abbot, sentinel, equalizer);
    let controller: ContractAddress = core_deployment::deploy_controller(admin, shrine);

    // Deploy transmuter
    let usdc_transmuter_restricted: ContractAddress = core_deployment::deploy_transmuter_restricted(
        admin, shrine, addresses::sepolia::usdc(), admin, constants::USDC_TRANSMUTER_RESTRICTED_DEBT_CEILING
    );

    println!("Deploying gates");
    // there's no WBTC on Starknet Sepolia
    let gate_class_hash: ClassHash = core_deployment::declare_gate();
    let eth: ContractAddress = addresses::eth_addr();
    let strk: ContractAddress = addresses::strk_addr();
    let eth_gate: ContractAddress = core_deployment::deploy_gate(gate_class_hash, shrine, eth, sentinel, "ETH");
    let strk_gate: ContractAddress = core_deployment::deploy_gate(gate_class_hash, shrine, strk, sentinel, "STRK");

    println!("Deploying oracles");
    let pragma: ContractAddress = core_deployment::deploy_pragma(
        admin,
        addresses::sepolia::pragma_spot_oracle(),
        addresses::sepolia::pragma_twap_oracle(),
        constants::PRAGMA_FRESHNESS_THRESHOLD,
        constants::PRAGMA_SOURCES_THRESHOLD
    );

    utils::set_oracles_to_seer(seer, array![pragma].span());

    println!("Setting up roles");
    utils::grant_role(absorber, purger, roles::absorber_roles::purger(), "ABS -> PU");
    utils::grant_role(sentinel, abbot, roles::sentinel_roles::abbot(), "SE -> ABB");
    utils::grant_role(sentinel, purger, roles::sentinel_roles::purger(), "SE -> PU");
    utils::grant_role(sentinel, caretaker, roles::sentinel_roles::caretaker(), "SE -> CA");
    utils::grant_role(seer, purger, roles::seer_roles::purger(), "SEER -> PU");
    utils::grant_role(shrine, abbot, roles::shrine_roles::abbot(), "SHR -> ABB");
    utils::grant_role(shrine, caretaker, roles::shrine_roles::caretaker(), "SHR -> CA");
    utils::grant_role(shrine, controller, roles::shrine_roles::controller(), "SHR -> CTR");
    utils::grant_role(shrine, equalizer, roles::shrine_roles::equalizer(), "SHR -> EQ");
    utils::grant_role(shrine, flash_mint, roles::shrine_roles::flash_mint(), "SHR -> FM");
    utils::grant_role(shrine, purger, roles::shrine_roles::purger(), "SHR -> PU");
    utils::grant_role(shrine, seer, roles::shrine_roles::seer(), "SHR -> SEER");
    utils::grant_role(shrine, sentinel, roles::shrine_roles::sentinel(), "SHR -> SE");
    utils::grant_role(shrine, usdc_transmuter_restricted, roles::shrine_roles::transmuter(), "SHR -> TR[USDC]");

    // Adding ETH and STRK yangs
    println!("Setting up Shrine");

    utils::add_yang_to_sentinel(
        sentinel,
        eth,
        eth_gate,
        "ETH",
        constants::INITIAL_ETH_AMT,
        constants::INITIAL_ETH_ASSET_MAX,
        constants::INITIAL_ETH_THRESHOLD,
        constants::INITIAL_ETH_PRICE,
        constants::INITIAL_ETH_BASE_RATE,
    );

    utils::add_yang_to_sentinel(
        sentinel,
        strk,
        strk_gate,
        "STRK",
        constants::INITIAL_STRK_AMT,
        constants::INITIAL_STRK_ASSET_MAX,
        constants::INITIAL_STRK_THRESHOLD,
        constants::INITIAL_STRK_PRICE,
        constants::INITIAL_STRK_BASE_RATE,
    );

    // Set up debt ceiling and minimum trove value in Shrine
    let debt_ceiling: u128 = constants::INITIAL_DEBT_CEILING;
    let _set_debt_ceiling = invoke(
        shrine,
        selector!("set_debt_ceiling"),
        array![debt_ceiling.into()],
        Option::Some(constants::MAX_FEE),
        Option::None
    )
        .expect('set debt ceiling failed');

    println!("Debt ceiling set: {}", debt_ceiling);

    let minimum_trove_value: u128 = constants::MINIMUM_TROVE_VALUE;
    let _set_minimum_trove_value = invoke(
        shrine,
        selector!("set_minimum_trove_value"),
        array![minimum_trove_value.into()],
        Option::Some(constants::MAX_FEE),
        Option::None
    )
        .expect('set minimum trove value failed');

    println!("Minimum trove value set: {}", minimum_trove_value);

    // Set up oracles
    println!("Setting up oracles");
    utils::set_yang_pair_id_for_oracle(pragma, eth, ETH_USD_PAIR_ID);
    utils::set_yang_pair_id_for_oracle(pragma, strk, STRK_USD_PAIR_ID);

    // Peripheral deployment
    println!("Deploying periphery contracts");
    let frontend_data_provider: ContractAddress = periphery_deployment::deploy_frontend_data_provider(
        Option::None, admin, shrine, sentinel, abbot, purger
    );

    println!("-------------------------------------------------\n");
    println!("Abbot: {}", abbot);
    println!("Absorber: {}", absorber);
    println!("Allocator: {}", allocator);
    println!("Caretaker: {}", caretaker);
    println!("Controller: {}", controller);
    println!("Equalizer: {}", equalizer);
    println!("Flash Mint: {}", flash_mint);
    println!("Frontend Data Provider: {}", frontend_data_provider);
    println!("Gate[ETH]: {}", eth_gate);
    println!("Gate[STRK]: {}", strk_gate);
    println!("Pragma: {}", pragma);
    println!("Purger: {}", purger);
    println!("Seer: {}", seer);
    println!("Sentinel: {}", sentinel);
    println!("Shrine: {}", shrine);
    println!("Transmuter[USDC] (Restricted): {}", usdc_transmuter_restricted);
}
