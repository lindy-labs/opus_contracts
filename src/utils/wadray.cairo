use debug::PrintTrait;
use integer::{BoundedInt, BoundedU128, Felt252TryIntoU128, U128IntoFelt252};
use option::OptionTrait;
use starknet::StorageBaseAddress;
use traits::{Into, PartialEq, PartialOrd, TryInto};
use zeroable::Zeroable;

use aura::utils::pow::pow10;
use aura::utils::storage_access;
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

#[derive(Copy, Drop, Serde, storage_access::StorageAccess)]
struct Wad {
    val: u128, 
}

#[derive(Copy, Drop, Serde, storage_access::StorageAccess)]
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

impl WadIntoU256 of Into<Wad, u256> {
    #[inline(always)]
    fn into(self: Wad) -> u256 {
        self.val.into()
    }
}

impl U256TryIntoWad of TryInto<u256, Wad> {
    #[inline(always)]
    fn try_into(self: u256) -> Option<Wad> {
        match self.try_into() {
            Option::Some(val) => Option::Some(Wad { val }),
            Option::None(_) => Option::None(()),
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

// Debug print
impl WadPrintImpl of PrintTrait<Wad> {
    fn print(self: Wad) {
        self.val.print();
    }
}

impl RayPrintImpl of PrintTrait<Ray> {
    fn print(self: Ray) {
        self.val.print();
    }
}

//
// Other functions
//

fn fixed_point_to_wad(n: u128, decimals: u8) -> Wad {
    assert(decimals <= WAD_DECIMALS, 'More than 18 decimals');
    let scale: u128 = pow10(WAD_DECIMALS - decimals);
    (n * scale).into()
}
