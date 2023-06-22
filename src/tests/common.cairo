use array::{ArrayTrait, SpanTrait};
use option::OptionTrait;
use starknet::{ContractAddress, contract_address_const, contract_address_try_from_felt252};
use starknet::contract_address::ContractAddressZeroable;
use starknet::testing::set_contract_address;
use traits::{Default, Into, TryInto};

use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
use aura::interfaces::IERC20::{
    IERC20Dispatcher, IERC20DispatcherTrait, IMintableDispatcher, IMintableDispatcherTrait
};
use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
use aura::utils::wadray;
use aura::utils::wadray::Wad;

use aura::tests::sentinel::utils::SentinelUtils;

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

fn badguy() -> ContractAddress {
    contract_address_try_from_felt252('bad guy').unwrap()
}

fn trove1_owner_addr() -> ContractAddress {
    contract_address_try_from_felt252('trove1 owner').unwrap()
}

fn trove2_owner_addr() -> ContractAddress {
    contract_address_try_from_felt252('trove2 owner').unwrap()
}

fn trove3_owner_addr() -> ContractAddress {
    contract_address_try_from_felt252('trove3 owner').unwrap()
}

//
// Trait implementations
//

impl SpanPartialEq<
    T, impl TPartialEq: PartialEq<T>, impl TDrop: Drop<T>, impl TCopy: Copy<T>
> of PartialEq<Span<T>> {
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

//
// Helpers - Test setup
//

// Helper function to fund a user account with yang assets
fn fund_user(user: ContractAddress, mut yangs: Span<ContractAddress>, mut asset_amts: Span<u128>) {
    loop {
        match yangs.pop_front() {
            Option::Some(yang) => {
                IMintableDispatcher {
                    contract_address: *yang
                }.mint(user, (*asset_amts.pop_front().unwrap()).into());
            },
            Option::None(_) => {
                break;
            }
        };
    };
}

// Helper function to approve Gates to transfer tokens from user, and to open a trove
fn open_trove_helper(
    abbot: IAbbotDispatcher,
    user: ContractAddress,
    mut yangs: Span<ContractAddress>,
    yang_asset_amts: Span<u128>,
    mut gates: Span<IGateDispatcher>,
    forge_amt: Wad
) -> u64 {
    set_contract_address(user);
    let mut yangs_copy = yangs;
    loop {
        match yangs_copy.pop_front() {
            Option::Some(yang) => {
                // Approve Gate to transfer from user
                let gate: IGateDispatcher = *gates.pop_front().unwrap();
                SentinelUtils::approve_max(gate, *yang, user);
            },
            Option::None(_) => {
                break;
            }
        };
    };

    set_contract_address(user);
    let trove_id: u64 = abbot.open_trove(forge_amt, yangs, yang_asset_amts, 0_u128.into());

    set_contract_address(ContractAddressZeroable::zero());

    trove_id
}

//
// Helpers - Convenience getters

// Helper function to return a nested array of token balances given a list of 
// token addresses and user addresses.
// The return value is in the form of:
// [[address1_token1_balance, address2_token1_balance, ...], [address1_token2_balance, ...], ...]
fn get_token_balances(
    mut tokens: Span<ContractAddress>, addresses: Span<ContractAddress>, 
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

//
// Helpers - Assertions
//

#[inline]
fn assert_equalish<
    T, impl TSub: Sub<T>, impl TPartialOrd: PartialOrd<T>, impl TCopy: Copy<T>, impl TDrop: Drop<T>
>(
    a: T, b: T, error: T, message: felt252
) {
    if a >= b {
        assert(a - b <= error, message);
    } else {
        assert(b - a <= error, message);
    }
}
