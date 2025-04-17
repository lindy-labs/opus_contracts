use opus::constants::{ETH_USD_PAIR_ID, PRAGMA_DECIMALS, STRK_USD_PAIR_ID, WBTC_USD_PAIR_ID};
use opus::utils::math::wad_to_fixed_point;
use scripts::{addresses, constants, mock_utils};
use sncast_std::{InvokeResult, ScriptCommandError, invoke};
use starknet::ContractAddress;
use wadray::Ray;

fn main() {
    let pct_initial_price: Ray = 900000000000000000000000000_u128.into(); // 90% (Ray)

    let eth_pragma_price: u128 = wad_to_fixed_point(
        wadray::rmul_wr(constants::INITIAL_ETH_PRICE.into(), pct_initial_price), PRAGMA_DECIMALS,
    );
    let strk_pragma_price: u128 = wad_to_fixed_point(
        wadray::rmul_wr(constants::INITIAL_STRK_PRICE.into(), pct_initial_price), PRAGMA_DECIMALS,
    );
    let wbtc_pragma_price: u128 = wad_to_fixed_point(
        wadray::rmul_wr(constants::INITIAL_WBTC_PRICE.into(), pct_initial_price), PRAGMA_DECIMALS,
    );

    mock_utils::set_mock_pragma_prices(
        addresses::devnet::MOCK_PRAGMA,
        array![ETH_USD_PAIR_ID, STRK_USD_PAIR_ID, WBTC_USD_PAIR_ID].span(),
        array![
            (eth_pragma_price, eth_pragma_price),
            (strk_pragma_price, strk_pragma_price),
            (wbtc_pragma_price, wbtc_pragma_price),
        ]
            .span(),
    );

    invoke(
        addresses::devnet::SEER, selector!("execute_task"), array![], FeeSettingsTrait::max_fee(MAX_FEE), Option::None,
    )
        .expect('update prices failed');
}
