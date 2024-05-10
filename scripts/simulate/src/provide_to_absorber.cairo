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
    let shrine: ContractAddress = 1044154046461616858194965537587468178336610055717742363898820754029885084504
        .try_into()
        .unwrap();
    let absorber: ContractAddress = 2593427506183745139029808205620002090895468653112483185982011296748798620259
        .try_into()
        .unwrap();

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
}
