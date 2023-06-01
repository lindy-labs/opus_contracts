use array::{ArrayTrait, SpanTrait};
use option::OptionTrait;
use starknet::ContractAddress;
use traits::{Default, TryInto};

use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
use aura::utils::wadray;

fn assert_spans_equal<T, impl TPartialEq: PartialEq<T>, impl DropT: Drop<T>, impl CopyT: Copy<T>>(
    mut a: Span<T>, mut b: Span<T>
) {
    loop {
        match a.pop_front() {
            Option::Some(i) => {
                assert(*i == *b.pop_front().unwrap(), 'elements not equal');
            },
            Option::None(_) => {
                break;
            }
        };
    };
}


// Helper function to return a nested array of token balances given a list of 
// token addresses and user addresses.
// The return value is in the form of:
// [[address1_token1_balance, address2_token1_balance, ...], [address1_token2_balance, ...], ...]
fn get_token_balances(
    mut tokens: Span<ContractAddress>,
    addresses: Span<ContractAddress>,
) -> Span<Span<u128>> {
    let mut balances: Array<Span<u128>> = Default::default();

    loop {
        match tokens.pop_front() {
            Option::Some(token) => {
                let token: IERC20Dispatcher = IERC20Dispatcher { contract_address: *token };
                let decimals: u8 = token.decimals();

                let mut yang_balances: Array<u128> = Default::default();
                let mut addresses_copy = addresses;
                loop {
                    match addresses_copy.pop_front() {
                        Option::Some(address) => {
                            let bal: u128 = token.balance_of(*address).try_into().unwrap();
                            yang_balances.append(bal);
                        },
                        Option::None(_) => {
                            break;
                        }
                    };
                };
                balances.append(yang_balances.span());
            },
            Option::None(_) => {
                break balances.span();
            }
        };
    }
}
