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
