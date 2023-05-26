use option::OptionTrait;
use traits::{Into, TryInto};

#[inline(always)]
fn cast_to_u256(a: u128, b: u128) -> (u256, u256) {
    (a.into(), b.into())
}

impl U128IntoU256 of Into<u128, u256> {
    #[inline(always)]
    fn into(self: u128) -> u256 {
        u256 { low: self, high: 0_u128 }
    }
}

impl U256TryIntoU8 of TryInto<u256, u8> {
    // cannot yet be marked as inline
    // https://github.com/starkware-libs/cairo/issues/3211
    fn try_into(self: u256) -> Option<u8> {
        if (self.high == 0) {
            self.low.try_into()
        } else {
            Option::None(())
        }
    }
}

impl U256TryIntoU64 of TryInto<u256, u64> {
    // cannot yet be marked as inline
    // https://github.com/starkware-libs/cairo/issues/3211
    fn try_into(self: u256) -> Option<u64> {
        if (self.high == 0) {
            self.low.try_into()
        } else {
            Option::None(())
        }
    }
}

impl U256TryIntoU128 of TryInto<u256, u128> {
    #[inline(always)]
    fn try_into(self: u256) -> Option<u128> {
        if (self.high == 0) {
            Option::Some(self.low)
        } else {
            Option::None(())
        }
    }
}
