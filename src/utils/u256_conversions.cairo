use option::OptionTrait;
use traits::Into;
use traits::TryInto;

#[inline(always)]
fn cast_to_u256(a: u128, b: u128) -> (u256, u256) {
    let a_u256: u256 = a.into();
    let b_u256: u256 = b.into();
    (a_u256, b_u256)
}

impl U128IntoU256 of Into<u128, u256> {
    fn into(self: u128) -> u256 {
        u256 { low: self, high: 0_u128 }
    }
}

impl U256TryIntoU128 of TryInto<u256, u128> {
    fn try_into(self: u256) -> Option<u128> {
        if (self.high == 0) {
            Option::Some(self.low)
        } else {
            Option::None(())
        }
    }
}

#[cfg(test)]
mod tests {
    use option::OptionTrait;
    use traits::Into;
    use traits::TryInto;

    use aura::utils::u256_conversions::U128IntoU256;
    use aura::utils::u256_conversions::U256TryIntoU128;

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
