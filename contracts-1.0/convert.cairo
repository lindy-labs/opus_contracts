use contracts::dummy_syscalls;

// 2 ** 128
const LOW_UPPER_BOUND: felt = 340282366920938463463374607431768211456;

// 2 ** 123
const HIGH_UPPER_BOUND: felt = 10633823966279326983230456482242756608;

// 2 ** 125
const PACKED_125_UPPER_BOUND: felt = 42535295865117307932921825928971026432;

// For conversion of felt to uint, use `u256_from_felt` from corelib

fn uint_to_felt_unchecked(value: u256) -> felt {
    let res = u128_to_felt(value.low) + u128_to_felt(value.high) * LOW_UPPER_BOUND;
    res
}

// Packs `low` into the first 128 bits, packs `high` into the last 123 bits
// Requires that 0 <= low < 2**128 and 0 <= high < 2**123
fn pack_felt(high: felt, low: felt) -> felt {
    assert(0 <= low & low < LOW_UPPER_BOUND, 'Convert: `low` is out of range');
    assert(0 <= high & high < HIGH_UPPER_BOUND, 'Convert: `high` is out of range');
    low + high * LOW_UPPER_BOUND
}

fn pack_125(high: felt, low: felt) -> felt {
    assert(0 <= low & low < PACKED_125_UPPER_BOUND, 'Convert: `low` is out of range');
    assert(0 <= high & high < PACKED_125_UPPER_BOUND, 'Convert: `high` is out of range');
    low + high * PACKED_125_UPPER_BOUND
}

// TODO: to be implemented once `split_int` is in corelib
fn unpack_125(packed: felt) -> (felt, felt) {
    dummy_syscalls::split_int()
}
