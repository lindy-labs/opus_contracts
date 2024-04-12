use deployment::constants::{MAX_FEE, SALT};
use deployment::constants;
use deployment::core_deployment;
use deployment::mock_deployment;
use opus::core::roles::{absorber_roles, sentinel_roles, shrine_roles};
use sncast_std::{call, CallResult, invoke, InvokeResult, DisplayContractAddress, get_nonce};
use starknet::{ClassHash, ContractAddress};


// Token constants
const WBTC_DECIMALS: u8 = 8;
const WBTC_SUPPLY: felt252 = 210000000000000;


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

    let balance = call(wbtc, selector!("balance_of"), array![admin.into()]).expect('balance_of failed');
    println!("Balance of admin's WBTC: {}", balance);

    // Deploy gates

    let gate_class_hash: ClassHash = core_deployment::declare_gate();
    let eth: ContractAddress = constants::eth_addr();
    let strk: ContractAddress = constants::strk_addr();

    let eth_gate: ContractAddress = core_deployment::deploy_gate(gate_class_hash, shrine, eth, sentinel, "ETH");
    let wbtc_gate: ContractAddress = core_deployment::deploy_gate(gate_class_hash, shrine, wbtc, sentinel, "WBTC");
    let strk_gate: ContractAddress = core_deployment::deploy_gate(gate_class_hash, shrine, strk, sentinel, "STRK");

    // Grant roles
    println!("Setting up roles");

    let grant_role_selector: felt252 = selector!("grant_role");

    // Absorber roles
    let invoke_nonce = get_nonce('pending');
    let grant_absorber_roles_to_purger = invoke(
        absorber,
        grant_role_selector,
        array![absorber_roles::purger().into(), purger.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: ABS -> PU failed');

    println!("Absorber roles granted to Purger: {}", grant_absorber_roles_to_purger.transaction_hash);

    // Sentinel roles
    let invoke_nonce = get_nonce('pending');
    let grant_sentinel_roles_to_abbot = invoke(
        sentinel,
        grant_role_selector,
        array![sentinel_roles::abbot().into(), abbot.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SE -> ABB failed');

    println!("Sentinel roles granted to Abbot: {}", grant_sentinel_roles_to_abbot.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let grant_sentinel_roles_to_purger = invoke(
        sentinel,
        grant_role_selector,
        array![sentinel_roles::purger().into(), purger.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SE -> PU failed');

    println!("Sentinel roles granted to Purger: {}", grant_sentinel_roles_to_purger.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let grant_sentinel_roles_to_caretaker = invoke(
        sentinel,
        grant_role_selector,
        array![sentinel_roles::caretaker().into(), caretaker.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SE -> CA failed');

    println!("Sentinel roles granted to Caretaker: {}", grant_sentinel_roles_to_caretaker.transaction_hash);

    // Shrine roles
    let invoke_nonce = get_nonce('pending');
    let grant_shrine_roles_to_abbot = invoke(
        shrine,
        grant_role_selector,
        array![shrine_roles::abbot().into(), abbot.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SHR -> ABB failed');

    println!("Shrine roles granted to Abbot: {}", grant_shrine_roles_to_abbot.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let grant_shrine_roles_to_caretaker = invoke(
        shrine,
        grant_role_selector,
        array![shrine_roles::caretaker().into(), caretaker.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SHR -> CA failed');

    println!("Shrine roles granted to Caretaker: {}", grant_shrine_roles_to_caretaker.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let grant_shrine_roles_to_controller = invoke(
        shrine,
        grant_role_selector,
        array![shrine_roles::controller().into(), controller.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SHR -> CTR failed');

    println!("Shrine roles granted to Controller: {}", grant_shrine_roles_to_controller.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let grant_shrine_roles_to_equalizer = invoke(
        shrine,
        grant_role_selector,
        array![shrine_roles::equalizer().into(), equalizer.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SHR -> EQ failed');

    println!("Shrine roles granted to Equalizer: {}", grant_shrine_roles_to_equalizer.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let grant_shrine_roles_to_flash_mint = invoke(
        shrine,
        grant_role_selector,
        array![shrine_roles::flash_mint().into(), flash_mint.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SHR -> FM failed');

    println!("Shrine roles granted to Flash Mint: {}", grant_shrine_roles_to_flash_mint.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let grant_shrine_roles_to_seer = invoke(
        shrine,
        grant_role_selector,
        array![shrine_roles::seer().into(), seer.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SHR -> SEER failed');

    println!("Shrine roles granted to Seer: {}", grant_shrine_roles_to_seer.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let grant_shrine_roles_to_purger = invoke(
        shrine,
        grant_role_selector,
        array![shrine_roles::purger().into(), purger.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SHR -> PU failed');

    println!("Shrine roles granted to Purger: {}", grant_shrine_roles_to_purger.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let grant_shrine_roles_to_sentinel = invoke(
        shrine,
        grant_role_selector,
        array![shrine_roles::sentinel().into(), sentinel.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SHR -> SE failed');

    println!("Shrine roles granted to Sentinel: {}", grant_shrine_roles_to_sentinel.transaction_hash);

    // Adding ETH and STRK yangs
    core_deployment::add_yang_to_sentinel(
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

    core_deployment::add_yang_to_sentinel(
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

    core_deployment::add_yang_to_sentinel(
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
    let set_debt_ceiling = invoke(
        shrine,
        selector!("set_debt_ceiling"),
        array![debt_ceiling.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('set debt ceiling failed');

    println!("Debt ceiling set to {}: {}", debt_ceiling, set_debt_ceiling.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let minimum_trove_value: u128 = constants::MINIMUM_TROVE_VALUE;
    let set_minimum_trove_value = invoke(
        shrine,
        selector!("set_minimum_trove_value"),
        array![minimum_trove_value.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('set debt ceiling failed');

    println!("Minimum trove value set to {}: {}", minimum_trove_value, set_minimum_trove_value.transaction_hash);
}
