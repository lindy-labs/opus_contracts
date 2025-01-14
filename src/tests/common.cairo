use core::num::traits::Zero;
use opus::constants::{DAI_DECIMALS, LUSD_DECIMALS, USDC_DECIMALS, USDT_DECIMALS};
use opus::core::shrine::shrine;
use opus::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait, IMintableDispatcher, IMintableDispatcherTrait};
use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
use opus::mock::erc4626_mintable::{IMockERC4626Dispatcher, IMockERC4626DispatcherTrait};
use opus::mock::mock_ekubo_oracle_extension::IMockEkuboOracleExtensionDispatcher;
use opus::tests::sentinel::utils::sentinel_utils;
use opus::tests::shrine::utils::shrine_utils;
use opus::types::{AssetBalance, Reward, YangBalance};
use opus::utils::math::pow;
use snforge_std::{CheatTarget, ContractClass, ContractClassTrait, declare, Event, start_prank, start_warp, stop_prank};
use starknet::testing::{pop_log_raw};
use starknet::{ContractAddress, get_block_timestamp};
use wadray::{Ray, Wad, WAD_ONE};

//
// Types
//

#[derive(Copy, Drop, PartialEq)]
pub enum RecoveryModeSetupType {
    BeforeRecoveryMode: (),
    BufferLowerBound: (),
    BufferUpperBound: (),
    ExceedsBuffer: (),
}

//
// Constants
//

pub const ETH_TOTAL: u128 = 100000000000000000000; // 100 * 10**18
pub const WBTC_TOTAL: u128 = 30000000000000000000; // 30 * 10**18
pub const WBTC_DECIMALS: u8 = 8;
pub const WBTC_SCALE: u128 = 100000000; // WBTC has 8 decimals, scale is 10**8

// Trove constants
pub const TROVE_1: u64 = 1;
pub const TROVE_2: u64 = 2;
pub const TROVE_3: u64 = 3;
pub const WHALE_TROVE: u64 = 0xb17b01;


//
// Constant addresses
//

pub fn badguy() -> ContractAddress {
    'bad guy'.try_into().unwrap()
}

pub fn trove1_owner_addr() -> ContractAddress {
    'trove1 owner'.try_into().unwrap()
}

pub fn trove2_owner_addr() -> ContractAddress {
    'trove2 owner'.try_into().unwrap()
}

pub fn trove3_owner_addr() -> ContractAddress {
    'trove3 owner'.try_into().unwrap()
}

pub fn non_zero_address() -> ContractAddress {
    'nonzero address'.try_into().unwrap()
}

pub fn eth_hoarder() -> ContractAddress {
    'eth hoarder'.try_into().unwrap()
}

pub fn wbtc_hoarder() -> ContractAddress {
    'wbtc hoarder'.try_into().unwrap()
}

pub fn admin() -> ContractAddress {
    'admin'.try_into().unwrap()
}


//
// Trait implementations
//

// Taken from Alexandria
// https://github.com/keep-starknet-strange/alexandria/blob/main/src/data_structures/src/array_ext.cairo
pub trait SpanTraitExt<T> {
    fn contains<impl TPartialEq: PartialEq<T>>(self: Span<T>, item: T) -> bool;
}

pub impl SpanImpl<T, impl TCopy: Copy<T>, impl TDrop: Drop<T>> of SpanTraitExt<T> {
    fn contains<impl TPartialEq: PartialEq<T>>(mut self: Span<T>, item: T) -> bool {
        loop {
            match self.pop_front() {
                Option::Some(v) => { if *v == item {
                    break true;
                } },
                Option::None => { break false; },
            };
        }
    }
}

pub impl AddressIntoSpan of Into<ContractAddress, Span<ContractAddress>> {
    fn into(self: ContractAddress) -> Span<ContractAddress> {
        let mut tmp: Array<ContractAddress> = ArrayTrait::new();
        tmp.append(self);
        tmp.span()
    }
}

pub impl RewardPartialEq of PartialEq<Reward> {
    fn eq(mut lhs: @Reward, mut rhs: @Reward) -> bool {
        lhs.asset == rhs.asset
            && lhs.blesser.contract_address == rhs.blesser.contract_address
            && lhs.is_active == rhs.is_active
    }

    fn ne(lhs: @Reward, rhs: @Reward) -> bool {
        !(lhs == rhs)
    }
}

//
// Helpers - Test setup
//

// Helper function to advance timestamp by the given intervals
pub fn advance_intervals_and_refresh_prices_and_multiplier(
    shrine: IShrineDispatcher, mut yangs: Span<ContractAddress>, intervals: u64
) {
    // Getting the yang price and interval so that they can be updated after the warp to reduce recursion
    let (current_multiplier, _, _) = shrine.get_current_multiplier();

    let mut yang_prices = array![];
    let mut yangs_copy = yangs;

    loop {
        match yangs_copy.pop_front() {
            Option::Some(yang) => {
                let (current_yang_price, _, _) = shrine.get_current_yang_price(*yang);
                yang_prices.append(current_yang_price);
            },
            Option::None => { break; }
        };
    };

    start_warp(CheatTarget::All, get_block_timestamp() + (intervals * shrine::TIME_INTERVAL));

    // Updating prices and multiplier
    start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
    shrine.set_multiplier(current_multiplier);
    loop {
        match yangs.pop_front() {
            Option::Some(yang) => {
                let yang_price = yang_prices.pop_front().unwrap();
                shrine.advance(*yang, yang_price);
            },
            Option::None => { break; }
        };
    };
    stop_prank(CheatTarget::One(shrine.contract_address));
}

pub fn advance_intervals(intervals: u64) {
    start_warp(CheatTarget::All, get_block_timestamp() + (intervals * shrine::TIME_INTERVAL));
}


// Mock tokens

pub fn eth_token_deploy(token_class: Option<ContractClass>) -> ContractAddress {
    deploy_token('Ether', 'ETH', 18, ETH_TOTAL.into(), eth_hoarder(), token_class)
}

pub fn wbtc_token_deploy(token_class: Option<ContractClass>) -> ContractAddress {
    deploy_token('Bitcoin', 'WBTC', 8, WBTC_TOTAL.into(), wbtc_hoarder(), token_class)
}

pub fn usdc_token_deploy(token_class: Option<ContractClass>) -> ContractAddress {
    deploy_token('USD Coin', 'USDC', USDC_DECIMALS.into(), WAD_ONE.into(), admin(), token_class)
}

pub fn usdt_token_deploy(token_class: Option<ContractClass>) -> ContractAddress {
    deploy_token('Tether USD', 'USDT', USDT_DECIMALS.into(), WAD_ONE.into(), admin(), token_class)
}

pub fn dai_token_deploy(token_class: Option<ContractClass>) -> ContractAddress {
    deploy_token('Dai Stablecoin', 'DAI', DAI_DECIMALS.into(), WAD_ONE.into(), admin(), token_class)
}

pub fn lusd_token_deploy(token_class: Option<ContractClass>) -> ContractAddress {
    deploy_token('LUSD Stablecoin', 'LUSD', LUSD_DECIMALS.into(), WAD_ONE.into(), admin(), token_class)
}

pub fn quote_tokens(token_class: Option<ContractClass>) -> Span<ContractAddress> {
    let token_class = match token_class {
        Option::Some(class) => class,
        Option::None => declare("erc20_mintable").unwrap()
    };
    array![
        dai_token_deploy(Option::Some(token_class)),
        usdc_token_deploy(Option::Some(token_class)),
        usdt_token_deploy(Option::Some(token_class))
    ]
        .span()
}

pub fn eth_vault_deploy(vault_class: Option<ContractClass>, eth: ContractAddress) -> ContractAddress {
    deploy_vault('Ether Vault', 'vETH', 18, ETH_TOTAL.into(), eth_hoarder(), eth, vault_class)
}

pub fn wbtc_vault_deploy(vault_class: Option<ContractClass>, wbtc: ContractAddress) -> ContractAddress {
    deploy_vault('Bitcoin Vault', 'vWBTC', 18, WBTC_TOTAL.into(), wbtc_hoarder(), wbtc, vault_class)
}


// Helper function to deploy a token
pub fn deploy_token(
    name: felt252,
    symbol: felt252,
    decimals: felt252,
    initial_supply: u256,
    recipient: ContractAddress,
    token_class: Option<ContractClass>,
) -> ContractAddress {
    let calldata: Array<felt252> = array![
        name,
        symbol,
        decimals,
        initial_supply.low.into(), // u256.low
        initial_supply.high.into(), // u256.high
        recipient.into(),
    ];

    let token_class = match token_class {
        Option::Some(class) => class,
        Option::None => declare("erc20_mintable").unwrap(),
    };

    let (token_addr, _) = token_class.deploy(@calldata).expect('erc20 deploy failed');
    token_addr
}

// Helper function to deploy a ERC-4626 vault
pub fn deploy_vault(
    name: felt252,
    symbol: felt252,
    decimals: felt252,
    initial_supply: u256,
    recipient: ContractAddress,
    asset: ContractAddress,
    vault_class: Option<ContractClass>,
) -> ContractAddress {
    let calldata: Array<felt252> = array![
        name,
        symbol,
        decimals,
        initial_supply.low.into(), // u256.low
        initial_supply.high.into(), // u256.high
        recipient.into(),
        asset.into(),
    ];

    let vault_class = match vault_class {
        Option::Some(class) => class,
        Option::None => declare("erc4626_mintable").unwrap(),
    };

    let (vault_addr, _) = vault_class.deploy(@calldata).expect('erc4626 deploy failed');

    // Mock initial conversion rate of 1 : 1
    IMockERC4626Dispatcher { contract_address: vault_addr }
        .set_convert_to_assets_per_wad_scale(pow(10, IERC20Dispatcher { contract_address: asset }.decimals()));

    vault_addr
}

// Helper function to fund a user account with yang assets
pub fn fund_user(user: ContractAddress, mut yangs: Span<ContractAddress>, mut asset_amts: Span<u128>) {
    loop {
        match yangs.pop_front() {
            Option::Some(yang) => {
                let amt = *asset_amts.pop_front().unwrap();
                if amt.is_zero() {
                    continue;
                }
                IMintableDispatcher { contract_address: *yang }.mint(user, amt.into());
            },
            Option::None => { break; }
        };
    };
}

// Mock Ekubo deployment helper

pub fn mock_ekubo_oracle_extension_deploy(
    mock_ekubo_oracle_extension_class: Option<ContractClass>
) -> IMockEkuboOracleExtensionDispatcher {
    let mut calldata: Array<felt252> = ArrayTrait::new();

    let mock_ekubo_oracle_extension_class = match mock_ekubo_oracle_extension_class {
        Option::Some(class) => class,
        Option::None => declare("mock_ekubo_oracle_extension").unwrap(),
    };

    let (mock_ekubo_oracle_extension_addr, _) = mock_ekubo_oracle_extension_class
        .deploy(@calldata)
        .expect('mock ekubo deploy failed');

    IMockEkuboOracleExtensionDispatcher { contract_address: mock_ekubo_oracle_extension_addr }
}

// Helper function to approve Gates to transfer tokens from user, and to open a trove
pub fn open_trove_helper(
    abbot: IAbbotDispatcher,
    user: ContractAddress,
    yangs: Span<ContractAddress>,
    yang_asset_amts: Span<u128>,
    mut gates: Span<IGateDispatcher>,
    forge_amt: Wad
) -> u64 {
    let mut yangs_copy = yangs;

    loop {
        match yangs_copy.pop_front() {
            Option::Some(yang) => {
                // Approve Gate to transfer from user
                let gate: IGateDispatcher = *gates.pop_front().unwrap();
                sentinel_utils::approve_max(gate, *yang, user);
            },
            Option::None => { break; }
        };
    };

    start_prank(CheatTarget::One(abbot.contract_address), user);
    let yang_assets: Span<AssetBalance> = combine_assets_and_amts(yangs, yang_asset_amts);
    let trove_id: u64 = abbot.open_trove(yang_assets, forge_amt, 1_u128.into());
    stop_prank(CheatTarget::One(abbot.contract_address));

    trove_id
}


// Helpers - Convenience getters

// Helper function to return a nested array of token balances given a list of
// token addresses and user addresses.
// The return value is in the form of:
// [[address1_token1_balance, address2_token1_balance, ...], [address1_token2_balance, ...], ...]
pub fn get_token_balances(mut tokens: Span<ContractAddress>, addresses: Span<ContractAddress>) -> Span<Span<u128>> {
    let mut balances: Array<Span<u128>> = ArrayTrait::new();

    loop {
        match tokens.pop_front() {
            Option::Some(token) => {
                let token: IERC20Dispatcher = IERC20Dispatcher { contract_address: *token };

                let mut yang_balances: Array<u128> = ArrayTrait::new();
                let mut addresses_copy = addresses;
                loop {
                    match addresses_copy.pop_front() {
                        Option::Some(address) => {
                            let bal: u128 = token.balance_of(*address).try_into().unwrap();
                            yang_balances.append(bal);
                        },
                        Option::None => { break; }
                    };
                };
                balances.append(yang_balances.span());
            },
            Option::None => { break balances.span(); }
        };
    }
}

// Fetches the ERC20 asset balance of a given address, and
// converts it to yang units.
#[inline(always)]
pub fn get_erc20_bal_as_yang(gate: IGateDispatcher, asset: ContractAddress, owner: ContractAddress) -> Wad {
    gate.convert_to_yang(IERC20Dispatcher { contract_address: asset }.balance_of(owner).try_into().unwrap())
}

//
// Helpers - Assertions
//

pub fn assert_equalish<T, impl TPartialOrd: PartialOrd<T>, impl TSub: Sub<T>, impl TCopy: Copy<T>, impl TDrop: Drop<T>>(
    a: T, b: T, error: T, message: felt252
) {
    if a >= b {
        assert(a - b <= error, message);
    } else {
        assert(b - a <= error, message);
    }
}

pub fn assert_asset_balances_equalish(
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
            Option::None => { break; }
        };
    };
}

pub fn assert_yang_balances_equalish(mut a: Span<YangBalance>, mut b: Span<YangBalance>, error: Wad, message: felt252) {
    assert(a.len() == b.len(), message);

    loop {
        match a.pop_front() {
            Option::Some(a) => {
                let b: YangBalance = *b.pop_front().unwrap();
                assert(*a.yang_id == b.yang_id, 'wrong yang ID');
                assert_equalish(*a.amount, b.amount, error, message);
            },
            Option::None => { break; }
        };
    };
}

// Helper to assert that an event was not emitted at all by checking the event name only
// without checking specific values of the event's members
pub fn assert_event_not_emitted_by_name(emitted_events: Span<(ContractAddress, Event)>, event_selector: felt252) {
    let end_idx = emitted_events.len();
    let mut current_idx = 0;
    loop {
        if current_idx == end_idx {
            break;
        }

        let (_, raw_event) = emitted_events.at(current_idx);

        assert(*raw_event.keys.at(0) != event_selector, 'event name emitted');

        current_idx += 1;
    };
}

//
// Helpers - Array functions
//

pub fn combine_assets_and_amts(mut assets: Span<ContractAddress>, mut amts: Span<u128>) -> Span<AssetBalance> {
    assert(assets.len() == amts.len(), 'combining diff array lengths');
    let mut asset_balances: Array<AssetBalance> = ArrayTrait::new();
    loop {
        match assets.pop_front() {
            Option::Some(asset) => {
                asset_balances.append(AssetBalance { address: *asset, amount: *amts.pop_front().unwrap() });
            },
            Option::None => { break; },
        };
    };

    asset_balances.span()
}

// Helper function to multiply an array of values by a given percentage
pub fn scale_span_by_pct(mut asset_amts: Span<u128>, pct: Ray) -> Span<u128> {
    let mut split_asset_amts: Array<u128> = ArrayTrait::new();
    loop {
        match asset_amts.pop_front() {
            Option::Some(asset_amt) => {
                // Convert to Wad for fixed point operations
                let asset_amt: Wad = (*asset_amt).into();
                split_asset_amts.append(wadray::rmul_wr(asset_amt, pct).val);
            },
            Option::None => { break; },
        };
    };

    split_asset_amts.span()
}

// Helper function to combine two arrays of equal lengths into a single array by doing element-wise addition.
// Assumes the arrays are ordered identically.
pub fn combine_spans(mut lhs: Span<u128>, mut rhs: Span<u128>) -> Span<u128> {
    assert(lhs.len() == rhs.len(), 'combining diff array lengths');
    let mut combined_asset_amts: Array<u128> = ArrayTrait::new();

    loop {
        match lhs.pop_front() {
            Option::Some(asset_amt) => {
                // Convert to Wad for fixed point operations
                combined_asset_amts.append(*asset_amt + *rhs.pop_front().unwrap());
            },
            Option::None => { break; },
        };
    };

    combined_asset_amts.span()
}
