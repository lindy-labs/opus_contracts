use core::integer::{u256_sqrt, u256_wide_mul, u512, u512_safe_div_rem_by_u256};
use core::num::traits::One;
use core::traits::DivRem;
use wadray::{Ray, u128_rdiv, u128_rmul, Wad, WAD_DECIMALS, WAD_SCALE};


const TWO_POW_128: u256 = 0x100000000000000000000000000000000;

pub fn sqrt(x: Ray) -> Ray {
    let scaled_val: u256 = x.val.into() * wadray::RAY_SCALE.into();
    u256_sqrt(scaled_val).into()
}

pub fn pow<T, impl TMul: Mul<T>, impl TOne: One<T>, impl TDrop: Drop<T>, impl TCopy: Copy<T>>(x: T, mut n: u8) -> T {
    if n == 0 {
        TOne::one()
    } else if n == 1 {
        x
    } else if n % 2 == 0 {
        pow(x * x, n / 2)
    } else {
        x * pow(x * x, (n - 1) / 2)
    }
}

pub fn fixed_point_to_wad(n: u128, decimals: u8) -> Wad {
    assert(decimals <= WAD_DECIMALS, 'More than 18 decimals');
    let scale: u128 = pow(10_u128, WAD_DECIMALS - decimals);
    (n * scale).into()
}

pub fn wad_to_fixed_point(n: Wad, decimals: u8) -> u128 {
    assert(decimals <= WAD_DECIMALS, 'More than 18 decimals');
    let scale: u128 = pow(10_u128, WAD_DECIMALS - decimals);
    n.val / scale
}

#[inline(always)]
pub fn scale_u128_by_ray(lhs: u128, rhs: Ray) -> u128 {
    u128_rmul(lhs, rhs.val)
}

#[inline(always)]
pub fn div_u128_by_ray(lhs: u128, rhs: Ray) -> u128 {
    u128_rdiv(lhs, rhs.val)
}

// See https://docs.ekubo.org/integration-guides/reference/reading-pool-price
// for conversion of x128 values from the Ekubo Core. However, take note that 
// Ekubo oracle extension already gives the squared price.
pub fn convert_ekubo_oracle_price_to_wad(n: u256, base_decimals: u8, quote_decimals: u8) -> Wad {
    // Adjust the scale based on the difference in precision between the base asset 
    // and the quote asset
    let adjusted_scale: u256 = if quote_decimals <= base_decimals {
        WAD_SCALE.into() * pow(10_u256, (base_decimals - quote_decimals).into())
    } else {
        WAD_SCALE.into() / pow(10_u256, (quote_decimals - base_decimals).into())
    };

    let val = n * adjusted_scale / TWO_POW_128;
    val.try_into().unwrap()
}


pub fn median_of_three<T, impl TPartialOrd: PartialOrd<T>, impl TDrop: Drop<T>, impl TCopy: Copy<T>>(
    values: Span<T>
) -> T {
    let a = *values[0];
    let b = *values[1];
    let c = *values[2];

    if (a <= b && b <= c) || (c <= b && b <= a) {
        b
    } else if (b <= a && a <= c) || (c <= a && a <= b) {
        a
    } else {
        c
    }
}
