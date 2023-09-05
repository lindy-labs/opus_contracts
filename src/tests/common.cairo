use array::ArrayTrait;
use starknet::{
    deploy_syscall, ClassHash, class_hash_try_from_felt252, ContractAddress,
    contract_address_to_felt252, contract_address_try_from_felt252, get_block_timestamp,
    SyscallResultTrait
};
use starknet::contract_address::ContractAddressZeroable;
use starknet::testing::{set_block_timestamp, set_contract_address};

use aura::core::shrine::Shrine;

use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
use aura::interfaces::IERC20::{
    IERC20Dispatcher, IERC20DispatcherTrait, IMintableDispatcher, IMintableDispatcherTrait
};
use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
use aura::tests::erc20::ERC20;
use aura::utils::types::{AssetBalance, Reward};
use aura::utils::wadray;
use aura::utils::wadray::{Ray, Wad, WadZeroable};

//use aura::tests::sentinel::utils::SentinelUtils;
use aura::tests::shrine::utils::ShrineUtils;

//
// Constants
//

const WBTC_DECIMALS: u8 = 8;

// Trove constants
const TROVE_1: u64 = 1;
const TROVE_2: u64 = 2;
const TROVE_3: u64 = 3;
const WHALE_TROVE: u64 = 0xb17b01;

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

fn non_zero_address() -> ContractAddress {
    contract_address_try_from_felt252('nonzero address').unwrap()
}

//
// Trait implementations
//

impl AddressIntoSpan of Into<ContractAddress, Span<ContractAddress>> {
    fn into(self: ContractAddress) -> Span<ContractAddress> {
        let mut tmp: Array<ContractAddress> = Default::default();
        tmp.append(self);
        tmp.span()
    }
}

impl RewardPartialEq of PartialEq<Reward> {
    fn eq(mut lhs: @Reward, mut rhs: @Reward) -> bool {
        (lhs.asset == rhs.asset)
            & (lhs.blesser.contract_address == rhs.blesser.contract_address)
            & (lhs.is_active == rhs.is_active)
    }

    fn ne(lhs: @Reward, rhs: @Reward) -> bool {
        !(lhs == rhs)
    }
}

//
// Helpers - Test setup
//

// Helper function to advance timestamp by the given intervals
#[inline(always)]
fn advance_intervals(intervals: u64) {
    set_block_timestamp(get_block_timestamp() + (intervals * Shrine::TIME_INTERVAL));
}

// Helper function to deploy a token
fn deploy_token(
    name: felt252,
    symbol: felt252,
    decimals: felt252,
    initial_supply: u256,
    recipient: ContractAddress,
) -> ContractAddress {
    let mut calldata: Array<felt252> = array![
        name,
        symbol,
        decimals,
        initial_supply.low.into(), // u256.low
        initial_supply.high.into(), // u256.high
        contract_address_to_felt252(recipient),
    ];

    let token: ClassHash = class_hash_try_from_felt252(ERC20::TEST_CLASS_HASH).unwrap();
    let (token, _) = deploy_syscall(token, 0, calldata.span(), false).unwrap_syscall();

    token
}

// Helper function to fund a user account with yang assets
fn fund_user(user: ContractAddress, mut yangs: Span<ContractAddress>, mut asset_amts: Span<u128>) {
    loop {
        match yangs.pop_front() {
            Option::Some(yang) => {
                IMintableDispatcher { contract_address: *yang }
                    .mint(user, (*asset_amts.pop_front().unwrap()).into());
            },
            Option::None => {
                break;
            }
        };
    };
}

// Helper function to approve Gates to transfer tokens from user, and to open a trove
//fn open_trove_helper(
//    abbot: IAbbotDispatcher,
//    user: ContractAddress,
//    yangs: Span<ContractAddress>,
//    yang_asset_amts: Span<u128>,
//    mut gates: Span<IGateDispatcher>,
//    forge_amt: Wad
//) -> u64 {
//    set_contract_address(user);
//    let mut yangs_copy = yangs;
//    loop {
//        match yangs_copy.pop_front() {
//            Option::Some(yang) => {
//                // Approve Gate to transfer from user
//                let gate: IGateDispatcher = *gates.pop_front().unwrap();
//                SentinelUtils::approve_max(gate, *yang, user);
//            },
//            Option::None => {
//                break;
//            }
//        };
//    };
//
//    set_contract_address(user);
//    let yang_assets: Span<AssetBalance> = combine_assets_and_amts(yangs, yang_asset_amts);
//    let trove_id: u64 = abbot.open_trove(yang_assets, forge_amt, WadZeroable::zero());
//
//    set_contract_address(ContractAddressZeroable::zero());
//
//    trove_id
//}
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
                        Option::None => {
                            break;
                        }
                    };
                };
                balances.append(yang_balances.span());
            },
            Option::None => {
                break balances.span();
            }
        };
    }
}

//
// Helpers - Assertions
//

fn assert_equalish<
    T, impl TPartialOrd: PartialOrd<T>, impl TSub: Sub<T>, impl TCopy: Copy<T>, impl TDrop: Drop<T>
>(
    a: T, b: T, error: T, message: felt252
) {
    if a >= b {
        assert(a - b <= error, message);
    } else {
        assert(b - a <= error, message);
    }
}

fn assert_asset_balances_equalish(
    mut a: Span<AssetBalance>, mut b: Span<AssetBalance>, error: u128, message: felt252
) {
    assert(a.len() == b.len(), message);

    loop {
        match a.pop_front() {
            Option::Some(a) => {
                let b: AssetBalance = *b.pop_front().unwrap();
                assert(*a.address == b.address, 'wrong asset address');
                assert_equalish(*a.amount, b.amount, error, message);
            },
            Option::None => {
                break;
            }
        };
    };
}

//
// Helpers - Array functions
//

fn combine_assets_and_amts(
    mut assets: Span<ContractAddress>, mut amts: Span<u128>
) -> Span<AssetBalance> {
    assert(assets.len() == amts.len(), 'combining diff array lengths');
    let mut asset_balances: Array<AssetBalance> = Default::default();
    loop {
        match assets.pop_front() {
            Option::Some(asset) => {
                asset_balances
                    .append(AssetBalance { address: *asset, amount: *amts.pop_front().unwrap(), });
            },
            Option::None => {
                break;
            },
        };
    };

    asset_balances.span()
}

// Helper function to multiply an array of values by a given percentage
fn scale_span_by_pct(mut asset_amts: Span<u128>, pct: Ray) -> Span<u128> {
    let mut split_asset_amts: Array<u128> = Default::default();
    loop {
        match asset_amts.pop_front() {
            Option::Some(asset_amt) => {
                // Convert to Wad for fixed point operations
                let asset_amt: Wad = (*asset_amt).into();
                split_asset_amts.append(wadray::rmul_wr(asset_amt, pct).val);
            },
            Option::None => {
                break;
            },
        };
    };

    split_asset_amts.span()
}

// Helper function to combine two arrays of equal lengths into a single array by doing element-wise addition.
// Assumes the arrays are ordered identically.
fn combine_spans(mut lhs: Span<u128>, mut rhs: Span<u128>) -> Span<u128> {
    assert(lhs.len() == rhs.len(), 'combining diff array lengths');
    let mut combined_asset_amts: Array<u128> = Default::default();

    loop {
        match lhs.pop_front() {
            Option::Some(asset_amt) => {
                // Convert to Wad for fixed point operations
                combined_asset_amts.append(*asset_amt + *rhs.pop_front().unwrap());
            },
            Option::None => {
                break;
            },
        };
    };

    combined_asset_amts.span()
}
