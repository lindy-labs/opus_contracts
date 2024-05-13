use core::integer::BoundedInt;
use deployment::constants::MAX_FEE;
use deployment::{constants, mock_utils};
use opus::constants::{ETH_USD_PAIR_ID, PRAGMA_DECIMALS, STRK_USD_PAIR_ID, WBTC_USD_PAIR_ID};
use opus::utils::math::wad_to_fixed_point;
use simulation::deployed;
use sncast_std::{
    declare, DeclareResult, deploy, DeployResult, DisplayClassHash, DisplayContractAddress, invoke, InvokeResult,
    ScriptCommandError
};
use starknet::ContractAddress;
use wadray::WAD_ONE;

fn main() {
    let provide_amt: u128 = 500 * WAD_ONE;

    let max_u128: u128 = BoundedInt::max();
    invoke(
        deployed::devnet::shrine(),
        selector!("approve"),
        array![deployed::devnet::absorber().into(), max_u128.into(), max_u128.into()],
        Option::Some(MAX_FEE),
        Option::None,
    )
        .expect('approve CASH failed');

    invoke(
        deployed::devnet::absorber(),
        selector!("provide"),
        array![provide_amt.into()],
        Option::Some(MAX_FEE),
        Option::None,
    )
        .expect('provide failed');

    println!("Provided {} CASH to Absorber", provide_amt);
}
