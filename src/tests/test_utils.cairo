use array::{ArrayTrait, SpanTrait};
use option::OptionTrait;
use starknet::ContractAddress;
use traits::{Default, TryInto};

use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
use aura::utils::wadray;


impl SpanPartialEq<T, impl TPartialEq: PartialEq<T>, impl TDrop: Drop<T>, impl TCopy: Copy<T>> of PartialEq<Span<T>> {
    fn eq(mut lhs: Span<T>, mut rhs: Span<T>) -> bool {
        loop {
            match lhs.pop_front() {
                Option::Some(lhs) => {
                    let rhs = *rhs.pop_front().unwrap();
                    if *lhs !=  rhs {
                        break false;
                    }
                },
                Option::None(_) => {
                    break true;
                }
            };
        }
    }

    fn ne(mut lhs: Span<T>, mut rhs: Span<T>) -> bool {
        !(lhs == rhs)
    }
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
