use option::OptionTrait;
use starknet::StorageBaseAddress;
use traits::{Into, PartialEq, TryInto};
use zeroable::Zeroable;


use aura::utils::wadray;
use aura::utils::wadray::{Ray, Wad};

const HALF_PRIME: felt252 =
    1809251394333065606848661391547535052811553607665798349986546028067936010240;

#[derive(Copy, Drop, Serde, storage_access::StorageAccess)]
struct SignedRay {
    val: u128,
    sign: bool
}

impl SignedRayIntoFelt252 of Into<SignedRay, felt252> {
    fn into(self: SignedRay) -> felt252 {
        let mag_felt: felt252 = self.val.into();

        if self.sign {
            return mag_felt;
        } else {
            return mag_felt * -1;
        }
    }
}

impl U128IntoSignedRay of Into<u128, SignedRay> {
    fn into(self: u128) -> SignedRay {
        SignedRay { val: self, sign: true }
    }
}

impl RayIntoSignedRay of Into<Ray, SignedRay> {
    fn into(self: Ray) -> SignedRay {
        SignedRay { val: self.val, sign: true }
    }
}

impl WadIntoSignedRay of Into<Wad, SignedRay> {
    fn into(self: Wad) -> SignedRay {
        SignedRay { val: self.val * wadray::DIFF, sign: true }
    }
}

impl SignedRayTryIntoRay of TryInto<SignedRay, Ray> {
    fn try_into(self: SignedRay) -> Option<Ray> {
        if self.sign {
            return Option::Some(Ray { val: self.val });
        } else {
            return Option::None(());
        }
    }
}


impl SignedRayAdd of Add<SignedRay> {
    fn add(lhs: SignedRay, rhs: SignedRay) -> SignedRay {
        from_felt(lhs.into() + rhs.into())
    }
}

impl SignedRaySub of Sub<SignedRay> {
    fn sub(lhs: SignedRay, rhs: SignedRay) -> SignedRay {
        from_felt(lhs.into() - rhs.into())
    }
}

impl SignedRayMul of Mul<SignedRay> {
    fn mul(lhs: SignedRay, rhs: SignedRay) -> SignedRay {
        let sign = sign_from_mul(lhs.sign, rhs.sign);
        let val = wadray::rmul_internal(lhs.val, rhs.val);
        SignedRay { val: val, sign: sign }
    }
}

impl SignedRayDiv of Div<SignedRay> {
    fn div(lhs: SignedRay, rhs: SignedRay) -> SignedRay {
        let sign = sign_from_mul(lhs.sign, rhs.sign);
        let val = wadray::rdiv_internal(lhs.val, rhs.val);
        SignedRay { val: val, sign: sign }
    }
}

impl SignedRayZeroable of Zeroable<SignedRay> {
    #[inline(always)]
    fn zero() -> SignedRay {
        SignedRay { val: 0, sign: true }
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

impl SignedRayPartialEq of PartialEq<SignedRay> {
    fn eq(lhs: SignedRay, rhs: SignedRay) -> bool {
        lhs.val == rhs.val & lhs.sign == rhs.sign
    }

    fn ne(lhs: SignedRay, rhs: SignedRay) -> bool {
        lhs.val != rhs.val | lhs.sign != rhs.sign
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
        if lhs.sign & rhs.sign {
            return lhs.val <= rhs.val;
        } else if !lhs.sign & !rhs.sign {
            return lhs.val >= rhs.val;
        } else if lhs.sign & !rhs.sign {
            return false;
        } else {
            return true;
        }
    }

    #[inline(always)]
    fn ge(lhs: SignedRay, rhs: SignedRay) -> bool {
        SignedRayPartialOrd::lt(rhs, lhs)
    }

    #[inline(always)]
    fn lt(lhs: SignedRay, rhs: SignedRay) -> bool {
        if lhs.sign & rhs.sign {
            return lhs.val < rhs.val;
        } else if !lhs.sign & !rhs.sign {
            return lhs.val > rhs.val;
        } else if lhs.sign & !rhs.sign {
            return false;
        } else {
            return true;
        }
    }

    #[inline(always)]
    fn gt(lhs: SignedRay, rhs: SignedRay) -> bool {
        SignedRayPartialOrd::le(rhs, lhs)
    }
}


fn from_felt(val: felt252) -> SignedRay {
    let ray_val = integer::u128_try_from_felt252(_felt_abs(val)).unwrap();
    SignedRay { val: ray_val, sign: _felt_sign(val) }
}

// Returns the sign of a signed `felt252` as with signed magnitude representation
// true = positive
// false = negative
#[inline(always)]
fn _felt_sign(a: felt252) -> bool {
    integer::u256_from_felt252(a) <= integer::u256_from_felt252(HALF_PRIME)
}

// Returns the absolute value of a signed `felt252`
fn _felt_abs(a: felt252) -> felt252 {
    let a_sign = _felt_sign(a);

    if a_sign {
        a
    } else {
        a * -1
    }
}

// Returns the sign of the product in signed multiplication (or quotient in division)
fn sign_from_mul(lhs_sign: bool, rhs_sign: bool) -> bool {
    lhs_sign & rhs_sign | !lhs_sign & !rhs_sign
}
