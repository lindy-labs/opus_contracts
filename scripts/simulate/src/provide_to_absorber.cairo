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
    let shrine: ContractAddress = 0x750862d29cc7a589f430e9d710e22e6d1ee9fdd13169424aa06a5c801e3f760.try_into().unwrap();
    let absorber: ContractAddress = 0x507e249755d7eb18057ae1104e06acb4b3112bc2f3079f0a1d7084bd3e92dc3
        .try_into()
        .unwrap();
    let mock_pragma: ContractAddress = 0x580b2efcb1998b5f1c1b431de6642f60d60192f645b68a51f41d9e054326314
        .try_into()
        .unwrap();
    let seer: ContractAddress = 0x43a37e8a81dafa1189cda0fc97e02cfc636467ff0ea6fe8b4367b0d148f09e6.try_into().unwrap();

    let provide_amt: u128 = 500 * WAD_ONE;

    let max_u128: u128 = BoundedInt::max();
    invoke(
        shrine,
        selector!("approve"),
        array![absorber.into(), max_u128.into(), max_u128.into()],
        Option::Some(MAX_FEE),
        Option::None,
    )
        .expect('approve CASH failed');

    invoke(absorber, selector!("provide"), array![provide_amt.into()], Option::Some(MAX_FEE), Option::None,)
        .expect('provide failed');

    println!("Provided {} CASH to Absorber", provide_amt);

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
