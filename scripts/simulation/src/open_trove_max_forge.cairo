use scripts::addresses;
use scripts::constants::{MAX_FEE, MINIMUM_TROVE_VALUE};
use simulation::utils;
use sncast_std::{CallResult, InvokeResult, ScriptCommandError, call, invoke};
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
        // 5 eth (Wad)
        (5 * WAD_ONE).into(),
        // strk
        addresses::strk_addr().into(),
        (50 * WAD_ONE).into(),
        // forge amt
        MINIMUM_TROVE_VALUE.into(),
        0,
    ];

    invoke(
        addresses::devnet::abbot(), selector!("open_trove"), open_trove_calldata, Option::Some(MAX_FEE), Option::None,
    )
        .expect('open trove failed');

    println!("Trove opened");

    let call_result = call(addresses::devnet::abbot(), selector!("get_troves_count"), array![])
        .expect('`get_troves_count` failed');
    let trove_id = *call_result.data.at(0);

    let call_result = call(addresses::devnet::shrine(), selector!("get_max_forge"), array![trove_id])
        .expect('`get_max_forge` failed');
    let max_forge_amt: u128 = (*call_result.data.at(0)).try_into().unwrap() - 1;

    let forge_calldata: Array<felt252> = array![trove_id, max_forge_amt.into(), 0];

    invoke(addresses::devnet::abbot(), selector!("forge"), forge_calldata, Option::Some(MAX_FEE), Option::None)
        .expect('forge failed');

    println!("Trove opened with ID {}", trove_id);
}
