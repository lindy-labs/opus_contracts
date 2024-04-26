use deployment::constants::{MAX_FEE, PRAGMA_SOURCES_THRESHOLD};
use opus::constants::PRAGMA_DECIMALS;
use opus::mock::mock_pragma::{IMockPragmaDispatcher, IMockPragmaDispatcherTrait};
use opus::mock::mock_switchboard::{IMockSwitchboardDispatcher, IMockSwitchboardDispatcherTrait};
use opus::types::pragma::PragmaPricesResponse;
use sncast_std::{DisplayContractAddress, invoke, InvokeResult};
use starknet::{ContractAddress, get_block_timestamp};

pub fn set_mock_pragma_prices(
    mock_pragma: ContractAddress, mut pair_ids: Span<felt252>, mut prices: Span<(u128, u128)>
) {
    println!("setting mock pragma prices");
    println!("mock pragma addr: {}", mock_pragma);
    let num_sources = PRAGMA_SOURCES_THRESHOLD + 1;

    loop {
        match pair_ids.pop_front() {
            Option::Some(pair_id) => {
                let (spot_price, twap_price) = *prices.pop_front().unwrap();

                let _set_spot_price = invoke(
                    mock_pragma,
                    selector!("next_get_valid_data_median"),
                    array![*pair_id, spot_price.into(), num_sources.into(),],
                    Option::Some(MAX_FEE),
                    Option::None,
                )
                    .expect('set spot price failed');

                let _set_twap_price = invoke(
                    mock_pragma,
                    selector!("next_calculate_twap"),
                    array![*pair_id, twap_price.into(), PRAGMA_DECIMALS.into(),],
                    Option::Some(MAX_FEE),
                    Option::None,
                )
                    .expect('set twap price failed');
            },
            Option::None => { break; },
        };
    };
    println!("Prices set for mock Pragma");
}

pub fn set_mock_switchboard_prices(
    mock_switchboard: ContractAddress, mut pair_ids: Span<felt252>, mut prices: Span<u128>
) {
    let ts = 1000;

    loop {
        match pair_ids.pop_front() {
            Option::Some(pair_id) => {
                let price = *prices.pop_front().unwrap();

                let _set_twap_price = invoke(
                    mock_switchboard,
                    selector!("next_get_latest_result"),
                    array![*pair_id, price.into(), ts.into(),],
                    Option::Some(MAX_FEE),
                    Option::None,
                )
                    .expect('set switchboard price failed');
            },
            Option::None => { break; },
        };
    };
    println!("Prices set for mock Switchboard");
}
