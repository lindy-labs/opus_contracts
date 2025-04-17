use core::num::traits::Bounded;
use scripts::addresses;
use scripts::constants::MAX_FEE;
use sncast_std::{InvokeResult, ScriptCommandError, invoke};
use starknet::ContractAddress;
use wadray::WAD_ONE;

fn main() {
    let provide_amt: u128 = 1000 * WAD_ONE;

    let max_u128: u128 = Bounded::MAX();
    invoke(
        addresses::devnet::SHRINE,
        selector!("approve"),
        array![addresses::devnet::ABSORBER.into(), max_u128.into(), max_u128.into()],
        FeeSettingsTrait::max_fee(MAX_FEE),
        Option::None,
    )
        .expect('approve CASH failed');

    invoke(
        addresses::devnet::ABSORBER,
        selector!("provide"),
        array![provide_amt.into()],
        FeeSettingsTrait::max_fee(MAX_FEE),
        Option::None,
    )
        .expect('provide failed');

    println!("Provided {} CASH to Absorber", provide_amt);
}
