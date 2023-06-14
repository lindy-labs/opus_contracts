use array::{ArrayTrait, SpanTrait};
use option::OptionTrait;
use starknet::{ContractAddress, contract_address_const};
use traits::{Default, PartialEq, TryInto};

use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
use aura::utils::types::Reward;
use aura::utils::wadray;
use aura::utils::wadray::Wad;


//
// Constants
//

const WBTC_DECIMALS: u8 = 8;

// Trove constants
const TROVE_1: u64 = 1;
const TROVE_2: u64 = 2;
const TROVE_3: u64 = 3;

//
// Constant addresses
//

#[inline(always)]
fn badguy() -> ContractAddress {
    contract_address_const::<0x42069>()
}

#[inline(always)]
fn trove1_owner_addr() -> ContractAddress {
    contract_address_const::<0x0001>()
}

#[inline(always)]
fn trove2_owner_addr() -> ContractAddress {
    contract_address_const::<0x0002>()
}

#[inline(always)]
fn trove3_owner_addr() -> ContractAddress {
    contract_address_const::<0x0003>()
}

//
// Trait implementations
//

impl SpanPartialEq<T, impl TPartialEq: PartialEq<T>, impl TDrop: Drop<T>, impl TCopy: Copy<T>> of PartialEq<Span<T>> {
    fn eq(mut lhs: Span<T>, mut rhs: Span<T>) -> bool {
        loop {
            match lhs.pop_front() {
                Option::Some(lhs) => {
                    if *lhs != *rhs.pop_front().unwrap() {
                        break false;
                    }
                },
                Option::None(_) => {
                    break true;
                }
            };
        }
    }

    fn ne(lhs: Span<T>, rhs: Span<T>) -> bool {
        !(lhs == rhs)
    }
}

impl RewardPartialEq of PartialEq<Reward> {
    fn eq(mut lhs: Reward, mut rhs: Reward) -> bool {
        lhs.asset == rhs.asset & lhs.blesser.contract_address == rhs.blesser.contract_address & lhs.is_active == rhs.is_active
    }

    fn ne(lhs: Reward, rhs: Reward) -> bool {
        !(lhs == rhs)
    }
}

//
// Helpers
//

#[inline(always)]
fn assert_equalish(a: Wad, b: Wad, error: Wad, message: felt252) {
    if a >= b {
        assert(a - b <= error, message);
    } else {
        assert(b - a <= error, message);
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
