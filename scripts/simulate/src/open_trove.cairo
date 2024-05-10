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
    let abbot: ContractAddress = 293212255598816008570921754636627554761055299333086153945661526532054986037
        .try_into()
        .unwrap();
    let eth_gate: ContractAddress = 2854927889298976482304332453752777576635504087813950583519355364528784326047
        .try_into()
        .unwrap();
    let strk_gate: ContractAddress = 2047265481346033047803571763905070421575510855949894757182676932001894918837
        .try_into()
        .unwrap();

    // Approve ETH and STRK
    utils::max_approve_token_for_gate(constants::eth_addr(), eth_gate);
    utils::max_approve_token_for_gate(constants::strk_addr(), strk_gate);

    let open_trove_calldata: Array<felt252> = array![
        2,
        // eth
        constants::eth_addr().into(),
        // 0.5 eth (Wad)
        5000000000000000000.into(),
        // strk
        constants::strk_addr().into(),
        (50 * WAD_ONE).into(),
        // forge amt
        (1000 * WAD_ONE).into(),
        0,
    ];

    invoke(abbot, selector!("open_trove"), open_trove_calldata, Option::Some(MAX_FEE), Option::None)
        .expect('open trove failed');

    println!("Trove opened");
}
