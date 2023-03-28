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

struct Absorption {
    epoch: ufelt,  // Epoch in which absorption happened
    interval: ufelt,  // Interval in which absorption happened
    after_yin_per_share: wad,  // Amount of yin per share after the absorption
}

struct PackedAbsorption {
    // Packed felt of:
    // Epoch in which absorption happened
    // - Interval in which absorption happened
    info: packed,
    yin_per_share: wad,
}

struct PackedRemoval {
    // Packed felt of:
    // - Interval in which removal was requested
    // - Absorption ID when removal was requested
    info: packed,
    // Packed felt of:
    // - Amount of shares for which removal was requested
    // - Epoch of shares subject to removal
    shares_info: packed,
}

struct Provision {
    epoch: ufelt,  // Epoch in which shares are issued
    shares: wad,  // Amount of shares for provider in the above epoch
}

struct Removal {
    interval: ufelt,  // Interval in which removal was requested
    absorption_id: ufelt,  // Absorption ID when removal was requested
    shares: wad,  // Amount of shares for which removal was requested
    epoch: ufelt,  // Epoch of shares subject to removal
}

struct AssetAbsorption {
    asset_amt_per_share: wad,  // Amount of asset in its decimal precision per share wad
    error: wad,  // Error to be added to next absorption
}

struct Suspension {
    yin: wad,
    interval: ufelt,
}
