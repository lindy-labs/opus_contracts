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
    asset_amt_per_share: wad,  // Amount of asset in its decimal precision per share wad
    error: wad,  // Error to be added to next absorption
}

struct Blessing {
    asset: address,  // ERC20 address of token
    blesser: address,  // Address of contract implementing `IBlesser` for distributing the token
    is_active: bool,  // Rewards are actively being distributed
}

struct Checkpoint {
    last_absorption_id: ufelt,  // Last absorption ID of a provider
    last_blessing_id: ufelt,  // Last blessing ID of a provider
}

struct Provision {
    epoch: ufelt,  // Epoch in which shares are issued
    shares: wad,  // Amount of shares for provider in the above epoch
}
