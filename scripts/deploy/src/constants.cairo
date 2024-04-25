use starknet::{ClassHash, ContractAddress};

// Constants for deployment
pub const MAX_FEE: felt252 = 999999999999999;
pub const SALT: felt252 = 0x3;

// Constants for Shrine
pub const INITIAL_DEBT_CEILING: u128 = 500000000000000000000000; // 500_000 (Wad)
pub const MINIMUM_TROVE_VALUE: u128 = 50000000000000000000; // 50 (Wad)

// Constants for Pragma spot
pub const PRAGMA_FRESHNESS_THRESHOLD: u64 = 3600; // 1 hour
pub const PRAGMA_SOURCES_THRESHOLD: u32 = 3;

// Constants for yangs
pub const INITIAL_ETH_AMT: u128 = 1000000000; // 10 ** 9
pub const INITIAL_WBTC_AMT: u128 = 10000; // 10 ** 4
pub const INITIAL_STRK_AMT: u128 = 1000000000; // 10 ** 9

pub const INITIAL_ETH_ASSET_MAX: u128 = 500000000000000000000; // 500 (Wad)
pub const INITIAL_ETH_THRESHOLD: u128 = 800000000000000000000000000; // 80% (Ray)
pub const INITIAL_ETH_PRICE: u128 = 3500000000000000000000; // 3_500 (Wad)
pub const INITIAL_ETH_BASE_RATE: u128 = 20000000000000000000000000; // 2% (Ray)

pub const INITIAL_WBTC_ASSET_MAX: u128 = 10000000000; // 100 (Wad)
pub const INITIAL_WBTC_THRESHOLD: u128 = 850000000000000000000000000; // 85% (Ray)
pub const INITIAL_WBTC_PRICE: u128 = 70000000000000000000000; // 70_000 (Wad)
pub const INITIAL_WBTC_BASE_RATE: u128 = 15000000000000000000000000; // 1.5% (Ray)

pub const INITIAL_STRK_ASSET_MAX: u128 = 100000000000000000000000; // 100_000 (Wad)
pub const INITIAL_STRK_THRESHOLD: u128 = 600000000000000000000000000; // 60% (Ray)
pub const INITIAL_STRK_PRICE: u128 = 1800000000000000000; // 1.80 (Wad)
pub const INITIAL_STRK_BASE_RATE: u128 = 40000000000000000000000000; // 4% (Ray)

// Constants for mocks
pub const WBTC_DECIMALS: u8 = 8;
pub const WBTC_INITIAL_SUPPLY: u128 = 2099999997690000; // approx. 21_000_000 * 10 ** 8

// Constants for Pragma and Switchboard
pub const WBTC_USD_PAIR_ID: felt252 = 'WBTC/USD';
pub const ETH_USD_PAIR_ID: felt252 = 'ETH/USD';
pub const STRK_USD_PAIR_ID: felt252 = 'STRK/USD';

// Chain constants
pub fn erc20_class_hash() -> ClassHash {
    0x046ded64ae2dead6448e247234bab192a9c483644395b66f2155f2614e5804b0.try_into().expect('invalid ERC20 class hash')
}

// https://github.com/starknet-io/starknet-addresses/blob/master/bridged_tokens/

pub fn eth_addr() -> ContractAddress {
    0x49D36570D4E46F48E99674BD3FCC84644DDD6B96F7C741B1562B82F9E004DC7.try_into().expect('invalid ETH address')
}

pub fn strk_addr() -> ContractAddress {
    0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d.try_into().expect('invalid STRK address')
}

pub fn wbtc_addr() -> ContractAddress {
    // only on mainnet
    0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac.try_into().expect('invalid WBTC address')
}

// Deployment constants

pub mod devnet {
    use starknet::ContractAddress;

    // devnet_admin.json
    pub fn admin() -> ContractAddress {
        0x42044b3252fcdaeccfc2514c2b72107aed76855f7251469e2f105d97ec6b6e5.try_into().expect('invalid admin address')
    }
}

pub mod sepolia {
    use starknet::ContractAddress;

    pub fn admin() -> ContractAddress {
        0x17721cd89df40d33907b70b42be2a524abeea23a572cf41c79ffe2422e7814e.try_into().expect('invalid admin address')
    }

    // https://github.com/Astraly-Labs/pragma-oracle?tab=readme-ov-file#deployment-addresses
    pub fn pragma_spot_oracle() -> ContractAddress {
        0x36031daa264c24520b11d93af622c848b2499b66b41d611bac95e13cfca131a
            .try_into()
            .expect('invalid pragma spot address')
    }

    pub fn pragma_twap_oracle() -> ContractAddress {
        0x54563a0537b3ae0ba91032d674a6d468f30a59dc4deb8f0dce4e642b94be15c
            .try_into()
            .expect('invalid pragma twap address')
    }
}
