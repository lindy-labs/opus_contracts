use starknet::{ClassHash, ContractAddress};

// Constants for deployment
pub const MAX_FEE: felt252 = 9999999999999999999;
pub const SALT: felt252 = 0x3;


// Chain constants
pub fn erc20_class_hash() -> ClassHash {
    0x046ded64ae2dead6448e247234bab192a9c483644395b66f2155f2614e5804b0.try_into().expect('invalid ERC20 class hash')
}

pub fn eth_addr() -> ContractAddress {
    0x49D36570D4E46F48E99674BD3FCC84644DDD6B96F7C741B1562B82F9E004DC7.try_into().expect('invalid ETH address')
}

pub fn strk_addr() -> ContractAddress {
    0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d.try_into().expect('invalid STRK address')
}

// Deployment constants
pub fn admin() -> ContractAddress {
    0x42044b3252fcdaeccfc2514c2b72107aed76855f7251469e2f105d97ec6b6e5.try_into().expect('invalid admin address')
}
