use deployment::constants::{MAX_FEE, SALT};
use deployment::constants;
use deployment::core_deployment;
use opus::core::roles::{absorber_roles, sentinel_roles, shrine_roles};
use sncast_std::{call, CallResult, invoke, InvokeResult, DisplayContractAddress, get_nonce};
use starknet::{ClassHash, ContractAddress};


// Token constants
const WBTC_DECIMALS: u8 = 8;
const WBTC_SUPPLY: felt252 = 210000000000000;


fn main() {
    println!("Deploying contracts");

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

    let gate_class_hash: ClassHash = core_deployment::declare_gate();
    let _eth_gate: ContractAddress = core_deployment::deploy_gate(
        gate_class_hash, shrine, constants::eth_addr(), sentinel, "ETH"
    );
    let _strk_gate: ContractAddress = core_deployment::deploy_gate(
        gate_class_hash, shrine, constants::strk_addr(), sentinel, "STRK"
    );

    // Grant roles

    println!("Setting up roles");

    let grant_role_selector: felt252 = selector!("grant_role");

    // Absorber roles
    let invoke_nonce = get_nonce('pending');
    let _grant_absorber_roles_to_purger = invoke(
        absorber,
        grant_role_selector,
        array![absorber_roles::purger().into(), purger.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: ABS -> PU failed');

    println!("Absorber roles granted to Purger: {}", _grant_absorber_roles_to_purger.transaction_hash);

    // Sentinel roles
    let invoke_nonce = get_nonce('pending');
    let _grant_sentinel_roles_to_abbot = invoke(
        sentinel,
        grant_role_selector,
        array![sentinel_roles::abbot().into(), abbot.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SE -> ABB failed');

    println!("Sentinel roles granted to Abbot: {}", _grant_sentinel_roles_to_abbot.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let _grant_sentinel_roles_to_purger = invoke(
        sentinel,
        grant_role_selector,
        array![sentinel_roles::purger().into(), purger.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SE -> PU failed');

    println!("Sentinel roles granted to Purger: {}", _grant_sentinel_roles_to_purger.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let _grant_sentinel_roles_to_caretaker = invoke(
        sentinel,
        grant_role_selector,
        array![sentinel_roles::caretaker().into(), caretaker.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SE -> CA failed');

    println!("Sentinel roles granted to Caretaker: {}", _grant_sentinel_roles_to_caretaker.transaction_hash);

    // Shrine roles
    let invoke_nonce = get_nonce('pending');
    let _grant_shrine_roles_to_abbot = invoke(
        shrine,
        grant_role_selector,
        array![shrine_roles::abbot().into(), abbot.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SHR -> ABB failed');

    println!("Shrine roles granted to Abbot: {}", _grant_shrine_roles_to_abbot.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let _grant_shrine_roles_to_caretaker = invoke(
        shrine,
        grant_role_selector,
        array![shrine_roles::caretaker().into(), caretaker.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SHR -> CA failed');

    println!("Shrine roles granted to Caretaker: {}", _grant_shrine_roles_to_caretaker.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let _grant_shrine_roles_to_controller = invoke(
        shrine,
        grant_role_selector,
        array![shrine_roles::controller().into(), controller.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SHR -> CTR failed');

    println!("Shrine roles granted to Controller: {}", _grant_shrine_roles_to_controller.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let _grant_shrine_roles_to_equalizer = invoke(
        shrine,
        grant_role_selector,
        array![shrine_roles::equalizer().into(), equalizer.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SHR -> EQ failed');

    println!("Shrine roles granted to Equalizer: {}", _grant_shrine_roles_to_equalizer.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let _grant_shrine_roles_to_flash_mint = invoke(
        shrine,
        grant_role_selector,
        array![shrine_roles::flash_mint().into(), flash_mint.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SHR -> FM failed');

    println!("Shrine roles granted to Flash Mint: {}", _grant_shrine_roles_to_flash_mint.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let _grant_shrine_roles_to_seer = invoke(
        shrine,
        grant_role_selector,
        array![shrine_roles::seer().into(), seer.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SHR -> SEER failed');

    println!("Shrine roles granted to Seer: {}", _grant_shrine_roles_to_seer.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let _grant_shrine_roles_to_purger = invoke(
        shrine,
        grant_role_selector,
        array![shrine_roles::purger().into(), purger.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SHR -> PU failed');

    println!("Shrine roles granted to Purger: {}", _grant_shrine_roles_to_purger.transaction_hash);

    let invoke_nonce = get_nonce('pending');
    let _grant_shrine_roles_to_sentinel = invoke(
        shrine,
        grant_role_selector,
        array![shrine_roles::sentinel().into(), sentinel.into()],
        Option::Some(MAX_FEE),
        Option::Some(invoke_nonce)
    )
        .expect('grant role: SHR -> SE failed');

    println!("Shrine roles granted to Sentinel: {}", _grant_shrine_roles_to_sentinel.transaction_hash);
}
