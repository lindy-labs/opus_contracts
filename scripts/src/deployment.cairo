use opus::core::roles::shrine_roles;
use sncast_std::{
    declare, deploy, invoke, call, DeclareResult, DeployResult, InvokeResult, CallResult, get_nonce,
    DisplayContractAddress, DisplayClassHash
};
use starknet::{ClassHash, ContractAddress};
use wadray::RAY_ONE;


// Constants for Controller
const P_GAIN: u128 = 100000000000000000000000000000;
const I_GAIN: u128 = 0;
const ALPHA_P: u8 = 3;
const BETA_P: u8 = 8;
const ALPHA_I: u8 = 1;
const BETA_I: u8 = 2;

// Constants for Seer
const SEER_UPDATE_FREQUENCY: u64 = 1000;

// Token constants
const WBTC_DECIMALS: u8 = 8;
const WBTC_SUPPLY: felt252 = 210000000000000;

// Chain constants
fn erc20_class_hash() -> ClassHash {
    0x046ded64ae2dead6448e247234bab192a9c483644395b66f2155f2614e5804b0.try_into().expect('invalid ERC20 class hash')
}

fn eth_address() -> ContractAddress {
    0x49D36570D4E46F48E99674BD3FCC84644DDD6B96F7C741B1562B82F9E004DC7.try_into().expect('invalid ETH address')
}

fn strk_address() -> ContractAddress {
    0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d.try_into().expect('invalid STRK address')
}

fn main() {
    let admin: ContractAddress = 0x42044b3252fcdaeccfc2514c2b72107aed76855f7251469e2f105d97ec6b6e5
        .try_into()
        .expect('invalid admin address');

    let max_fee = 9999999999999999999;
    let salt = 0x3;

    // Declare and deploy Shrine

    let declare_shrine = declare("shrine", Option::Some(max_fee), Option::None).expect('failed shrine declare');
    let shrine_class_hash = declare_shrine.class_hash;

    println!("Class hash of Shrine: {}", shrine_class_hash);

    let nonce = get_nonce('latest');
    let shrine_calldata: Array<felt252> = array![admin.into(), 'Cash', 'CASH',];
    let deploy_shrine = deploy(
        shrine_class_hash, shrine_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    )
        .expect('failed shrine deploy');
    let shrine: ContractAddress = deploy_shrine.contract_address;

    println!("Deployed Shrine to address: {}", shrine);

    // Declare and deploy Flashmint

    let declare_flash_mint = declare("flash_mint", Option::Some(max_fee), Option::None)
        .expect('failed flash mint declare');
    let flash_mint_class_hash = declare_flash_mint.class_hash;

    println!("Class hash of Flash Mint: {}", flash_mint_class_hash);

    let nonce = get_nonce('latest');
    let flash_mint_calldata: Array<felt252> = array![shrine.into()];
    let deploy_flash_mint = deploy(
        flash_mint_class_hash, flash_mint_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    )
        .expect('failed flash mint deploy');
    let flash_mint: ContractAddress = deploy_flash_mint.contract_address;

    println!("Deployed Flash Mint to address: {}", flash_mint);

    // Declare and deploy Sentinel

    let declare_sentinel = declare("sentinel", Option::Some(max_fee), Option::None).expect('failed sentinel declare');
    let sentinel_class_hash = declare_sentinel.class_hash;

    println!("Class hash of Sentinel: {}", sentinel_class_hash);

    let nonce = get_nonce('latest');
    let sentinel_calldata: Array<felt252> = array![admin.into(), shrine.into()];
    let deploy_sentinel = deploy(
        sentinel_class_hash, sentinel_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    )
        .expect('failed sentinel deploy');
    let sentinel: ContractAddress = deploy_sentinel.contract_address;

    println!("Deployed Sentinel to address: {}", sentinel);

    // Declare and deploy Seer

    let declare_seer = declare("seer", Option::Some(max_fee), Option::None).expect('failed seer declare');
    let seer_class_hash = declare_seer.class_hash;

    println!("Class hash of Seer: {}", seer_class_hash);

    let nonce = get_nonce('latest');
    let seer_calldata: Array<felt252> = array![
        admin.into(), shrine.into(), sentinel.into(), SEER_UPDATE_FREQUENCY.into()
    ];
    let deploy_seer = deploy(
        seer_class_hash, seer_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    )
        .expect('failed seer deploy');
    let seer: ContractAddress = deploy_seer.contract_address;

    println!("Deployed Seer to address: {}", seer);

    // Declare and deploy Abbot

    let declare_abbot = declare("abbot", Option::Some(max_fee), Option::None).expect('failed abbot declare');
    let abbot_class_hash = declare_abbot.class_hash;

    println!("Class hash of Abbot: {}", abbot_class_hash);

    let nonce = get_nonce('latest');
    let abbot_calldata: Array<felt252> = array![shrine.into(), sentinel.into()];
    let deploy_abbot = deploy(
        abbot_class_hash, abbot_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    )
        .expect('failed abbot deploy');
    let abbot: ContractAddress = deploy_abbot.contract_address;

    println!("Deployed Abbot to address: {}", abbot);

    // Declare and deploy Absorber

    let declare_absorber = declare("absorber", Option::Some(max_fee), Option::None).expect('failed absorber declare');
    let absorber_class_hash = declare_absorber.class_hash;

    println!("Class hash of Absorber: {}", absorber_class_hash);

    let nonce = get_nonce('latest');
    let absorber_calldata: Array<felt252> = array![admin.into(), shrine.into(), sentinel.into()];
    let deploy_absorber = deploy(
        absorber_class_hash, absorber_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    )
        .expect('failed absorber deploy');
    let absorber: ContractAddress = deploy_absorber.contract_address;

    println!("Deployed Absorber to address: {}", absorber);

    // Declare and deploy Purger

    let declare_purger = declare("purger", Option::Some(max_fee), Option::None).expect('failed purger declare');
    let purger_class_hash = declare_purger.class_hash;

    println!("Class hash of Purger: {}", purger_class_hash);

    let nonce = get_nonce('latest');
    let purger_calldata: Array<felt252> = array![
        admin.into(), shrine.into(), sentinel.into(), absorber.into(), seer.into()
    ];
    let deploy_purger = deploy(
        purger_class_hash, purger_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    )
        .expect('failed purger deploy');
    let purger: ContractAddress = deploy_purger.contract_address;

    println!("Deployed Purger to address: {}", purger);

    // Declare and deploy Allocator

    let declare_allocator = declare("allocator", Option::Some(max_fee), Option::None)
        .expect('failed allocator declare');
    let allocator_class_hash = declare_allocator.class_hash;

    println!("Class hash of Allocator: {}", allocator_class_hash);

    let nonce = get_nonce('latest');
    let num_recipients: felt252 = 1;
    let allocator_calldata: Array<felt252> = array![
        admin.into(), num_recipients, admin.into(), num_recipients, RAY_ONE.into()
    ];
    let deploy_allocator = deploy(
        allocator_class_hash, allocator_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    )
        .expect('failed allocator deploy');
    let allocator: ContractAddress = deploy_allocator.contract_address;

    println!("Deployed Allocator to address: {}", allocator);

    // Declare and deploy Equalizer

    let declare_equalizer = declare("equalizer", Option::Some(max_fee), Option::None)
        .expect('failed equalizer declare');
    let equalizer_class_hash = declare_equalizer.class_hash;

    println!("Class hash of Equalizer: {}", equalizer_class_hash);

    let nonce = get_nonce('latest');
    let equalizer_calldata: Array<felt252> = array![admin.into(), shrine.into(), allocator.into()];
    let deploy_equalizer = deploy(
        equalizer_class_hash, equalizer_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    )
        .expect('failed equalizer deploy');
    let equalizer: ContractAddress = deploy_equalizer.contract_address;

    println!("Deployed Equalizer to address: {}", equalizer);

    // Declare and deploy Caretaker

    let declare_caretaker = declare("caretaker", Option::Some(max_fee), Option::None)
        .expect('failed caretaker declare');
    let caretaker_class_hash = declare_caretaker.class_hash;

    println!("Class hash of Caretaker: {}", caretaker_class_hash);

    let nonce = get_nonce('latest');
    let caretaker_calldata: Array<felt252> = array![
        admin.into(), shrine.into(), abbot.into(), sentinel.into(), equalizer.into()
    ];
    let deploy_caretaker = deploy(
        caretaker_class_hash, caretaker_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    )
        .expect('failed caretaker deploy');
    let caretaker: ContractAddress = deploy_caretaker.contract_address;

    println!("Deployed Caretaker to address: {}", caretaker);

    // Declare and deploy Controller

    let declare_controller = declare("controller", Option::Some(max_fee), Option::None)
        .expect('failed controller declare');
    let controller_class_hash = declare_controller.class_hash;

    println!("Class hash of Controller: {}", controller_class_hash);

    let nonce = get_nonce('latest');
    let controller_calldata: Array<felt252> = array![
        admin.into(),
        shrine.into(),
        P_GAIN.into(),
        I_GAIN.into(),
        ALPHA_P.into(),
        BETA_P.into(),
        ALPHA_I.into(),
        BETA_I.into()
    ];
    let deploy_controller = deploy(
        controller_class_hash, controller_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    )
        .expect('failed controller deploy');
    let controller: ContractAddress = deploy_controller.contract_address;

    println!("Deployed Controller to address: {}", controller);

    // TODO: We should declare our own mock ERC-20 to allow easy minting
    // Declare and deploy WBTC
    // let nonce = get_nonce('latest');
    // let wbtc_calldata: Array<felt252> = array!['Wrapped BTC', 'WBTC', WBTC_DECIMALS.into(), WBTC_SUPPLY.into(), 0, admin.into()];
    // let deploy_wbtc = deploy(
    //     erc20_class_hash(), wbtc_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    // )
    //     .expect('failed WBTC deploy');
    // let wbtc: ContractAddress = deploy_wbtc.contract_address;

    // println!("Deployed WBTC to address: {}", wbtc);

    // Declare and deploy Gates

    let declare_gate = declare("gate", Option::Some(max_fee), Option::None).expect('failed gate declare');
    let gate_class_hash = declare_gate.class_hash;

    println!("Class hash of Gate: {}", gate_class_hash);

    let nonce = get_nonce('latest');
    let eth_gate_calldata: Array<felt252> = array![shrine.into(), eth_address().into(), sentinel.into()];
    let deploy_eth_gate = deploy(
        gate_class_hash, eth_gate_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    )
        .expect('failed ETH gate deploy');
    let eth_gate: ContractAddress = deploy_eth_gate.contract_address;

    println!("Deployed ETH Gate to address: {}", eth_gate);

    let nonce = get_nonce('latest');
    let strk_gate_calldata: Array<felt252> = array![shrine.into(), strk_address().into(), sentinel.into()];
    let deploy_strk_gate = deploy(
        gate_class_hash, strk_gate_calldata, Option::Some(salt), true, Option::Some(max_fee), Option::Some(nonce)
    )
        .expect('failed STRK gate deploy');
    let strk_gate: ContractAddress = deploy_strk_gate.contract_address;

    println!("Deployed STRK Gate to address: {}", strk_gate);

    // Grant roles

    let invoke_nonce = get_nonce('pending');
    let grant_flash_mint_roles = invoke(
        shrine,
        selector!("grant_role"),
        array![shrine_roles::flash_mint().into(), flash_mint.into()],
        Option::Some(max_fee),
        Option::Some(invoke_nonce)
    )
        .expect('grant flash mint roles failed');

    println!("Flash Mint roles granted: {}", grant_flash_mint_roles.transaction_hash);
}
