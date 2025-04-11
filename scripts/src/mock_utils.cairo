use opus::constants::PRAGMA_DECIMALS;
use opus::mock::mock_pragma::{IMockPragmaDispatcher, IMockPragmaDispatcherTrait};
use opus::types::pragma::PragmaPricesResponse;
use scripts::constants::{MAX_FEE, PRAGMA_SOURCES_THRESHOLD};
use sncast_std::{DisplayContractAddress, InvokeResult, invoke};
use starknet::{ContractAddress, get_block_timestamp};

pub fn set_mock_pragma_prices(
    mock_pragma: ContractAddress, mut pair_ids: Span<felt252>, mut prices: Span<(u128, u128)>,
) {
    let num_sources = PRAGMA_SOURCES_THRESHOLD + 1;

    loop {
        match pair_ids.pop_front() {
            Option::Some(pair_id) => {
                let (spot_price, twap_price) = *prices.pop_front().unwrap();

                let _set_spot_price = invoke(
                    mock_pragma,
                    selector!("next_get_valid_data_median"),
                    array![*pair_id, spot_price.into(), num_sources.into()],
                    Option::Some(MAX_FEE),
                    Option::None,
                )
                    .expect('set spot price failed');

                let _set_twap_price = invoke(
                    mock_pragma,
                    selector!("next_calculate_twap"),
                    array![*pair_id, twap_price.into(), PRAGMA_DECIMALS.into()],
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
