%lang starknet

struct Trove {
    charge_from: felt,  // Time ID (timestamp // TIME_ID_INTERVAL) for start of next accumulated interest calculation
    debt: felt,  // Normalized debt
}

struct Yang {
    total: felt,  // Total amount of the Yang currently deposited
    max: felt,  // Maximum amount of the Yang that can be deposited
}
