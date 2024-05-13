use scripts::constants::MAX_FEE;
use scripts::addresses;
use simulation::utils;
use sncast_std::{
    DisplayClassHash, DisplayContractAddress, invoke, InvokeResult,
    ScriptCommandError
};
use starknet::ContractAddress;
use wadray::WAD_ONE;

fn main() {
    // Approve ETH and STRK
    utils::max_approve_token_for_gate(addresses::eth_addr(), addresses::devnet::eth_gate());
    utils::max_approve_token_for_gate(addresses::strk_addr(), addresses::devnet::strk_gate());

    let open_trove_calldata: Array<felt252> = array![
        2,
        // eth
        addresses::eth_addr().into(),
        // 0.5 eth (Wad)
        5000000000000000000.into(),
        // strk
        addresses::strk_addr().into(),
        (50 * WAD_ONE).into(),
        // forge amt
        (1000 * WAD_ONE).into(),
        0,
    ];

    invoke(addresses::devnet::abbot(), selector!("open_trove"), open_trove_calldata, Option::Some(MAX_FEE), Option::None)
        .expect('open trove failed');

    println!("Trove opened");
}
