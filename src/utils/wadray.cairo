use integer::U128IntoFelt252;
use integer::Felt252TryIntoU128;
use option::OptionTrait;
use traits::Into;
use traits::TryInto;
use traits::PartialEq;


const WAD_SCALE: u128 = 1000000000000000000_u128;
const RAY_SCALE: u128 = 1000000000000000000000000000_u128;
const WAD_ONE: u128 = 1000000000000000000_u128;
const RAY_ONE: u128 = 1000000000000000000000000000_u128;

// The difference between WAD_SCALE and RAY_SCALE. RAY_SCALE = WAD_SCALE * DIFF
const DIFF: u128 = 1000000000_u128;

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
fn cast_to_u256(a: u128, b: u128) -> (u256, u256) {
    let a_u256: u256 = a.into();
    let b_u256: u256 = b.into();
    (a_u256, b_u256)
}

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

// Traits
trait FixedPointTrait<T> {
    fn new(val: u128) -> T;
    fn val(self: T) -> u128;
}

//
// Implementations
//

// Fixed Point Type basic functions

impl WadImpl of FixedPointTrait<Wad> {
    fn new(val: u128) -> Wad {
        Wad { val: val }
    }

    fn val(self: Wad) -> u128 {
        self.val
    }
}

impl RayImpl of FixedPointTrait<Ray> {
    fn new(val: u128) -> Ray {
        Ray { val: val }
    }

    fn val(self: Ray) -> u128 {
        self.val
    }
}

// Addition
impl WadAdd of Add<Wad> {
    fn add(lhs: Wad, rhs: Wad) -> Wad {
        Wad { val: lhs.val + rhs.val }
    }
}

impl RayAdd of Add<Ray> {
    fn add(lhs: Ray, rhs: Ray) -> Ray {
        Ray { val: lhs.val + rhs.val }
    }
}

// Subtraction
impl WadSub of Sub<Wad> {
    fn sub(lhs: Wad, rhs: Wad) -> Wad {
        Wad { val: lhs.val - rhs.val }
    }
}

impl RaySub of Sub<Ray> {
    fn sub(lhs: Ray, rhs: Ray) -> Ray {
        Ray { val: lhs.val - rhs.val }
    }
}

// Multiplication
impl WadMul of Mul<Wad> {
    fn mul(lhs: Wad, rhs: Wad) -> Wad {
        wmul(lhs, rhs)
    }
}

impl RayMul of Mul<Ray> {
    fn mul(lhs: Ray, rhs: Ray) -> Ray {
        rmul(lhs, rhs)
    }
}

// Division
impl WadDiv of Div<Wad> {
    fn div(lhs: Wad, rhs: Wad) -> Wad {
        wdiv(lhs, rhs)
    }
}

impl RayDiv of Div<Ray> {
    fn div(lhs: Ray, rhs: Ray) -> Ray {
        rdiv(lhs, rhs)
    }
}

// Conversions
impl WadIntoRay of Into<Wad, Ray> {
    fn into(self: Wad) -> Ray {
        Ray { val: self.val * DIFF }
    }
}

impl RayIntoWad of Into<Ray, Wad> {
    fn into(self: Ray) -> Wad {
        // The value will get truncated if it has more than 18 decimals.
        Wad { val: self.val / DIFF }
    }
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

#[cfg(test)]
mod tests {
    use aura::utils::wadray::Ray;
    use aura::utils::wadray::RAY_ONE;
    use aura::utils::wadray::Wad;
    use aura::utils::wadray::WAD_ONE;


    #[test]
    fn add_test() {
        assert(Wad { val: 0 } + Wad { val: 0 } == Wad { val: 0 }, 'Incorrect addition #1');
        assert(Wad { val: 1 } + Wad { val: 1 } == Wad { val: 2 }, 'Incorrect addition #2');
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

        assert(Ray { val: 0 } + Ray { val: 0 } == Ray { val: 0 }, 'Incorrect addition #4');
        assert(Ray { val: 1 } + Ray { val: 1 } == Ray { val: 2 }, 'Incorrect addition #5');
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
    fn sub_test() {
        assert(Wad { val: 0 } - Wad { val: 0 } == Wad { val: 0 }, 'Incorrect subtraction #1');
        assert(Wad { val: 2 } - Wad { val: 1 } == Wad { val: 1 }, 'Incorrect subtraction #2');
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

        assert(Ray { val: 0 } - Ray { val: 0 } == Ray { val: 0 }, 'Incorrect subtraction #4');
        assert(Ray { val: 2 } - Ray { val: 1 } == Ray { val: 1 }, 'Incorrect subtraction #5');
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
    fn mul_test() {
        assert(
            Wad { val: 0_u128 } * Wad { val: 69_u128 } == Wad { val: 0_u128 },
            'Incorrect Multiplication # 1'
        );
        assert(
            Wad { val: 1_u128 } * Wad { val: 1_u128 } == Wad { val: 0_u128 },
            'Incorrect multiplication #2'
        ); // Result should be truncated
        assert(
            Wad {
                val: 121110987654321531059_u128
                } * Wad {
                val: 1234567891011125475893_u128
                } == Wad {
                val: 149519736606670187008926_u128
            },
            'Incorrect multiplication #3'
        );

        assert(
            Ray { val: 0_u128 } * Ray { val: 69_u128 } == Ray { val: 0_u128 },
            'Incorrect Multiplication # 4'
        );
        assert(
            Ray { val: 1_u128 } * Ray { val: 1_u128 } == Ray { val: 0_u128 },
            'Incorrect multiplication #5'
        ); // Result should be truncated
        assert(
            Ray {
                val: 121110987654321531059_u128
                } * Ray {
                val: 1234567891011125475893_u128
                } == Ray {
                val: 149519736606670_u128
            },
            'Incorrect multiplication #6'
        );
    }

    #[test]
    fn div_test() {
        assert(
            Wad { val: 2 * WAD_ONE } / Wad { val: WAD_ONE / 2 } == Wad { val: 4 * WAD_ONE },
            'Incorrect division #1'
        );

        assert(
            Ray { val: 2 * RAY_ONE } / Ray { val: RAY_ONE / 2 } == Ray { val: 4 * RAY_ONE },
            'Incorrect division #2'
        );
    }

    #[test]
    #[should_panic(expected: ('u256 is 0', ))]
    fn div_wad_fail_test() {
        let a: Wad = Wad { val: WAD_ONE } / Wad { val: 0 };
    }

    #[test]
    #[should_panic(expected: ('u256 is 0', ))]
    fn div_ray_fail_test() {
        let a: Ray = Ray { val: RAY_ONE } / Ray { val: 0 };
    }
}
