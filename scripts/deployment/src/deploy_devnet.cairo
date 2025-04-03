use deployment::{core_deployment, mock_deployment, periphery_deployment, utils};
use opus::constants::{
    ETH_USD_PAIR_ID, PRAGMA_DECIMALS, STRK_USD_PAIR_ID, USDC_DECIMALS, WBTC_DECIMALS, WBTC_USD_PAIR_ID
};
use opus::core::roles::{absorber_roles, sentinel_roles, seer_roles, shrine_roles};
use opus::utils::math::wad_to_fixed_point;
use scripts::addresses;
use scripts::constants;
use scripts::mock_utils;
use sncast_std::{call, CallResult, invoke, InvokeResult, DisplayContractAddress};
use starknet::{ClassHash, ContractAddress};


fn main() {
    let admin: ContractAddress = addresses::devnet::admin();

    println!("Deploying contracts");

    // Deploy core contracts
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

    // Deploy mocks
    println!("Deploying mocks");
    let mock_pragma: ContractAddress = mock_deployment::deploy_mock_pragma();

    let erc20_mintable_class_hash: ClassHash = mock_deployment::declare_erc20_mintable();
    let usdc: ContractAddress = mock_deployment::deploy_erc20_mintable(
        erc20_mintable_class_hash, 'USD Coin', 'USDC', USDC_DECIMALS, constants::USDC_INITIAL_SUPPLY, admin
    );
    let wbtc: ContractAddress = mock_deployment::deploy_erc20_mintable(
        erc20_mintable_class_hash, 'Wrapped BTC', 'WBTC', WBTC_DECIMALS, constants::WBTC_INITIAL_SUPPLY, admin
    );

    // Deploy transmuter
    let usdc_transmuter_restricted: ContractAddress = core_deployment::deploy_transmuter_restricted(
        admin, shrine, usdc, admin, constants::USDC_TRANSMUTER_RESTRICTED_DEBT_CEILING
    );

    // Deploy gates
    println!("Deploying Gates");
    let gate_class_hash: ClassHash = core_deployment::declare_gate();
    let eth: ContractAddress = addresses::eth_addr();
    let strk: ContractAddress = addresses::strk_addr();

    let eth_gate: ContractAddress = core_deployment::deploy_gate(gate_class_hash, shrine, eth, sentinel, "ETH");
    let wbtc_gate: ContractAddress = core_deployment::deploy_gate(gate_class_hash, shrine, wbtc, sentinel, "WBTC");
    let strk_gate: ContractAddress = core_deployment::deploy_gate(gate_class_hash, shrine, strk, sentinel, "STRK");

    println!("Deploying oracles");
    let pragma: ContractAddress = core_deployment::deploy_pragma(
        admin, mock_pragma, mock_pragma, constants::PRAGMA_FRESHNESS_THRESHOLD, constants::PRAGMA_SOURCES_THRESHOLD
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

    // Set up mock oracles
    println!("Setting up mock oracles");
    let eth_pragma_price: u128 = wad_to_fixed_point(constants::INITIAL_ETH_PRICE.into(), PRAGMA_DECIMALS);
    let strk_pragma_price: u128 = wad_to_fixed_point(constants::INITIAL_WBTC_PRICE.into(), PRAGMA_DECIMALS);
    let wbtc_pragma_price: u128 = wad_to_fixed_point(constants::INITIAL_STRK_PRICE.into(), PRAGMA_DECIMALS);

    mock_utils::set_mock_pragma_prices(
        mock_pragma,
        array![ETH_USD_PAIR_ID, STRK_USD_PAIR_ID, WBTC_USD_PAIR_ID].span(),
        array![
            (eth_pragma_price, eth_pragma_price),
            (strk_pragma_price, strk_pragma_price),
            (wbtc_pragma_price, wbtc_pragma_price),
        ]
            .span()
    );

    // Set up oracles
    println!("Setting up oracles");
    utils::set_yang_pair_id_for_oracle(pragma, eth, ETH_USD_PAIR_ID);
    utils::set_yang_pair_id_for_oracle(pragma, wbtc, WBTC_USD_PAIR_ID);
    utils::set_yang_pair_id_for_oracle(pragma, strk, STRK_USD_PAIR_ID);

    // Peripheral deployment
    println!("Deploying periphery contracts");
    let frontend_data_provider: ContractAddress = periphery_deployment::deploy_frontend_data_provider(
        Option::None, admin, shrine, sentinel, abbot, purger
    );

    // Transmute initial amount
    let transmute_amt: u128 = 250000000000; // 250,000 (10**6)
    let _approve_usdc = invoke(
        usdc,
        selector!("approve"),
        array![usdc_transmuter_restricted.into(), transmute_amt.into(), 0],
        Option::Some(constants::MAX_FEE),
        Option::None,
    )
        .expect('approve USDC failed');
    let _transmute = invoke(
        usdc_transmuter_restricted,
        selector!("transmute"),
        array![transmute_amt.into()],
        Option::Some(constants::MAX_FEE),
        Option::None
    )
        .expect('transmute failed');

    println!("Transmuted {} USDC for CASH", transmute_amt);

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
    println!("Mock Pragma: {}", mock_pragma);
    println!("Pragma: {}", pragma);
    println!("Purger: {}", purger);
    println!("Seer: {}", seer);
    println!("Sentinel: {}", sentinel);
    println!("Shrine: {}", shrine);
    println!("Token[USDC]: {}", usdc);
    println!("Token[WBTC]: {}", wbtc);
    println!("Transmuter[USDC] (Restricted): {}", usdc_transmuter_restricted);
}
