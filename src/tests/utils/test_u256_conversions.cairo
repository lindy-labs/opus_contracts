#[cfg(test)]
mod tests {
    use option::OptionTrait;
    use traits::{Into, TryInto};

    use aura::utils::u256_conversions::{U128IntoU256, U256TryIntoU128};

    const SOME_U128: u128 = 1000;
    #[test]
    fn test_conversions() {
        // Test conversion from u128 to u256

        let some_u256: u256 = SOME_U128.into();
        assert(some_u256.low == SOME_U128 & some_u256.high == 0, 'Incorrect u128->u256 conversion');

        // Test conversion from u256 to u128
        let a: u128 = u256 { low: SOME_U128, high: 0 }.try_into().unwrap();
        assert(a == SOME_U128, 'Incorrect u256->u128 conversion');
    }

    #[test]
    #[should_panic(expected: ('Option::unwrap failed.', ))]
    fn test_conversions_fail() {
        let a: u128 = u256 { low: SOME_U128, high: 1 }.try_into().unwrap();
    }
}
