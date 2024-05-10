use core::integer::BoundedInt;
use deployment::constants::MAX_FEE;
use deployment::{constants, mock_utils};
use opus::constants::{ETH_USD_PAIR_ID, PRAGMA_DECIMALS, STRK_USD_PAIR_ID, WBTC_USD_PAIR_ID};
use opus::utils::math::wad_to_fixed_point;
use sncast_std::{
    declare, DeclareResult, deploy, DeployResult, DisplayClassHash, DisplayContractAddress, invoke, InvokeResult,
    ScriptCommandError
};
use starknet::ContractAddress;
use wadray::WAD_ONE;

fn main() {
    // To update for each devnet instance
    let mock_pragma: ContractAddress = 3239380313790890222009670146965793695247352380113186951344603154142805677789
        .try_into()
        .unwrap();
    let seer: ContractAddress = 1013230234558776689968017309046271916058552264170820325826244966583211814314
        .try_into()
        .unwrap();

    let eth_pragma_price: u128 = wad_to_fixed_point((constants::INITIAL_ETH_PRICE / 4).into(), PRAGMA_DECIMALS);
    let strk_pragma_price: u128 = wad_to_fixed_point((constants::INITIAL_STRK_PRICE / 4).into(), PRAGMA_DECIMALS);
    let wbtc_pragma_price: u128 = wad_to_fixed_point((constants::INITIAL_WBTC_PRICE / 4).into(), PRAGMA_DECIMALS);

    mock_utils::set_mock_pragma_prices(
        mock_pragma,
        array![ETH_USD_PAIR_ID, STRK_USD_PAIR_ID, WBTC_USD_PAIR_ID].span(),
        array![
            (eth_pragma_price, eth_pragma_price),
            (strk_pragma_price, strk_pragma_price),
            (wbtc_pragma_price, wbtc_pragma_price),
        ]
            .span()
    );

    invoke(seer, selector!("execute_task"), array![], Option::Some(MAX_FEE), Option::None,)
        .expect('update prices failed');
}
