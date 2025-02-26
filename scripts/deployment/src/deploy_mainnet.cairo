use deployment::{core_deployment, periphery_deployment, utils};
use opus::constants::{ETH_USD_PAIR_ID, PRAGMA_DECIMALS, STRK_USD_PAIR_ID, WBTC_USD_PAIR_ID, WSTETH_USD_PAIR_ID};
use opus::core::roles::{
    absorber_roles, allocator_roles, caretaker_roles, controller_roles, equalizer_roles, purger_roles, seer_roles,
    sentinel_roles, shrine_roles, transmuter_roles
};
use opus::external::roles::pragma_roles;
use scripts::addresses;
use scripts::constants;
use sncast_std::{call, CallResult, invoke, InvokeResult, DisplayContractAddress};
use starknet::{ClassHash, ContractAddress};
use wadray::RAY_PERCENT;


fn main() {
    let admin: ContractAddress = addresses::mainnet::admin();

    println!("Deploying contracts");

    // Deploy core contracts for launch
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

    // Deploy core contracts after launch
    let receptor: ContractAddress = core_deployment::deploy_receptor(addresses::mainnet::multisig(), shrine);

    // Deploy transmuter
    let usdc_transmuter_restricted: ContractAddress = core_deployment::deploy_transmuter_restricted(
        admin, shrine, addresses::mainnet::usdc(), admin, constants::USDC_TRANSMUTER_RESTRICTED_DEBT_CEILING
    );

    // Deploy gates
    println!("Deploying Gates");
    let gate_class_hash: ClassHash = core_deployment::declare_gate();
    let eth: ContractAddress = addresses::eth_addr();
    let strk: ContractAddress = addresses::strk_addr();
    let wbtc: ContractAddress = addresses::mainnet::wbtc();
    let wsteth: ContractAddress = addresses::mainnet::wsteth();
    let xstrk: ContractAddress = addresses::mainnet::xstrk();
    let sstrk: ContractAddress = addresses::mainnet::sstrk();
    let wsteth_canonical: ContractAddress = addresses::mainnet::wsteth_canonical();

    let eth_gate: ContractAddress = core_deployment::deploy_gate(gate_class_hash, shrine, eth, sentinel, "ETH");
    let strk_gate: ContractAddress = core_deployment::deploy_gate(gate_class_hash, shrine, strk, sentinel, "STRK");
    let wbtc_gate: ContractAddress = core_deployment::deploy_gate(gate_class_hash, shrine, wbtc, sentinel, "WBTC");
    let wsteth_gate: ContractAddress = core_deployment::deploy_gate(
        gate_class_hash, shrine, wsteth, sentinel, "WSTETH"
    );
    let xstrk_gate: ContractAddress = core_deployment::deploy_gate(gate_class_hash, shrine, xstrk, sentinel, "xSTRK");
    let sstrk_gate: ContractAddress = core_deployment::deploy_gate(gate_class_hash, shrine, sstrk, sentinel, "sSTRK");
    let wsteth_canonical_gate: ContractAddress = core_deployment::deploy_gate(
        gate_class_hash, shrine, wsteth_canonical, sentinel, "WSTETH"
    );

    println!("Deploying oracles");
    let pragma: ContractAddress = core_deployment::deploy_pragma(
        admin,
        addresses::mainnet::pragma_spot_oracle(),
        addresses::mainnet::pragma_twap_oracle(),
        constants::PRAGMA_FRESHNESS_THRESHOLD,
        constants::PRAGMA_SOURCES_THRESHOLD
    );
    utils::set_oracles_to_seer(seer, array![pragma].span());

    // Grant roles
    println!("Setting up roles");

    utils::grant_role(absorber, purger, absorber_roles::purger(), "ABS -> PU");

    utils::grant_role(sentinel, abbot, sentinel_roles::abbot(), "SE -> ABB");
    utils::grant_role(sentinel, purger, sentinel_roles::purger(), "SE -> PU");
    utils::grant_role(sentinel, caretaker, sentinel_roles::caretaker(), "SE -> CA");
    utils::grant_role(seer, purger, seer_roles::purger(), "SEER -> PU");
    utils::grant_role(shrine, abbot, shrine_roles::abbot(), "SHR -> ABB");
    utils::grant_role(shrine, caretaker, shrine_roles::caretaker(), "SHR -> CA");
    utils::grant_role(shrine, controller, shrine_roles::controller(), "SHR -> CTR");
    utils::grant_role(shrine, equalizer, shrine_roles::equalizer(), "SHR -> EQ");
    utils::grant_role(shrine, flash_mint, shrine_roles::flash_mint(), "SHR -> FM");
    utils::grant_role(shrine, purger, shrine_roles::purger(), "SHR -> PU");
    utils::grant_role(shrine, seer, shrine_roles::seer(), "SHR -> SEER");
    utils::grant_role(shrine, sentinel, shrine_roles::sentinel(), "SHR -> SE");
    utils::grant_role(shrine, usdc_transmuter_restricted, shrine_roles::transmuter(), "SHR -> TR[USDC]");

    // Adding ETH, STRK, WBTC and WSTETH yangs
    // The admin role has been transferred to the multisig so any new collateral needs to 
    // be added with the multisig.
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

    utils::add_yang_to_sentinel(
        sentinel,
        wbtc,
        wbtc_gate,
        "WBTC",
        constants::INITIAL_WBTC_AMT,
        constants::INITIAL_WBTC_ASSET_MAX,
        constants::INITIAL_WBTC_THRESHOLD,
        constants::INITIAL_WBTC_PRICE,
        constants::INITIAL_WBTC_BASE_RATE,
    );

    utils::add_yang_to_sentinel(
        sentinel,
        wsteth,
        wsteth_gate,
        "WSTETH",
        constants::INITIAL_WSTETH_AMT,
        constants::INITIAL_WSTETH_ASSET_MAX,
        constants::INITIAL_WSTETH_THRESHOLD,
        constants::INITIAL_WSTETH_PRICE,
        constants::INITIAL_WSTETH_BASE_RATE,
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
    utils::set_yang_pair_id_for_oracle(pragma, wbtc, WBTC_USD_PAIR_ID);
    utils::set_yang_pair_id_for_oracle(pragma, wsteth, WSTETH_USD_PAIR_ID);

    // The admin role has been transferred to the multisig so any new pair IDs 
    // need to be added with the multisig.

    // Set initial allocation
    let twenty_pct: felt252 = (20 * RAY_PERCENT).into();
    let eighty_pct: felt252 = (80 * RAY_PERCENT).into();
    let _set_allocation = invoke(
        allocator,
        selector!("set_allocation"),
        array![2, addresses::mainnet::multisig().into(), absorber.into(), 2, twenty_pct, eighty_pct],
        Option::Some(constants::MAX_FEE),
        Option::None
    )
        .expect('set allocation failed');
    println!("Allocation updated");

    // Update prices
    println!("Updating prices");
    let _update_prices = invoke(
        seer, selector!("execute_task"), array![], Option::Some(constants::MAX_FEE), Option::None
    )
        .expect('update prices failed');

    // Peripheral deployment
    println!("Deploying periphery contracts");
    let frontend_data_provider: ContractAddress = periphery_deployment::deploy_frontend_data_provider(
        Option::None, admin, shrine, sentinel, abbot, purger
    );

    // Transfer admin role to multisig
    let multisig: ContractAddress = addresses::mainnet::multisig();
    utils::transfer_admin_and_role(absorber, multisig, absorber_roles::default_admin_role(), "Absorber");
    utils::transfer_admin_and_role(allocator, multisig, allocator_roles::default_admin_role(), "Allocator");
    utils::transfer_admin_and_role(caretaker, multisig, caretaker_roles::default_admin_role(), "Caretaker");
    utils::transfer_admin_and_role(controller, multisig, controller_roles::default_admin_role(), "Controller");
    utils::transfer_admin_and_role(equalizer, multisig, equalizer_roles::default_admin_role(), "Equalizer");
    utils::transfer_admin_and_role(pragma, multisig, pragma_roles::default_admin_role(), "Pragma");
    utils::transfer_admin_and_role(purger, multisig, purger_roles::default_admin_role(), "Purger");
    utils::transfer_admin_and_role(seer, multisig, seer_roles::default_admin_role(), "Seer");
    utils::transfer_admin_and_role(sentinel, multisig, sentinel_roles::default_admin_role(), "Sentinel");
    utils::transfer_admin_and_role(shrine, multisig, shrine_roles::default_admin_role(), "Shrine");
    utils::transfer_admin_and_role(
        usdc_transmuter_restricted, multisig, transmuter_roles::default_admin_role(), "Transmuter[USDC] (R)"
    );

    // Print summary table of deployed contracts
    println!("-------------------------------------------------\n");
    println!("Deployed addresses");
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
    println!("Gate[WBTC]: {}", wbtc_gate);
    println!("Gate[WSTETH]: {}", wsteth_gate);
    println!("Gate[xSTRK]: {}", xstrk_gate);
    println!("Gate[sSTRK]: {}", sstrk_gate);
    println!("Gate[WSTETH_CANONICAL]: {}", wsteth_canonical_gate);
    println!("Pragma: {}", pragma);
    println!("Purger: {}", purger);
    println!("Receptor: {}", receptor);
    println!("Seer: {}", seer);
    println!("Sentinel: {}", sentinel);
    println!("Shrine: {}", shrine);
    println!("Transmuter[USDC] (Restricted): {}", usdc_transmuter_restricted);
}
