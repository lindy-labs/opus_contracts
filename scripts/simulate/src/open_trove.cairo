use deployment::constants::MAX_FEE;
use deployment::constants;
use simulation::utils;
use sncast_std::{
    declare, DeclareResult, deploy, DeployResult, DisplayClassHash, DisplayContractAddress, invoke, InvokeResult,
    ScriptCommandError
};
use starknet::ContractAddress;
use wadray::WAD_ONE;

fn main() {
    // To update for each devnet instance
    let abbot: ContractAddress = 0x2d69a1605970fdc3e23a3af8c98fdcdfde9011224614eb99a5dd492b5b839a3.try_into().unwrap();
    let eth_gate: ContractAddress = 0x168d9af3c4c3b85ac3429432d769c7dbbebbbbc815475fe7cb446927b2b9b6b
        .try_into()
        .unwrap();
    let strk_gate: ContractAddress = 0x1cf8842c9340da2e81534f53f71a00c61cf667cad2df04609fa96a80017357f
        .try_into()
        .unwrap();

    // Approve ETH and STRK
    utils::max_approve_token_for_gate(constants::eth_addr(), eth_gate);
    utils::max_approve_token_for_gate(constants::strk_addr(), strk_gate);

    let open_trove_calldata: Array<felt252> = array![
        2,
        // eth
        constants::eth_addr().into(),
        (5 * WAD_ONE).into(),
        // strk
        constants::strk_addr().into(),
        (500 * WAD_ONE).into(),
        // forge amt
        (10000 * WAD_ONE).into(),
        0,
    ];

    invoke(abbot, selector!("open_trove"), open_trove_calldata, Option::Some(MAX_FEE), Option::None,)
        .expect('open trove failed');

    println!("Trove opened");
}
