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

struct YangRedistribution {
    unit_debt: wad,  // Amount of debt in wad to be distributed to each wad unit of yang
    error: wad,  // Amount of debt to be added to the next redistribution to calculate `debt_per_yang`
}
