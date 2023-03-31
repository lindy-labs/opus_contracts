%lang starknet

from contracts.lib.aliases import address, bool, packed, ufelt, wad

//
// Shrine
//

struct PackedTrove {
    // Packed felt of:
    // - Time ID (timestamp // TIME_ID_INTERVAL) for start of next accumulated interest calculation (lower 125 bits)
    // - the amount of debt in the trove. (upper 125 bits)
    info: packed,
    last_rate_era: ufelt,
}

struct Trove {
    charge_from: ufelt,  // Time ID (timestamp // TIME_ID_INTERVAL) for start of next accumulated interest calculation
    debt: wad,  // Normalized debt
    last_rate_era: ufelt,
}

struct YangRedistribution {
    unit_debt: wad,  // Amount of debt in wad to be distributed to each wad unit of yang
    error: wad,  // Amount of debt to be added to the next redistribution to calculate `debt_per_yang`
}

//
// Absorber
//

// For absorptions, the `asset_amt_per_share` is tied to an absorption ID and is not changed once set.
// For blessings, the `asset_amt_per_share` is a cumulative value that is updated until the given epoch ends
struct AssetApportion {
    asset_amt_per_share: ufelt,  // Amount of asset in its decimal precision per share wad
    error: ufelt,  // Error to be added to next absorption
}

struct Reward {
    asset: address,  // ERC20 address of token
    blesser: address,  // Address of contract implementing `IBlesser` for distributing the token to the absorber
    is_active: bool,  // Whether the blesser (vesting contract) should be called
}

struct Provision {
    epoch: ufelt,  // Epoch in which shares are issued
    shares: wad,  // Amount of shares for provider in the above epoch
}

struct Request {
    timestamp: ufelt,  // Timestamp of request
    timelock: ufelt,  // Amount of time that needs to elapse after the timestamp before removal
    has_removed: bool,  // Whether provider has called `remove`
}
