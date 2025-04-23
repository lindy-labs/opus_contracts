use scripts::addresses;
use scripts::constants::MAX_FEE;
use sncast_std::{DeclareResultTrait, DisplayContractAddress, FeeSettingsTrait, declare, invoke};

fn main() {
    println!("Declaring new frontend data provider contract");

    let declare_frontend_data_provider = declare(
        "frontend_data_provider", FeeSettingsTrait::max_fee(MAX_FEE), Option::None,
    )
        .expect('failed FDP declare');

    println!("Upgrading frontend data provider with new class hash");

    let calldata: Array<felt252> = array![(*declare_frontend_data_provider.class_hash()).into()];
    invoke(
        addresses::devnet::FRONTEND_DATA_PROVIDER,
        selector!("upgrade"),
        calldata,
        FeeSettingsTrait::max_fee(MAX_FEE),
        Option::None,
    )
        .expect('upgrade failed');
}
