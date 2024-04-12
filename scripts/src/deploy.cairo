use deployment::constants::{MAX_FEE, SALT};
use deployment::constants;
use deployment::core_deployment;
use deployment::mock_deployment;
use deployment::utils;
use opus::core::roles::{absorber_roles, sentinel_roles, shrine_roles};
use sncast_std::{call, CallResult, invoke, InvokeResult, DisplayContractAddress, get_nonce};
use starknet::{ClassHash, ContractAddress};


fn main() {
    let admin: ContractAddress = constants::admin();

    println!("Deploying contracts");

    // Deploy core contracts
    let shrine: ContractAddress = core_deployment::deploy_shrine();
    let flash_mint: ContractAddress = core_deployment::deploy_flash_mint(shrine);
    let sentinel: ContractAddress = core_deployment::deploy_sentinel(shrine);
    let seer: ContractAddress = core_deployment::deploy_seer(shrine, sentinel);
    let abbot: ContractAddress = core_deployment::deploy_abbot(shrine, sentinel);
    let absorber: ContractAddress = core_deployment::deploy_absorber(shrine, sentinel);
    let purger: ContractAddress = core_deployment::deploy_purger(shrine, sentinel, absorber, seer);
    let allocator: ContractAddress = core_deployment::deploy_allocator();
    let equalizer: ContractAddress = core_deployment::deploy_equalizer(shrine, allocator);
    let caretaker: ContractAddress = core_deployment::deploy_caretaker(shrine, abbot, sentinel, equalizer);
    let controller: ContractAddress = core_deployment::deploy_controller(shrine);

    // Deploy mocks
    println!("Deploying mocks");
    let _mock_pragma: ContractAddress = mock_deployment::deploy_mock_pragma();
    let _mock_switchboard: ContractAddress = mock_deployment::deploy_mock_switchboard();

    let erc20_mintable_class_hash: ClassHash = mock_deployment::declare_erc20_mintable();
    let wbtc: ContractAddress = mock_deployment::deploy_erc20_mintable(
        erc20_mintable_class_hash,
        'Wrapped BTC',
        'WBTC',
        constants::WBTC_DECIMALS,
        constants::WBTC_INITIAL_SUPPLY,
        admin
    );

    // Deploy gates
    println!("Deploying Gates");
    let gate_class_hash: ClassHash = core_deployment::declare_gate();
    let eth: ContractAddress = constants::eth_addr();
    let strk: ContractAddress = constants::strk_addr();

    let eth_gate: ContractAddress = core_deployment::deploy_gate(gate_class_hash, shrine, eth, sentinel, "ETH");
    let wbtc_gate: ContractAddress = core_deployment::deploy_gate(gate_class_hash, shrine, wbtc, sentinel, "WBTC");
    let strk_gate: ContractAddress = core_deployment::deploy_gate(gate_class_hash, shrine, strk, sentinel, "STRK");

    // Grant roles
    println!("Setting up roles");

    utils::grant_role(absorber, purger, absorber_roles::purger(), "ABS -> PU");

    utils::grant_role(sentinel, abbot, sentinel_roles::abbot(), "SE -> ABB");
    utils::grant_role(sentinel, purger, sentinel_roles::purger(), "SE -> PU");
    utils::grant_role(sentinel, caretaker, sentinel_roles::caretaker(), "SE -> CA");

    utils::grant_role(shrine, abbot, shrine_roles::abbot(), "SHR -> ABB");
    utils::grant_role(shrine, caretaker, shrine_roles::caretaker(), "SHR -> CA");
    utils::grant_role(shrine, controller, shrine_roles::controller(), "SHR -> CTR");
    utils::grant_role(shrine, equalizer, shrine_roles::equalizer(), "SHR -> EQ");
    utils::grant_role(shrine, flash_mint, shrine_roles::flash_mint(), "SHR -> FM");
    utils::grant_role(shrine, purger, shrine_roles::purger(), "SHR -> PU");
    utils::grant_role(shrine, seer, shrine_roles::seer(), "SHR -> SEER");
    utils::grant_role(shrine, sentinel, shrine_roles::sentinel(), "SHR -> SE");

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
    let invoke_nonce = get_nonce('pending');
    let debt_ceiling: u128 = constants::INITIAL_DEBT_CEILING;
    let _set_debt_ceiling = invoke(
        shrine,
        selector!("set_debt_ceiling"),
        array![debt_ceiling.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('set debt ceiling failed');

    println!("Debt ceiling set: {}", debt_ceiling);

    let invoke_nonce = get_nonce('pending');
    let minimum_trove_value: u128 = constants::MINIMUM_TROVE_VALUE;
    let _set_minimum_trove_value = invoke(
        shrine,
        selector!("set_minimum_trove_value"),
        array![minimum_trove_value.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('set debt ceiling failed');

    println!("Minimum trove value set: {}", minimum_trove_value);
}
