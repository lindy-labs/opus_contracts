use scripts::addresses;
use scripts::constants::MAX_FEE;
use sncast_std::{
    declare, DeclareResult, deploy, DeployResult, DisplayClassHash, DisplayContractAddress, invoke, InvokeResult,
    ScriptCommandError
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

// Constants for Ekubo
const EKUBO_TWAP_DURATION: u64 = 60 * 60; // 1 hour

// Constants for Receptor
const RECEPTOR_UPDATE_FREQUENCY: u64 = 1000;
const RECEPTOR_TWAP_DURATION: u64 = 10800; // 3 hours

// Constants for Seer
const SEER_UPDATE_FREQUENCY: u64 = 1000;

//
// Deployment helpers
//

pub fn deploy_shrine(admin: ContractAddress) -> ContractAddress {
    let declare_shrine = declare("shrine", Option::Some(MAX_FEE), Option::None).expect('failed shrine declare');
    let shrine_calldata: Array<felt252> = array![admin.into(), 'Cash', 'CASH',];
    let deploy_shrine = deploy(
        declare_shrine.class_hash, shrine_calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed shrine deploy');

    deploy_shrine.contract_address
}

pub fn deploy_flash_mint(shrine: ContractAddress) -> ContractAddress {
    let declare_flash_mint = declare("flash_mint", Option::Some(MAX_FEE), Option::None)
        .expect('failed flash mint declare');

    let flash_mint_calldata: Array<felt252> = array![shrine.into()];
    let deploy_flash_mint = deploy(
        declare_flash_mint.class_hash, flash_mint_calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed flash mint deploy');

    deploy_flash_mint.contract_address
}

pub fn deploy_sentinel(admin: ContractAddress, shrine: ContractAddress) -> ContractAddress {
    let declare_sentinel = declare("sentinel", Option::Some(MAX_FEE), Option::None).expect('failed sentinel declare');

    let sentinel_calldata: Array<felt252> = array![admin.into(), shrine.into()];
    let deploy_sentinel = deploy(
        declare_sentinel.class_hash, sentinel_calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed sentinel deploy');

    deploy_sentinel.contract_address
}

pub fn deploy_seer(admin: ContractAddress, shrine: ContractAddress, sentinel: ContractAddress) -> ContractAddress {
    let declare_seer = declare("seer", Option::Some(MAX_FEE), Option::None).expect('failed seer declare');

    let seer_calldata: Array<felt252> = array![
        admin.into(), shrine.into(), sentinel.into(), SEER_UPDATE_FREQUENCY.into()
    ];
    let deploy_seer = deploy(
        declare_seer.class_hash, seer_calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed seer deploy');

    deploy_seer.contract_address
}

pub fn deploy_seer_v2(admin: ContractAddress, shrine: ContractAddress, sentinel: ContractAddress) -> ContractAddress {
    let declare_seer = declare("seer_v2", Option::Some(MAX_FEE), Option::None).expect('failed seer v2 declare');

    let seer_calldata: Array<felt252> = array![
        admin.into(), shrine.into(), sentinel.into(), SEER_UPDATE_FREQUENCY.into()
    ];
    let deploy_seer = deploy(
        declare_seer.class_hash, seer_calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed seer v2 deploy');

    deploy_seer.contract_address
}

pub fn deploy_abbot(shrine: ContractAddress, sentinel: ContractAddress) -> ContractAddress {
    let declare_abbot = declare("abbot", Option::Some(MAX_FEE), Option::None).expect('failed abbot declare');

    let abbot_calldata: Array<felt252> = array![shrine.into(), sentinel.into()];
    let deploy_abbot = deploy(
        declare_abbot.class_hash, abbot_calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed abbot deploy');

    deploy_abbot.contract_address
}

pub fn deploy_absorber(admin: ContractAddress, shrine: ContractAddress, sentinel: ContractAddress) -> ContractAddress {
    let declare_absorber = declare("absorber", Option::Some(MAX_FEE), Option::None).expect('failed absorber declare');

    let absorber_calldata: Array<felt252> = array![admin.into(), shrine.into(), sentinel.into()];
    let deploy_absorber = deploy(
        declare_absorber.class_hash, absorber_calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed absorber deploy');

    deploy_absorber.contract_address
}

pub fn deploy_purger(
    admin: ContractAddress,
    shrine: ContractAddress,
    sentinel: ContractAddress,
    absorber: ContractAddress,
    seer: ContractAddress
) -> ContractAddress {
    let declare_purger = declare("purger", Option::Some(MAX_FEE), Option::None).expect('failed purger declare');

    let purger_calldata: Array<felt252> = array![
        admin.into(), shrine.into(), sentinel.into(), absorber.into(), seer.into()
    ];
    let deploy_purger = deploy(
        declare_purger.class_hash, purger_calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed purger deploy');

    deploy_purger.contract_address
}

pub fn deploy_allocator(admin: ContractAddress) -> ContractAddress {
    let declare_allocator = declare("allocator", Option::Some(MAX_FEE), Option::None)
        .expect('failed allocator declare');

    let num_recipients: felt252 = 1;
    let allocator_calldata: Array<felt252> = array![
        admin.into(), num_recipients, admin.into(), num_recipients, RAY_ONE.into()
    ];
    let deploy_allocator = deploy(
        declare_allocator.class_hash, allocator_calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed allocator deploy');

    deploy_allocator.contract_address
}

pub fn deploy_equalizer(
    admin: ContractAddress, shrine: ContractAddress, allocator: ContractAddress
) -> ContractAddress {
    let declare_equalizer = declare("equalizer", Option::Some(MAX_FEE), Option::None)
        .expect('failed equalizer declare');

    let equalizer_calldata: Array<felt252> = array![admin.into(), shrine.into(), allocator.into()];
    let deploy_equalizer = deploy(
        declare_equalizer.class_hash, equalizer_calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed equalizer deploy');

    deploy_equalizer.contract_address
}

pub fn deploy_caretaker(
    admin: ContractAddress,
    shrine: ContractAddress,
    abbot: ContractAddress,
    sentinel: ContractAddress,
    equalizer: ContractAddress
) -> ContractAddress {
    let declare_caretaker = declare("caretaker", Option::Some(MAX_FEE), Option::None)
        .expect('failed caretaker declare');

    let caretaker_calldata: Array<felt252> = array![
        admin.into(), shrine.into(), abbot.into(), sentinel.into(), equalizer.into()
    ];
    let deploy_caretaker = deploy(
        declare_caretaker.class_hash, caretaker_calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed caretaker deploy');

    deploy_caretaker.contract_address
}

pub fn deploy_controller(admin: ContractAddress, shrine: ContractAddress) -> ContractAddress {
    let declare_controller = declare("controller", Option::Some(MAX_FEE), Option::None)
        .expect('failed controller declare');

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
        declare_controller.class_hash, controller_calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed controller deploy');

    deploy_controller.contract_address
}

pub fn deploy_receptor(admin: ContractAddress, shrine: ContractAddress) -> ContractAddress {
    let declare_receptor = declare("receptor", Option::Some(MAX_FEE), Option::None).expect('failed receptor declare');

    let num_quote_tokens: felt252 = 3;
    let receptor_calldata: Array<felt252> = array![
        admin.into(),
        shrine.into(),
        addresses::mainnet::ekubo_oracle_extension().into(),
        RECEPTOR_UPDATE_FREQUENCY.into(),
        RECEPTOR_TWAP_DURATION.into(),
        num_quote_tokens,
        addresses::mainnet::dai().into(),
        addresses::mainnet::usdc().into(),
        addresses::mainnet::usdt().into(),
    ];
    let deploy_receptor = deploy(
        declare_receptor.class_hash, receptor_calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed receptor deploy');

    deploy_receptor.contract_address
}

pub fn declare_gate() -> ClassHash {
    declare("gate", Option::Some(MAX_FEE), Option::None).expect('failed gate declare').class_hash
}

pub fn deploy_gate(
    gate_class_hash: ClassHash,
    shrine: ContractAddress,
    token: ContractAddress,
    sentinel: ContractAddress,
    token_name: ByteArray
) -> ContractAddress {
    let gate_calldata: Array<felt252> = array![shrine.into(), token.into(), sentinel.into()];
    let deploy_gate_result = deploy(
        gate_class_hash, gate_calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    );
    if deploy_gate_result.is_err() {
        panic!("failed {} gate deploy", token_name);
    }
    deploy_gate_result.unwrap().contract_address
}

pub fn deploy_pragma(
    admin: ContractAddress,
    spot_oracle: ContractAddress,
    twap_oracle: ContractAddress,
    freshness_threshold: u64,
    sources_threshold: u32
) -> ContractAddress {
    let declare_pragma = declare("pragma", Option::Some(MAX_FEE), Option::None).expect('failed pragma declare');
    let calldata: Array<felt252> = array![
        admin.into(), spot_oracle.into(), twap_oracle.into(), freshness_threshold.into(), sources_threshold.into()
    ];

    let deploy_pragma = deploy(
        declare_pragma.class_hash, calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed pragma deploy');

    deploy_pragma.contract_address
}

pub fn deploy_pragma_v2(
    admin: ContractAddress,
    spot_oracle: ContractAddress,
    twap_oracle: ContractAddress,
    freshness_threshold: u64,
    sources_threshold: u32
) -> ContractAddress {
    let declare_pragma = declare("pragma_v2", Option::Some(MAX_FEE), Option::None).expect('failed pragma declare');
    let calldata: Array<felt252> = array![
        admin.into(), spot_oracle.into(), twap_oracle.into(), freshness_threshold.into(), sources_threshold.into()
    ];

    let deploy_pragma = deploy(
        declare_pragma.class_hash, calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed pragma deploy');

    deploy_pragma.contract_address
}

pub fn deploy_switchboard(admin: ContractAddress, oracle: ContractAddress) -> ContractAddress {
    let declare_switchboard = declare("switchboard", Option::Some(MAX_FEE), Option::None)
        .expect('failed switchboard declare');
    let calldata: Array<felt252> = array![admin.into(), oracle.into()];

    let deploy_switchboard = deploy(
        declare_switchboard.class_hash, calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed switchboard deploy');

    deploy_switchboard.contract_address
}

// Note that this works only for mainnet because Sepolia only has USDC and USDT so we are unable
// to have 3 quote tokens in the first place. Also, USDT/EKUBO pool is not initialized.
pub fn deploy_ekubo(admin: ContractAddress, oracle: ContractAddress) -> ContractAddress {
    let declare_ekubo = declare("ekubo", Option::Some(MAX_FEE), Option::None).expect('failed ekubo declare');

    let num_quote_tokens: felt252 = 3;
    let calldata: Array<felt252> = array![
        admin.into(),
        oracle.into(),
        EKUBO_TWAP_DURATION.into(),
        num_quote_tokens,
        addresses::mainnet::dai().into(),
        addresses::mainnet::usdc().into(),
        addresses::mainnet::usdt().into(),
    ];

    let deploy_ekubo = deploy(
        declare_ekubo.class_hash, calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed ekubo deploy');

    deploy_ekubo.contract_address
}

pub fn deploy_transmuter_restricted(
    admin: ContractAddress, shrine: ContractAddress, asset: ContractAddress, receiver: ContractAddress, ceiling: u128
) -> ContractAddress {
    let declare_transmuter_restricted = declare("transmuter_restricted", Option::Some(MAX_FEE), Option::None)
        .expect('failed transmuter(r) declare');
    let calldata: Array<felt252> = array![admin.into(), shrine.into(), asset.into(), receiver.into(), ceiling.into()];

    let deploy_transmuter_restricted = deploy(
        declare_transmuter_restricted.class_hash, calldata, Option::None, true, Option::Some(MAX_FEE), Option::None
    )
        .expect('failed transmuter(r) deploy');

    deploy_transmuter_restricted.contract_address
}
