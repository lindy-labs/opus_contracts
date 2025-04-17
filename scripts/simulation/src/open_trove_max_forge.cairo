use scripts::addresses;
use scripts::constants::{MAX_FEE, MINIMUM_TROVE_VALUE};
use simulation::utils;
use sncast_std::{CallResult, InvokeResult, ScriptCommandError, call, invoke};
use starknet::ContractAddress;
use wadray::WAD_ONE;

fn main() {
    // Approve ETH and STRK
    utils::max_approve_token_for_gate(addresses::ETH, addresses::devnet::ETH_GATE);
    utils::max_approve_token_for_gate(addresses::STRK, addresses::devnet::STRK_GATE);

    let open_trove_calldata: Array<felt252> = array![
        2,
        // eth
        addresses::ETH.into(),
        // 5 eth (Wad)
        (5 * WAD_ONE).into(),
        // strk
        addresses::STRK.into(),
        (50 * WAD_ONE).into(),
        // forge amt
        MINIMUM_TROVE_VALUE.into(),
        0,
    ];

    invoke(
        addresses::devnet::ABBOT,
        selector!("open_trove"),
        open_trove_calldata,
        FeeSettingsTrait::max_fee(MAX_FEE),
        Option::None,
    )
        .expect('open trove failed');

    println!("Trove opened");

    let call_result = call(addresses::devnet::ABBOT, selector!("get_troves_count"), array![])
        .expect('`get_troves_count` failed');
    let trove_id = *call_result.data.at(0);

    let call_result = call(addresses::devnet::SHRINE, selector!("get_max_forge"), array![trove_id])
        .expect('`get_max_forge` failed');
    let max_forge_amt: u128 = (*call_result.data.at(0)).try_into().unwrap() - 1;

    let forge_calldata: Array<felt252> = array![trove_id, max_forge_amt.into(), 0];

    invoke(
        addresses::devnet::ABBOT, selector!("forge"), forge_calldata, FeeSettingsTrait::max_fee(MAX_FEE), Option::None,
    )
        .expect('forge failed');

    println!("Trove opened with ID {}", trove_id);
}
