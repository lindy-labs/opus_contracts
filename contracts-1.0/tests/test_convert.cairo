use contracts::convert;

#[test]
fn test_uint_to_felt_unchecked_pass() {
    let val: u256 = u256 { low: 1_u128, high: 0_u128,  };
    assert(convert::uint_to_felt_unchecked(val) == 1, 'invalid result');
}

#[test]
fn test_pack_felt_pass() {
    assert(convert::pack_felt(0, 1) == 1, 'invalid result');
    assert(convert::pack_felt(1, 0) == convert::LOW_UPPER_BOUND, 'invalid result');
}

#[test]
#[should_panic]
fn test_pack_felt_fail() {
    // low exceeds upper bound
    let invalid_low_upper_bound = convert::LOW_UPPER_BOUND + 1;
    convert::pack_felt(0, invalid_low_upper_bound);

    // high exceeds upper bound
    let invalid_high_upper_bound = convert::HIGH_UPPER_BOUND + 1;
    convert::pack_felt(invalid_high_upper_bound, 0);

    // lower bound is exceeded
    let invalid_lower_bound = -1;
    convert::pack_felt(invalid_lower_bound, 0);
    convert::pack_felt(0, invalid_lower_bound);
}

#[test]
fn test_pack_125_pass() {
    assert(convert::pack_125(0, 1) == 1, 'invalid result');
    assert(convert::pack_125(1, 0) == convert::PACKED_125_UPPER_BOUND, 'invalid result');
}

#[test]
#[should_panic]
fn test_pack_125_fail() {
    // upper bound is exceeded
    let invalid_upper_bound = convert::PACKED_125_UPPER_BOUND + 1;
    convert::pack_125(0, invalid_upper_bound);
    convert::pack_125(invalid_upper_bound, 0);

    // low exceeds lower bound
    let invalid_lower_bound = -1;
    convert::pack_125(invalid_lower_bound, 0);
    convert::pack_125(0, invalid_lower_bound);
}

#[test]
fn test_unpack_125_pass() {
    let (low, high) = convert::unpack_125(1);
    assert(low == 1, 'invalid result');
    assert(high == 2, 'invalid result');
}
