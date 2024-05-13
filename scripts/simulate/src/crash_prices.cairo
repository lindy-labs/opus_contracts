use opus::constants::{ETH_USD_PAIR_ID, PRAGMA_DECIMALS, STRK_USD_PAIR_ID, WBTC_USD_PAIR_ID};
use opus::utils::math::wad_to_fixed_point;
use scripts::addresses;
use scripts::constants;
use scripts::mock_utils;
use sncast_std::{invoke, InvokeResult, ScriptCommandError};
use starknet::ContractAddress;

fn main() {
    let eth_pragma_price: u128 = wad_to_fixed_point((constants::INITIAL_ETH_PRICE / 4).into(), PRAGMA_DECIMALS);
    let strk_pragma_price: u128 = wad_to_fixed_point((constants::INITIAL_STRK_PRICE / 4).into(), PRAGMA_DECIMALS);
    let wbtc_pragma_price: u128 = wad_to_fixed_point((constants::INITIAL_WBTC_PRICE / 4).into(), PRAGMA_DECIMALS);

    mock_utils::set_mock_pragma_prices(
        addresses::devnet::mock_pragma(),
        array![ETH_USD_PAIR_ID, STRK_USD_PAIR_ID, WBTC_USD_PAIR_ID].span(),
        array![
            (eth_pragma_price, eth_pragma_price),
            (strk_pragma_price, strk_pragma_price),
            (wbtc_pragma_price, wbtc_pragma_price),
        ]
            .span()
    );

    invoke(
        addresses::devnet::seer(), selector!("execute_task"), array![], Option::Some(constants::MAX_FEE), Option::None,
    )
        .expect('update prices failed');
}
