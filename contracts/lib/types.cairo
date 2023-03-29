%lang starknet

from contracts.lib.aliases import ufelt, wad, packed

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

struct Provision {
    epoch: ufelt,  // Epoch in which shares are issued
    shares: wad,  // Amount of shares for provider in the above epoch
}

struct Request {
    timestamp: ufelt,  // Timestamp of request
    timelock: ufelt,  // Amount of time that needs to elapse after the timestamp before removal
}

struct AssetAbsorption {
    asset_amt_per_share: wad,  // Amount of asset in its decimal precision per share wad
    error: wad,  // Error to be added to next absorption
}
