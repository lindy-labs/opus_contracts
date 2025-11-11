use core::num::traits::Pow;
use wadray::{Ray, WAD_DECIMALS, WAD_SCALE, Wad, u128_rdiv, u128_rmul};


const TWO_POW_128: u256 = 0x100000000000000000000000000000000;


pub fn fixed_point_to_wad(n: u128, decimals: u8) -> Wad {
    assert(decimals <= WAD_DECIMALS, 'More than 18 decimals');
    let scale: u128 = 10_u128.pow((WAD_DECIMALS - decimals).into());
    (n * scale).into()
}

pub fn wad_to_fixed_point(n: Wad, decimals: u8) -> u128 {
    assert(decimals <= WAD_DECIMALS, 'More than 18 decimals');
    let scale: u128 = 10_u128.pow((WAD_DECIMALS - decimals).into());
    n.into() / scale
}

#[inline(always)]
pub fn scale_u128_by_ray(lhs: u128, rhs: Ray) -> u128 {
    u128_rmul(lhs, rhs.into())
}

#[inline(always)]
pub fn div_u128_by_ray(lhs: u128, rhs: Ray) -> u128 {
    u128_rdiv(lhs, rhs.into())
}

// See https://docs.ekubo.org/integration-guides/reference/reading-pool-price
// for conversion of x128 values from the Ekubo Core. However, take note that
// Ekubo oracle extension already gives the squared price.
pub fn convert_ekubo_oracle_price_to_wad(n: u256, base_decimals: u8, quote_decimals: u8) -> Wad {
    // Adjust the scale based on the difference in precision between the base asset
    // and the quote asset
    let adjusted_scale: u256 = if quote_decimals <= base_decimals {
        WAD_SCALE.into() * 10_u256.pow((base_decimals - quote_decimals).into())
    } else {
        WAD_SCALE.into() / 10_u256.pow((quote_decimals - base_decimals).into())
    };

    let val = n * adjusted_scale / TWO_POW_128;
    val.try_into().unwrap()
}


pub fn median_of_three<T, impl TPartialOrd: PartialOrd<T>, impl TDrop: Drop<T>, impl TCopy: Copy<T>>(
    values: Span<T>,
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
