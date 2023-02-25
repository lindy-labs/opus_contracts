%lang starknet

from contracts.lib.aliases import address, bool, ufelt, wad

//
// Shrine
//

struct Trove {
    charge_from: ufelt,  // Time ID (timestamp // TIME_ID_INTERVAL) for start of next accumulated interest calculation
    debt: wad,  // Normalized debt
}

struct YangRedistribution {
    unit_debt: wad,  // Amount of debt in wad to be distributed to each wad unit of yang
    error: wad,  // Amount of debt to be added to the next redistribution to calculate `debt_per_yang`
}

//
// Absorber
//

struct AssetApportion {
    asset_amt_per_share: ufelt,  // Amount of asset in its decimal precision per share wad
    error: ufelt,  // Error to be added to next absorption
}

struct Reward {
    asset: address,  // ERC20 address of token
    blesser: address,  // Address of contract implementing `IBlesser` for distributing the token
    is_active: bool,  // Whether the blesser (vesting contract) should be called
}

struct Provision {
    epoch: ufelt,  // Epoch in which shares are issued
    shares: wad,  // Amount of shares for provider in the above epoch
}
