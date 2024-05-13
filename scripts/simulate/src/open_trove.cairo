use deployment::constants::MAX_FEE;
use deployment::constants;
use simulation::deployed;
use simulation::utils;
use sncast_std::{
    declare, DeclareResult, deploy, DeployResult, DisplayClassHash, DisplayContractAddress, invoke, InvokeResult,
    ScriptCommandError
};
use starknet::ContractAddress;
use wadray::WAD_ONE;

fn main() {
    // Approve ETH and STRK
    utils::max_approve_token_for_gate(constants::eth_addr(), deployed::devnet::eth_gate());
    utils::max_approve_token_for_gate(constants::strk_addr(), deployed::devnet::strk_gate());

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

    invoke(deployed::devnet::abbot(), selector!("open_trove"), open_trove_calldata, Option::Some(MAX_FEE), Option::None)
        .expect('open trove failed');

    println!("Trove opened");
}
