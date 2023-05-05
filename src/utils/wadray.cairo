use integer::{Felt252TryIntoU128, U128IntoFelt252};
use option::OptionTrait;
use traits::{Into, PartialEq, PartialOrd, TryInto};
use zeroable::Zeroable;

use aura::utils::pow::pow10;
use aura::utils::storage_access_impls;
use aura::utils::u256_conversions::{cast_to_u256, U128IntoU256, U256TryIntoU128};

const WAD_DECIMALS: u8 = 18;

const WAD_SCALE: u128 = 1000000000000000000;
const RAY_SCALE: u128 = 1000000000000000000000000000;
const WAD_ONE: u128 = 1000000000000000000;
const RAY_ONE: u128 = 1000000000000000000000000000;
const WAD_PERCENT: u128 = 10000000000000000;
const RAY_PERCENT: u128 = 10000000000000000000000000;

// Largest Wad that can be converted into a Ray without overflowing
const MAX_CONVERTIBLE_WAD: u128 = 99999999999999999999999999999;

// The difference between WAD_SCALE and RAY_SCALE. RAY_SCALE = WAD_SCALE * DIFF
const DIFF: u128 = 1000000000;

#[derive(Copy, Drop, Serde)]
struct Wad {
    val: u128, 
}

#[derive(Copy, Drop, Serde)]
struct Ray {
    val: u128
}

// Core functions

#[inline(always)]
fn wmul(lhs: Wad, rhs: Wad) -> Wad {
    let (lhs_u256, rhs_u256) = cast_to_u256(lhs.val, rhs.val);
    Wad { val: wmul_internal(lhs.val, rhs.val) }
}

// wmul of Wad and Ray -> Ray
#[inline(always)]
fn wmul_wr(lhs: Wad, rhs: Ray) -> Ray {
    Ray { val: wmul_internal(lhs.val, rhs.val) }
}

#[inline(always)]
fn wmul_rw(lhs: Ray, rhs: Wad) -> Ray {
    wmul_wr(rhs, lhs)
}

#[inline(always)]
fn rmul(lhs: Ray, rhs: Ray) -> Ray {
    Ray { val: rmul_internal(lhs.val, rhs.val) }
}

// rmul of Wad and Ray -> Wad
#[inline(always)]
fn rmul_rw(lhs: Ray, rhs: Wad) -> Wad {
    Wad { val: rmul_internal(lhs.val, rhs.val) }
}

#[inline(always)]
fn rmul_wr(lhs: Wad, rhs: Ray) -> Wad {
    rmul_rw(rhs, lhs)
}

#[inline(always)]
fn wdiv(lhs: Wad, rhs: Wad) -> Wad {
    Wad { val: wdiv_internal(lhs.val, rhs.val) }
}

// wdiv of Ray by Wad -> Ray
#[inline(always)]
fn wdiv_rw(lhs: Ray, rhs: Wad) -> Ray {
    Ray { val: wdiv_internal(lhs.val, rhs.val) }
}

#[inline(always)]
fn rdiv(lhs: Ray, rhs: Ray) -> Ray {
    Ray { val: rdiv_internal(lhs.val, rhs.val) }
}

// rdiv of Wad by Ray -> Wad
#[inline(always)]
fn rdiv_wr(lhs: Wad, rhs: Ray) -> Wad {
    Wad { val: rdiv_internal(lhs.val, rhs.val) }
}

// rdiv of Wad by Wad -> Ray
#[inline(always)]
fn rdiv_ww(lhs: Wad, rhs: Wad) -> Ray {
    Ray { val: rdiv_internal(lhs.val, rhs.val) }
}

//
// Internal helpers 
//

#[inline(always)]
fn wmul_internal(lhs: u128, rhs: u128) -> u128 {
    let (lhs_u256, rhs_u256) = cast_to_u256(lhs, rhs);
    (lhs_u256 * rhs_u256 / WAD_ONE.into()).try_into().unwrap()
}

#[inline(always)]
fn rmul_internal(lhs: u128, rhs: u128) -> u128 {
    let (lhs_u256, rhs_u256) = cast_to_u256(lhs, rhs);
    (lhs_u256 * rhs_u256 / RAY_ONE.into()).try_into().unwrap()
}

#[inline(always)]
fn wdiv_internal(lhs: u128, rhs: u128) -> u128 {
    let (lhs_u256, rhs_u256) = cast_to_u256(lhs, rhs);
    ((lhs_u256 * WAD_ONE.into()) / rhs_u256).try_into().unwrap()
}

#[inline(always)]
fn rdiv_internal(lhs: u128, rhs: u128) -> u128 {
    let (lhs_u256, rhs_u256) = cast_to_u256(lhs, rhs);
    ((lhs_u256 * RAY_ONE.into()) / rhs_u256).try_into().unwrap()
}


//
// Trait Implementations
//

// Addition
impl WadAdd of Add<Wad> {
    #[inline(always)]
    fn add(lhs: Wad, rhs: Wad) -> Wad {
        Wad { val: lhs.val + rhs.val }
    }
}

impl RayAdd of Add<Ray> {
    #[inline(always)]
    fn add(lhs: Ray, rhs: Ray) -> Ray {
        Ray { val: lhs.val + rhs.val }
    }
}

impl WadAddEq of AddEq<Wad> {
    #[inline(always)]
    fn add_eq(ref self: Wad, other: Wad) {
        self = self + other;
    }
}

impl RayAddEq of AddEq<Ray> {
    #[inline(always)]
    fn add_eq(ref self: Ray, other: Ray) {
        self = self + other;
    }
}


// Subtraction
impl WadSub of Sub<Wad> {
    #[inline(always)]
    fn sub(lhs: Wad, rhs: Wad) -> Wad {
        Wad { val: lhs.val - rhs.val }
    }
}

impl RaySub of Sub<Ray> {
    #[inline(always)]
    fn sub(lhs: Ray, rhs: Ray) -> Ray {
        Ray { val: lhs.val - rhs.val }
    }
}

impl WadSubEq of SubEq<Wad> {
    #[inline(always)]
    fn sub_eq(ref self: Wad, other: Wad) {
        self = self - other;
    }
}

impl RaySubEq of SubEq<Ray> {
    #[inline(always)]
    fn sub_eq(ref self: Ray, other: Ray) {
        self = self - other;
    }
}


// Multiplication
impl WadMul of Mul<Wad> {
    #[inline(always)]
    fn mul(lhs: Wad, rhs: Wad) -> Wad {
        wmul(lhs, rhs)
    }
}

impl RayMul of Mul<Ray> {
    #[inline(always)]
    fn mul(lhs: Ray, rhs: Ray) -> Ray {
        rmul(lhs, rhs)
    }
}

impl WadMulEq of MulEq<Wad> {
    #[inline(always)]
    fn mul_eq(ref self: Wad, other: Wad) {
        self = self * other;
    }
}

impl RayMulEq of MulEq<Ray> {
    #[inline(always)]
    fn mul_eq(ref self: Ray, other: Ray) {
        self = self * other;
    }
}


// Division
impl WadDiv of Div<Wad> {
    #[inline(always)]
    fn div(lhs: Wad, rhs: Wad) -> Wad {
        wdiv(lhs, rhs)
    }
}

impl RayDiv of Div<Ray> {
    #[inline(always)]
    fn div(lhs: Ray, rhs: Ray) -> Ray {
        rdiv(lhs, rhs)
    }
}

impl WadDivEq of DivEq<Wad> {
    #[inline(always)]
    fn div_eq(ref self: Wad, other: Wad) {
        self = self / other;
    }
}

impl RayDivEq of DivEq<Ray> {
    #[inline(always)]
    fn div_eq(ref self: Ray, other: Ray) {
        self = self / other;
    }
}


// Conversions
impl WadTryIntoRay of TryInto<Wad, Ray> {
    fn try_into(self: Wad) -> Option::<Ray> {
        if (self.val <= MAX_CONVERTIBLE_WAD) {
            Option::Some(Ray { val: self.val * DIFF })
        } else {
            Option::None(())
        }
    }
}

impl RayIntoWad of Into<Ray, Wad> {
    #[inline(always)]
    fn into(self: Ray) -> Wad {
        // The value will get truncated if it has more than 18 decimals.
        Wad { val: self.val / DIFF }
    }
}

impl U128IntoWad of Into<u128, Wad> {
    #[inline(always)]
    fn into(self: u128) -> Wad {
        Wad { val: self }
    }
}

impl U128IntoRay of Into<u128, Ray> {
    #[inline(always)]
    fn into(self: u128) -> Ray {
        Ray { val: self }
    }
}


// Comparisons

impl WadPartialEq of PartialEq<Wad> {
    fn eq(lhs: Wad, rhs: Wad) -> bool {
        lhs.val == rhs.val
    }

    fn ne(lhs: Wad, rhs: Wad) -> bool {
        lhs.val != rhs.val
    }
}

impl RayPartialEq of PartialEq<Ray> {
    fn eq(lhs: Ray, rhs: Ray) -> bool {
        lhs.val == rhs.val
    }

    fn ne(lhs: Ray, rhs: Ray) -> bool {
        lhs.val != rhs.val
    }
}

impl WadPartialOrd of PartialOrd<Wad> {
    fn le(lhs: Wad, rhs: Wad) -> bool {
        lhs.val <= rhs.val
    }

    fn ge(lhs: Wad, rhs: Wad) -> bool {
        lhs.val >= rhs.val
    }

    fn lt(lhs: Wad, rhs: Wad) -> bool {
        lhs.val < rhs.val
    }

    fn gt(lhs: Wad, rhs: Wad) -> bool {
        lhs.val > rhs.val
    }
}

impl RayPartialOrd of PartialOrd<Ray> {
    fn le(lhs: Ray, rhs: Ray) -> bool {
        lhs.val <= rhs.val
    }

    fn ge(lhs: Ray, rhs: Ray) -> bool {
        lhs.val >= rhs.val
    }

    fn lt(lhs: Ray, rhs: Ray) -> bool {
        lhs.val < rhs.val
    }

    fn gt(lhs: Ray, rhs: Ray) -> bool {
        lhs.val > rhs.val
    }
}

// Zeroable
impl WadZeroable of Zeroable<Wad> {
    #[inline(always)]
    fn zero() -> Wad {
        Wad { val: 0 }
    }

    #[inline(always)]
    fn is_zero(self: Wad) -> bool {
        self.val == 0
    }

    #[inline(always)]
    fn is_non_zero(self: Wad) -> bool {
        self.val != 0
    }
}

impl RayZeroable of Zeroable<Ray> {
    #[inline(always)]
    fn zero() -> Ray {
        Ray { val: 0 }
    }

    #[inline(always)]
    fn is_zero(self: Ray) -> bool {
        self.val == 0
    }

    #[inline(always)]
    fn is_non_zero(self: Ray) -> bool {
        self.val != 0
    }
}

fn fixed_point_to_wad(n: u128, decimals: u8) -> Wad {
    assert(decimals <= WAD_DECIMALS, 'wadray: more than 18 decimals');
    let scale: u128 = pow10(WAD_DECIMALS - decimals);
    (n * scale).into()
}

#[cfg(test)]
mod tests {
    use option::OptionTrait;
    use traits::Into;
    use traits::TryInto;
    use zeroable::Zeroable;

    use aura::utils::wadray;
    use aura::utils::wadray::{
        DIFF, MAX_CONVERTIBLE_WAD, Ray, RAY_ONE, rdiv_wr, rmul_rw, rmul_wr, Wad, WAD_ONE, wdiv_rw,
        wmul_rw, wmul_wr
    };


    #[test]
    fn test_add() {
        // 0 + 0 = 0
        assert(Wad { val: 0 } + Wad { val: 0 } == Wad { val: 0 }, 'Incorrect addition #1');

        // 1 + 1 = 2
        assert(Wad { val: 1 } + Wad { val: 1 } == Wad { val: 2 }, 'Incorrect addition #2');

        // 123456789101112 + 121110987654321 = 244567776755433
        assert(
            Wad {
                val: 123456789101112
                } + Wad {
                val: 121110987654321
                } == Wad {
                val: 244567776755433
            },
            'Incorrect addition #3'
        );

        // 0 + 0 = 0
        assert(Ray { val: 0 } + Ray { val: 0 } == Ray { val: 0 }, 'Incorrect addition #4');

        // 1 + 1 = 2
        assert(Ray { val: 1 } + Ray { val: 1 } == Ray { val: 2 }, 'Incorrect addition #5');

        // 123456789101112 + 121110987654321 = 244567776755433
        assert(
            Ray {
                val: 123456789101112
                } + Ray {
                val: 121110987654321
                } == Ray {
                val: 244567776755433
            },
            'Incorrect addition #6'
        );
    }

    #[test]
    fn test_add_eq() {
        let mut a1 = Wad { val: 5 };
        let a2 = Wad { val: 5 };
        let b = Wad { val: 3 };

        a1 += b;
        assert(a1 == a2 + b, 'Incorrect AddEq #1');
    }


    #[test]
    fn test_sub() {
        // 0 - 0 = 0
        assert(Wad { val: 0 } - Wad { val: 0 } == Wad { val: 0 }, 'Incorrect subtraction #1');

        // 2 - 1 = 1
        assert(Wad { val: 2 } - Wad { val: 1 } == Wad { val: 1 }, 'Incorrect subtraction #2');

        // 244567776755433 - 121110987654321 = 123456789101112
        assert(
            Wad {
                val: 244567776755433
                } - Wad {
                val: 121110987654321
                } == Wad {
                val: 123456789101112
            },
            'Incorrect subtraction #3'
        );

        // 0 - 0 = 0
        assert(Ray { val: 0 } - Ray { val: 0 } == Ray { val: 0 }, 'Incorrect subtraction #4');

        // 2 - 1 = 1
        assert(Ray { val: 2 } - Ray { val: 1 } == Ray { val: 1 }, 'Incorrect subtraction #5');

        // 244567776755433 - 121110987654321 = 123456789101112
        assert(
            Ray {
                val: 244567776755433
                } - Ray {
                val: 121110987654321
                } == Ray {
                val: 123456789101112
            },
            'Incorrect subtraction #6'
        );
    }

    #[test]
    fn test_sub_eq() {
        let mut a1 = Wad { val: 5 };
        let a2 = Wad { val: 5 };
        let b = Wad { val: 3 };

        a1 -= b;
        assert(a1 == a2 - b, 'Incorrect SubEq #1');
    }


    #[test]
    fn test_mul() {
        // 0 * 69 = 0
        assert(Wad { val: 0 } * Wad { val: 69 } == Wad { val: 0 }, 'Incorrect Multiplication # 1');

        // 1 * 1 = 0 (truncated)
        assert(
            Wad { val: 1 } * Wad { val: 1 } == Wad { val: 0 }, 'Incorrect multiplication #2'
        ); // Result should be truncated

        // 1 (wad) * 1 (wad) = 1 (wad)
        assert(
            Wad { val: WAD_ONE } * Wad { val: WAD_ONE } == Wad { val: WAD_ONE },
            'Incorrect multiplication #3'
        );

        // 121110987654321531059 * 1234567891011125475893 = 149519736606670187008926
        assert(
            Wad {
                val: 121110987654321531059
                } * Wad {
                val: 1234567891011125475893
                } == Wad {
                val: 149519736606670187008926
            },
            'Incorrect multiplication #4'
        );

        // 0 * 69 = 0
        assert(Ray { val: 0 } * Ray { val: 69 } == Ray { val: 0 }, 'Incorrect Multiplication #5');

        // 1 * 1 = 0 (truncated)
        assert(
            Ray { val: 1 } * Ray { val: 1 } == Ray { val: 0 }, 'Incorrect multiplication #6'
        ); // Result should be truncated

        // 1 (ray) * 1 (ray) = 1 (ray)
        assert(
            Ray { val: RAY_ONE } * Ray { val: RAY_ONE } == Ray { val: RAY_ONE },
            'Incorrect multiplication #7'
        );

        // 121110987654321531059 * 1234567891011125475893 = 149519736606670 (truncated)
        assert(
            Ray {
                val: 121110987654321531059
                } * Ray {
                val: 1234567891011125475893
                } == Ray {
                val: 149519736606670
            },
            'Incorrect multiplication #8'
        );

        // wmul(ray, wad) -> ray
        assert(
            wmul_rw(Ray { val: RAY_ONE }, Wad { val: WAD_ONE }) == Ray { val: RAY_ONE },
            'Incorrect multiplication #9'
        );

        // wmul(wad, ray) -> ray
        assert(
            wmul_wr(Wad { val: WAD_ONE }, Ray { val: RAY_ONE }) == Ray { val: RAY_ONE },
            'Incorrect multiplication #10'
        );

        // rmul(ray, wad) -> wad
        assert(
            rmul_rw(Ray { val: RAY_ONE }, Wad { val: WAD_ONE }) == Wad { val: WAD_ONE },
            'Incorrect multiplication #11'
        );

        // rmul(wad, ray) -> wad
        assert(
            rmul_wr(Wad { val: WAD_ONE }, Ray { val: RAY_ONE }) == Wad { val: WAD_ONE },
            'Incorrect multiplication #12'
        );
    }

    #[test]
    fn test_mul_eq() {
        let mut a1 = Wad { val: 5 };
        let a2 = Wad { val: 5 };
        let b = Wad { val: 3 };

        a1 *= b;
        assert(a1 == a2 * b, 'Incorrect MulEq #1');
    }


    #[test]
    fn test_div() {
        // 2 / (1 / 2) = 4 (wad)
        assert(
            Wad { val: 2 * WAD_ONE } / Wad { val: WAD_ONE / 2 } == Wad { val: 4 * WAD_ONE },
            'Incorrect division #1'
        );

        // 2 / (1 / 2) = 4 (ray)
        assert(
            Ray { val: 2 * RAY_ONE } / Ray { val: RAY_ONE / 2 } == Ray { val: 4 * RAY_ONE },
            'Incorrect division #2'
        );

        // wdiv(ray, wad) -> ray
        assert(
            wdiv_rw(Ray { val: RAY_ONE }, Wad { val: WAD_ONE }) == Ray { val: RAY_ONE },
            'Incorrect division #3'
        );

        // rdiv(wad, ray) -> wad
        assert(
            rdiv_wr(Wad { val: WAD_ONE }, Ray { val: RAY_ONE }) == Wad { val: WAD_ONE },
            'Incorrect division #4'
        );
    }

    #[test]
    fn test_div_eq() {
        let mut a1 = Wad { val: 15 };
        let a2 = Wad { val: 15 };
        let b = Wad { val: 3 };

        a1 /= b;
        assert(a1 == a2 / b, 'Incorrect DivEq #1');
    }


    #[test]
    #[should_panic(expected: ('u256 is 0', ))]
    fn test_div_wad_fail() {
        let a: Wad = Wad { val: WAD_ONE } / Wad { val: 0 };
    }

    #[test]
    #[should_panic(expected: ('u256 is 0', ))]
    fn test_div_ray_fail() {
        let a: Ray = Ray { val: RAY_ONE } / Ray { val: 0 };
    }

    #[test]
    fn test_conversions() {
        // Test conversion from Wad to Ray
        let a: Ray = Wad { val: WAD_ONE }.try_into().unwrap();
        assert(a.val == RAY_ONE, 'Incorrect wad->ray conversion');

        let a: Ray = Wad { val: MAX_CONVERTIBLE_WAD }.try_into().unwrap();
        assert(a.val == MAX_CONVERTIBLE_WAD * DIFF, 'Incorrect wad->ray conversion');

        let a: Option::<Ray> = Wad { val: MAX_CONVERTIBLE_WAD + 1 }.try_into();
        assert(a.is_none(), 'Incorrect wad->ray conversion');

        // Test conversion from Ray to Wad
        let a: Wad = Ray { val: RAY_ONE }.into();
        assert(a.val == WAD_ONE, 'Incorrect ray->wad conversion');
    }

    #[test]
    fn test_u128_into_wadray() {
        // Test U128IntoWad
        let wad_value: u128 = 42;
        let wad_result: Wad = wad_value.into();
        assert(wad_result.val == wad_value, 'Incorrect u128->Wad conversion');

        // Test U128IntoRay
        let ray_value: u128 = 84;
        let ray_result: Ray = ray_value.into();
        assert(ray_result.val == ray_value, 'Incorrect u128->Ray conversion');
    }

    #[test]
    #[should_panic(expected: ('Option::unwrap failed.', ))]
    fn test_conversions_fail2() {
        let a: Ray = Wad { val: MAX_CONVERTIBLE_WAD + 1 }.try_into().unwrap();
    }

    #[test]
    fn test_comparisons() {
        // Test Wad type comparison operators: <, >, <=, >=
        assert(Wad { val: WAD_ONE } < Wad { val: WAD_ONE + 1 }, 'Incorrect < comparison #1');
        assert(Wad { val: WAD_ONE + 1 } > Wad { val: WAD_ONE }, 'Incorrect > comparison #2');
        assert(Wad { val: WAD_ONE } <= Wad { val: WAD_ONE }, 'Incorrect <= comparison #3');
        assert(Wad { val: WAD_ONE + 1 } >= Wad { val: WAD_ONE + 1 }, 'Incorrect >= comparison #4');

        // Test Ray type comparison operators: <, >, <=, >=
        assert(Ray { val: RAY_ONE } < Ray { val: RAY_ONE + 1 }, 'Incorrect < comparison #5');
        assert(Ray { val: RAY_ONE + 1 } > Ray { val: RAY_ONE }, 'Incorrect > comparison #6');
        assert(Ray { val: RAY_ONE } <= Ray { val: RAY_ONE }, 'Incorrect <= comparison #7');
        assert(Ray { val: RAY_ONE + 1 } >= Ray { val: RAY_ONE + 1 }, 'Incorrect >= comparison #8');

        // Test Ray type opposite comparisons: !(<), !(>), !(<=), !(>=)
        assert(!(Ray { val: RAY_ONE } < Ray { val: RAY_ONE }), 'Incorrect < comparison #9');
        assert(!(Ray { val: RAY_ONE } > Ray { val: RAY_ONE }), 'Incorrect > comparison #10');
        assert(!(Ray { val: RAY_ONE + 1 } <= Ray { val: RAY_ONE }), 'Incorrect <= comparison #11');
        assert(!(Ray { val: RAY_ONE } >= Ray { val: RAY_ONE + 1 }), 'Incorrect >= comparison #12');

        // Test Wad type opposite comparisons: !(<), !(>), !(<=), !(>=)
        assert(!(Wad { val: WAD_ONE } < Wad { val: WAD_ONE }), 'Incorrect < comparison #13');
        assert(!(Wad { val: WAD_ONE } > Wad { val: WAD_ONE }), 'Incorrect > comparison #14');
        assert(!(Wad { val: WAD_ONE + 1 } <= Wad { val: WAD_ONE }), 'Incorrect <= comparison #15');
        assert(!(Wad { val: WAD_ONE } >= Wad { val: WAD_ONE + 1 }), 'Incorrect >= comparison #16');

        // Test Wad type != operator
        assert(Wad { val: WAD_ONE } != Wad { val: WAD_ONE + 1 }, 'Incorrect != comparison #17');
        assert(!(Wad { val: WAD_ONE } != Wad { val: WAD_ONE }), 'Incorrect != comparison #18');

        // Test Ray type != operator
        assert(Ray { val: RAY_ONE } != Ray { val: RAY_ONE + 1 }, 'Incorrect != comparison #19');
        assert(!(Ray { val: RAY_ONE } != Ray { val: RAY_ONE }), 'Incorrect != comparison #20');
    }

    #[test]
    fn test_zeroable() {
        // Test zero
        let wad_zero = Wad { val: 0 };
        assert(wad_zero.val == 0, 'Value should be 0 #1');

        // Test is_zero
        let wad_one = Wad { val: 1 };
        assert(wad_zero.is_zero(), 'Value should be 0 #2');
        assert(!wad_one.is_zero(), 'Value should not be 0 #3');

        // Test is_non_zero
        assert(!wad_zero.is_non_zero(), 'Value should be 0 #4');
        assert(wad_one.is_non_zero(), 'Value should not be 0 #5');

        let ray_zero = Ray { val: 0 };
        assert(ray_zero.val == 0, 'Value should be 0 #6');

        // Test is_zero
        let ray_one = Ray { val: 1 };
        assert(ray_zero.is_zero(), 'Value should be 0 #7');
        assert(!ray_one.is_zero(), 'Value should not be 0 #8');

        // Test is_non_zero
        assert(!ray_zero.is_non_zero(), 'Value should be 0 #9');
        assert(ray_one.is_non_zero(), 'Value should not be 0 #10');
    }
}
