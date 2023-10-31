use debug::PrintTrait;
use integer::BoundedI128;
use math::Oneable;

use opus::utils::wadray;
use opus::utils::wadray::{Ray, Wad};

const WAD_ONE: i128 = 1000000000000000000;
const RAY_ONE: i128 = 1000000000000000000000000000;


impl I128TryIntoU128 of TryInto<i128, u128> {
    fn try_into(self: i128) -> Option<u128> {
        if self < 0 {
            Option::None
        } else {
            let val: felt252 = self.into();
            val.try_into()
        }
    }
}

impl U128TryIntoI128 of TryInto<u128, i128> {
    fn try_into(self: u128) -> Option<i128> {
        if self > BoundedI128::max().try_into().unwrap() {
            Option::None
        } else {
            let val: felt252 = self.into();
            val.try_into()
        }
    }
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct SignedWad {
    val: i128,
}

impl I128IntoSignedWad of Into<i128, SignedWad> {
    fn into(self: i128) -> SignedWad {
        SignedWad { val: self }
    }
}

impl WadTryIntoSignedWad of TryInto<Wad, SignedWad> {
    fn try_into(self: Wad) -> Option<SignedWad> {
        let val: Option<i128> = self.val.try_into();
        if val.is_some() {
            Option::Some(val.unwrap().into())
        } else {
            Option::None
        }
    }
}

impl SignedWadTryIntoWad of TryInto<SignedWad, Wad> {
    fn try_into(self: SignedWad) -> Option<Wad> {
        let val: Option<u128> = self.val.try_into();
        if val.is_some() {
            Option::Some(val.unwrap().into())
        } else {
            Option::None
        }
    }
}

impl SignedWadNeg of Neg<SignedWad> {
    fn neg(a: SignedWad) -> SignedWad {
        SignedWad { val: -a.val }
    }
}

impl SignedWadAdd of Add<SignedWad> {
    fn add(lhs: SignedWad, rhs: SignedWad) -> SignedWad {
        (lhs.val + rhs.val).into()
    }
}

impl SignedWadSub of Sub<SignedWad> {
    fn sub(lhs: SignedWad, rhs: SignedWad) -> SignedWad {
        (lhs.val - rhs.val).into()
    }
}

impl SignedWadMul of Mul<SignedWad> {
    fn mul(lhs: SignedWad, rhs: SignedWad) -> SignedWad {
        let sign = sign_from_mul(lhs.val, rhs.val);
        let val = wadray::wmul_internal(abs_i128(lhs.val), abs_i128(rhs.val));
        let val: i128 = val.try_into().unwrap();
        if sign {
            (-val).into()
        } else {
            val.into()
        }
    }
}

impl SignedWadDiv of Div<SignedWad> {
    fn div(lhs: SignedWad, rhs: SignedWad) -> SignedWad {
        let sign = sign_from_mul(lhs.val, rhs.val);
        let val = wadray::wdiv_internal(abs_i128(lhs.val), abs_i128(rhs.val));
        let val: i128 = val.try_into().unwrap();
        if sign {
            (-val).into()
        } else {
            val.into()
        }
    }
}

impl SignedWadZeroable of Zeroable<SignedWad> {
    #[inline(always)]
    fn zero() -> SignedWad {
        0_i128.into()
    }

    #[inline(always)]
    fn is_zero(self: SignedWad) -> bool {
        self.val == 0
    }

    #[inline(always)]
    fn is_non_zero(self: SignedWad) -> bool {
        self.val != 0
    }
}

impl SignedWadOneable of Oneable<SignedWad> {
    #[inline(always)]
    fn one() -> SignedWad {
        WAD_ONE.into()
    }

    #[inline(always)]
    fn is_one(self: SignedWad) -> bool {
        self.val == WAD_ONE
    }

    #[inline(always)]
    fn is_non_one(self: SignedWad) -> bool {
        self.val != WAD_ONE
    }
}

impl SignedWadPartialEq of PartialEq<SignedWad> {
    fn eq(lhs: @SignedWad, rhs: @SignedWad) -> bool {
        *lhs.val == *rhs.val
    }

    fn ne(lhs: @SignedWad, rhs: @SignedWad) -> bool {
        *lhs.val != *rhs.val
    }
}

impl SignedWadAddEq of AddEq<SignedWad> {
    #[inline(always)]
    fn add_eq(ref self: SignedWad, other: SignedWad) {
        self = self + other;
    }
}

impl SignedWadPartialOrd of PartialOrd<SignedWad> {
    #[inline(always)]
    fn le(lhs: SignedWad, rhs: SignedWad) -> bool {
        lhs.val <= rhs.val
    }

    #[inline(always)]
    fn ge(lhs: SignedWad, rhs: SignedWad) -> bool {
        lhs.val >= rhs.val
    }

    #[inline(always)]
    fn lt(lhs: SignedWad, rhs: SignedWad) -> bool {
        lhs.val < rhs.val
    }

    #[inline(always)]
    fn gt(lhs: SignedWad, rhs: SignedWad) -> bool {
        lhs.val > rhs.val
    }
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct SignedRay {
    val: i128,
}

impl I128IntoSignedRay of Into<i128, SignedRay> {
    fn into(self: i128) -> SignedRay {
        SignedRay { val: self }
    }
}

impl RayIntoSignedRay of Into<Ray, SignedRay> {
    fn into(self: Ray) -> SignedRay {
        let val: i128 = self.val.try_into().unwrap();
        val.into()
    }
}

impl WadIntoSignedRay of Into<Wad, SignedRay> {
    fn into(self: Wad) -> SignedRay {
        let val: u128 = self.val * wadray::DIFF;
        let val: i128 = val.try_into().unwrap();
        val.into()
    }
}

impl SignedRayTryIntoRay of TryInto<SignedRay, Ray> {
    fn try_into(self: SignedRay) -> Option<Ray> {
        if self.val >= 0 {
            return Option::Some(Ray { val: self.val.try_into().unwrap() });
        } else {
            return Option::None;
        }
    }
}


impl SignedRayAdd of Add<SignedRay> {
    fn add(lhs: SignedRay, rhs: SignedRay) -> SignedRay {
        (lhs.val + rhs.val).into()
    }
}

impl SignedRaySub of Sub<SignedRay> {
    fn sub(lhs: SignedRay, rhs: SignedRay) -> SignedRay {
        (lhs.val - rhs.val).into()
    }
}

impl SignedRayMul of Mul<SignedRay> {
    fn mul(lhs: SignedRay, rhs: SignedRay) -> SignedRay {
        let sign = sign_from_mul(lhs.val, rhs.val);
        let val = wadray::rmul_internal(abs_i128(lhs.val), abs_i128(rhs.val));
        let val: i128 = val.try_into().unwrap();
        if sign {
            (-val).into()
        } else {
            val.into()
        }
    }
}

impl SignedRayDiv of Div<SignedRay> {
    fn div(lhs: SignedRay, rhs: SignedRay) -> SignedRay {
        let sign = sign_from_mul(lhs.val, rhs.val);
        let val = wadray::rdiv_internal(abs_i128(lhs.val), abs_i128(rhs.val));
        let val: i128 = val.try_into().unwrap();
        if sign {
            (-val).into()
        } else {
            val.into()
        }
    }
}

impl SignedRayZeroable of Zeroable<SignedRay> {
    #[inline(always)]
    fn zero() -> SignedRay {
        0_i128.into()
    }

    #[inline(always)]
    fn is_zero(self: SignedRay) -> bool {
        self.val == 0
    }

    #[inline(always)]
    fn is_non_zero(self: SignedRay) -> bool {
        self.val != 0
    }
}

impl SignedRayOneable of Oneable<SignedRay> {
    #[inline(always)]
    fn one() -> SignedRay {
        RAY_ONE.into()
    }

    #[inline(always)]
    fn is_one(self: SignedRay) -> bool {
        self.val == RAY_ONE
    }

    #[inline(always)]
    fn is_non_one(self: SignedRay) -> bool {
        self.val != RAY_ONE
    }
}

impl SignedRayPartialEq of PartialEq<SignedRay> {
    fn eq(lhs: @SignedRay, rhs: @SignedRay) -> bool {
        *lhs.val == *rhs.val
    }

    fn ne(lhs: @SignedRay, rhs: @SignedRay) -> bool {
        *lhs.val != *rhs.val
    }
}

impl SignedRayAddEq of AddEq<SignedRay> {
    #[inline(always)]
    fn add_eq(ref self: SignedRay, other: SignedRay) {
        self = self + other;
    }
}

impl SignedRayPartialOrd of PartialOrd<SignedRay> {
    #[inline(always)]
    fn le(lhs: SignedRay, rhs: SignedRay) -> bool {
        lhs.val <= rhs.val
    }

    #[inline(always)]
    fn ge(lhs: SignedRay, rhs: SignedRay) -> bool {
        lhs.val >= rhs.val
    }

    #[inline(always)]
    fn lt(lhs: SignedRay, rhs: SignedRay) -> bool {
        lhs.val < rhs.val
    }

    #[inline(always)]
    fn gt(lhs: SignedRay, rhs: SignedRay) -> bool {
        lhs.val > rhs.val
    }
}

// Returns the sign of the product in signed multiplication (or quotient in division)
fn sign_from_mul(lhs: i128, rhs: i128) -> bool {
    (!(lhs < 0) && rhs < 0) || (lhs < 0 && !(rhs < 0))
}

fn abs_i128(a: i128) -> u128 {
    if a < 0 {
        let tmp: felt252 = (-a).into();
        tmp.try_into().unwrap()
    } else {
        let tmp: felt252 = a.into();
        tmp.try_into().unwrap()
    }
}
