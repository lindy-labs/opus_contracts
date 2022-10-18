%lang starknet

from contracts.lib.aliases import ufelt, wad

struct Trove {
    charge_from: ufelt,  // Time ID (timestamp // TIME_ID_INTERVAL) for start of next accumulated interest calculation
    debt: wad,  // Normalized debt
}

struct Yang {
    total: wad,  // Total amount of the Yang currently deposited
    max: wad,  // Maximum amount of the Yang that can be deposited
}

struct YangPendingDebt {
    total: wad,
    debt_per_yang: wad,
}
