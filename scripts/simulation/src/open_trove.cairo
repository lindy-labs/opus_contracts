use scripts::addresses;
use scripts::constants::MAX_FEE;
use simulation::utils;
use sncast_std::{FeeSettingsTrait, call, invoke};
use wadray::WAD_ONE;

fn main() {
    // Approve ETH and STRK
    utils::max_approve_token_for_gate(addresses::ETH, addresses::devnet::ETH_GATE);
    utils::max_approve_token_for_gate(addresses::STRK, addresses::devnet::STRK_GATE);

    let open_trove_calldata: Array<felt252> = array![
        2,
        // eth
        addresses::ETH.into(),
        // 10 eth (Wad)
        10000000000000000000.into(),
        // strk
        addresses::STRK.into(),
        (1000 * WAD_ONE).into(),
        // forge amt
        (2500 * WAD_ONE).into(),
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

    let call_result = call(addresses::devnet::ABBOT, selector!("get_troves_count"), array![])
        .expect('`get_troves_count` failed');
    let trove_id = *call_result.data.at(0);

    println!("Trove opened with ID {}", trove_id);
}
