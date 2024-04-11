use deployment::constants::{MAX_FEE, SALT};
use deployment::constants;
use sncast_std::{declare, DeclareResult, deploy, DeployResult, DisplayClassHash, DisplayContractAddress, get_nonce};
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

//
// Deployment helpers
//

pub fn deploy_shrine() -> ContractAddress {
    let declare_shrine = declare("shrine", Option::Some(MAX_FEE), Option::None).expect('failed shrine declare');
    let shrine_class_hash = declare_shrine.class_hash;

    println!("Class hash of Shrine: {}", shrine_class_hash);

    let nonce = get_nonce('latest');
    let shrine_calldata: Array<felt252> = array![constants::admin().into(), 'Cash', 'CASH',];
    let deploy_shrine = deploy(
        shrine_class_hash, shrine_calldata, Option::Some(SALT), true, Option::Some(MAX_FEE), Option::Some(nonce)
    )
        .expect('failed shrine deploy');

    println!("Deployed Shrine to address: {}", deploy_shrine.contract_address);

    deploy_shrine.contract_address
}

pub fn deploy_flash_mint(shrine: ContractAddress) -> ContractAddress {
    let declare_flash_mint = declare("flash_mint", Option::Some(MAX_FEE), Option::None)
        .expect('failed flash mint declare');
    let flash_mint_class_hash = declare_flash_mint.class_hash;

    println!("Class hash of Flash Mint: {}", flash_mint_class_hash);

    let nonce = get_nonce('latest');
    let flash_mint_calldata: Array<felt252> = array![shrine.into()];
    let deploy_flash_mint = deploy(
        flash_mint_class_hash, flash_mint_calldata, Option::Some(SALT), true, Option::Some(MAX_FEE), Option::Some(nonce)
    )
        .expect('failed flash mint deploy');

    println!("Deployed Flash Mint to address: {}", deploy_flash_mint.contract_address);

    deploy_flash_mint.contract_address
}

pub fn deploy_sentinel(shrine: ContractAddress) -> ContractAddress {
    let declare_sentinel = declare("sentinel", Option::Some(MAX_FEE), Option::None).expect('failed sentinel declare');
    let sentinel_class_hash = declare_sentinel.class_hash;

    println!("Class hash of Sentinel: {}", sentinel_class_hash);

    let nonce = get_nonce('latest');
    let sentinel_calldata: Array<felt252> = array![constants::admin().into(), shrine.into()];
    let deploy_sentinel = deploy(
        sentinel_class_hash, sentinel_calldata, Option::Some(SALT), true, Option::Some(MAX_FEE), Option::Some(nonce)
    )
        .expect('failed sentinel deploy');

    println!("Deployed Sentinel to address: {}", deploy_sentinel.contract_address);

    deploy_sentinel.contract_address
}

pub fn deploy_seer(shrine: ContractAddress, sentinel: ContractAddress) -> ContractAddress {
    let declare_seer = declare("seer", Option::Some(MAX_FEE), Option::None).expect('failed seer declare');
    let seer_class_hash = declare_seer.class_hash;

    println!("Class hash of Seer: {}", seer_class_hash);

    let nonce = get_nonce('latest');
    let seer_calldata: Array<felt252> = array![
        constants::admin().into(), shrine.into(), sentinel.into(), SEER_UPDATE_FREQUENCY.into()
    ];
    let deploy_seer = deploy(
        seer_class_hash, seer_calldata, Option::Some(SALT), true, Option::Some(MAX_FEE), Option::Some(nonce)
    )
        .expect('failed seer deploy');

    println!("Deployed Seer to address: {}", deploy_seer.contract_address);

    deploy_seer.contract_address
}

pub fn deploy_abbot(shrine: ContractAddress, sentinel: ContractAddress) -> ContractAddress {
    let declare_abbot = declare("abbot", Option::Some(MAX_FEE), Option::None).expect('failed abbot declare');
    let abbot_class_hash = declare_abbot.class_hash;

    println!("Class hash of Abbot: {}", abbot_class_hash);

    let nonce = get_nonce('latest');
    let abbot_calldata: Array<felt252> = array![shrine.into(), sentinel.into()];
    let deploy_abbot = deploy(
        abbot_class_hash, abbot_calldata, Option::Some(SALT), true, Option::Some(MAX_FEE), Option::Some(nonce)
    )
        .expect('failed abbot deploy');

    println!("Deployed Abbot to address: {}", deploy_abbot.contract_address);

    deploy_abbot.contract_address
}

pub fn deploy_absorber(shrine: ContractAddress, sentinel: ContractAddress) -> ContractAddress {
    let declare_absorber = declare("absorber", Option::Some(MAX_FEE), Option::None).expect('failed absorber declare');
    let absorber_class_hash = declare_absorber.class_hash;

    println!("Class hash of Absorber: {}", absorber_class_hash);

    let nonce = get_nonce('latest');
    let absorber_calldata: Array<felt252> = array![constants::admin().into(), shrine.into(), sentinel.into()];
    let deploy_absorber = deploy(
        absorber_class_hash, absorber_calldata, Option::Some(SALT), true, Option::Some(MAX_FEE), Option::Some(nonce)
    )
        .expect('failed absorber deploy');

    println!("Deployed Absorber to address: {}", deploy_absorber.contract_address);

    deploy_absorber.contract_address
}

pub fn deploy_purger(
    shrine: ContractAddress, sentinel: ContractAddress, absorber: ContractAddress, seer: ContractAddress
) -> ContractAddress {
    let declare_purger = declare("purger", Option::Some(MAX_FEE), Option::None).expect('failed purger declare');
    let purger_class_hash = declare_purger.class_hash;

    println!("Class hash of Purger: {}", purger_class_hash);

    let nonce = get_nonce('latest');
    let purger_calldata: Array<felt252> = array![
        constants::admin().into(), shrine.into(), sentinel.into(), absorber.into(), seer.into()
    ];
    let deploy_purger = deploy(
        purger_class_hash, purger_calldata, Option::Some(SALT), true, Option::Some(MAX_FEE), Option::Some(nonce)
    )
        .expect('failed purger deploy');

    println!("Deployed Purger to address: {}", deploy_purger.contract_address);

    deploy_purger.contract_address
}

pub fn deploy_allocator() -> ContractAddress {
    let declare_allocator = declare("allocator", Option::Some(MAX_FEE), Option::None)
        .expect('failed allocator declare');
    let allocator_class_hash = declare_allocator.class_hash;

    println!("Class hash of Allocator: {}", allocator_class_hash);

    let nonce = get_nonce('latest');
    let num_recipients: felt252 = 1;
    let allocator_calldata: Array<felt252> = array![
        constants::admin().into(), num_recipients, constants::admin().into(), num_recipients, RAY_ONE.into()
    ];
    let deploy_allocator = deploy(
        allocator_class_hash, allocator_calldata, Option::Some(SALT), true, Option::Some(MAX_FEE), Option::Some(nonce)
    )
        .expect('failed allocator deploy');

    println!("Deployed Allocator to address: {}", deploy_allocator.contract_address);

    deploy_allocator.contract_address
}

pub fn deploy_equalizer(shrine: ContractAddress, allocator: ContractAddress) -> ContractAddress {
    let declare_equalizer = declare("equalizer", Option::Some(MAX_FEE), Option::None)
        .expect('failed equalizer declare');
    let equalizer_class_hash = declare_equalizer.class_hash;

    println!("Class hash of Equalizer: {}", equalizer_class_hash);

    let nonce = get_nonce('latest');
    let equalizer_calldata: Array<felt252> = array![constants::admin().into(), shrine.into(), allocator.into()];
    let deploy_equalizer = deploy(
        equalizer_class_hash, equalizer_calldata, Option::Some(SALT), true, Option::Some(MAX_FEE), Option::Some(nonce)
    )
        .expect('failed equalizer deploy');

    println!("Deployed Equalizer to address: {}", deploy_equalizer.contract_address);

    deploy_equalizer.contract_address
}

pub fn deploy_caretaker(
    shrine: ContractAddress, abbot: ContractAddress, sentinel: ContractAddress, equalizer: ContractAddress
) -> ContractAddress {
    let declare_caretaker = declare("caretaker", Option::Some(MAX_FEE), Option::None)
        .expect('failed caretaker declare');
    let caretaker_class_hash = declare_caretaker.class_hash;

    println!("Class hash of Caretaker: {}", caretaker_class_hash);

    let nonce = get_nonce('latest');
    let caretaker_calldata: Array<felt252> = array![
        constants::admin().into(), shrine.into(), abbot.into(), sentinel.into(), equalizer.into()
    ];
    let deploy_caretaker = deploy(
        caretaker_class_hash, caretaker_calldata, Option::Some(SALT), true, Option::Some(MAX_FEE), Option::Some(nonce)
    )
        .expect('failed caretaker deploy');

    println!("Deployed Caretaker to address: {}", deploy_caretaker.contract_address);

    deploy_caretaker.contract_address
}

pub fn deploy_controller(shrine: ContractAddress) -> ContractAddress {
    let declare_controller = declare("controller", Option::Some(MAX_FEE), Option::None)
        .expect('failed controller declare');
    let controller_class_hash = declare_controller.class_hash;

    println!("Class hash of Controller: {}", controller_class_hash);

    let nonce = get_nonce('latest');
    let controller_calldata: Array<felt252> = array![
        constants::admin().into(),
        shrine.into(),
        P_GAIN.into(),
        I_GAIN.into(),
        ALPHA_P.into(),
        BETA_P.into(),
        ALPHA_I.into(),
        BETA_I.into()
    ];
    let deploy_controller = deploy(
        controller_class_hash, controller_calldata, Option::Some(SALT), true, Option::Some(MAX_FEE), Option::Some(nonce)
    )
        .expect('failed controller deploy');

    println!("Deployed Controller to address: {}", deploy_controller.contract_address);

    deploy_controller.contract_address
}

pub fn declare_gate() -> ClassHash {
    let declare_gate = declare("gate", Option::Some(MAX_FEE), Option::None).expect('failed gate declare');

    println!("Class hash of Gate: {}", declare_gate.class_hash);

    declare_gate.class_hash
}

pub fn deploy_gate(
    gate_class_hash: ClassHash,
    shrine: ContractAddress,
    token: ContractAddress,
    sentinel: ContractAddress,
    token_name: ByteArray
) -> ContractAddress {
    let nonce = get_nonce('latest');
    let gate_calldata: Array<felt252> = array![shrine.into(), token.into(), sentinel.into()];
    let deploy_gate = deploy(
        gate_class_hash, gate_calldata, Option::Some(SALT), true, Option::Some(MAX_FEE), Option::Some(nonce)
    )
        .expect('failed ETH gate deploy');

    println!("Deployed {} Gate to address: {}", token_name, deploy_gate.contract_address);

    deploy_gate.contract_address
}
