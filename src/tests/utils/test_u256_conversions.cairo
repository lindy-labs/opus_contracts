#[cfg(test)]
mod tests {
    use option::OptionTrait;
    use traits::{Into, TryInto};

    use super::{U128IntoU256, U256TryIntoU8, U256TryIntoU64, U256TryIntoU128};

    const SOME_U128: u128 = 1000;

    #[test]
    fn test_conversions_u256_tryinto_u8() {
        let some = 42_u256;
        let converted: u8 = some.try_into().unwrap();
        assert(converted == 42_u8, 'Incorrect u256->u8 conversion');
    }

    #[test]
    fn test_conversions_u256_tryinto_u64() {
        let some = 42_u256;
        let converted: u64 = some.try_into().unwrap();
        assert(converted == 42_u64, 'Incorrect u256->u64 conversion');
    }

    #[test]
    fn test_conversions_u128_into_u256() {
        let some_u256: u256 = SOME_U128.into();
        assert(some_u256.low == SOME_U128 & some_u256.high == 0, 'Incorrect u128->u256 conversion');
    }

    #[test]
    fn test_conversions_u256_tryinto_u128() {
        let a: u128 = u256 { low: SOME_U128, high: 0 }.try_into().unwrap();
        assert(a == SOME_U128, 'Incorrect u256->u128 conversion');
    }

    #[test]
    #[should_panic(expected: ('Option::unwrap failed.', ))]
    fn test_conversions_u256_tryinto_u8_overflow() {
        let a: u8 = u256 { low: 256, high: 0 }.try_into().unwrap();
    }

    #[test]
    #[should_panic(expected: ('Option::unwrap failed.', ))]
    fn test_conversions_u256_tryinto_u64_overflow() {
        let a: u64 = u256 { low: 0x10000000000000000, high: 0 }.try_into().unwrap();
    }

    #[test]
    #[should_panic(expected: ('Option::unwrap failed.', ))]
    fn test_conversions_u256_tryinto_u128_overflow() {
        let a: u128 = u256 { low: SOME_U128, high: 1 }.try_into().unwrap();
    }
}
