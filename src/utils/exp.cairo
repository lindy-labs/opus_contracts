use option::OptionTrait;
use traits::Into;
use traits::TryInto;

use aura::utils::wadray::Wad;
use aura::utils::u256_conversions::U128IntoU256;
use aura::utils::u256_conversions::U256TryIntoU128;
//
// Constants
// 

const ONE_18: u128 = 1000000000000000000_u128;

// Higher precision numbers are used internally
const ONE_20: u128 = 100000000000000000000_u128;

// The domain of natural exponentiation is bound by the word size and number of decimals used.
//
// Because internally the result will be stored using 20 decimals, the largest possible result is
// (2^128 - 1) / 10^20, which makes the largest possible exponent ln((2^128 - 1) / 10^20) ~= 42.6711.
const MAX_NATURAL_EXPONENT: u128 = 42600000000000000000_u128;

// 18 decimal constants
const x0: u128 = 128000000000000000000_u128; // 2ˆ7
const a0: u128 =
    38877084059945950922200000000000000000000000000000000000_u128; // eˆ(x0) (no decimals)
const x1: u128 = 64000000000000000000_u128; // 2ˆ6
const a1: u128 = 6235149080811616882910000000_u128; // eˆ(x1) (no decimals)

// 20 decimal constants
const x2: u128 = 3200000000000000000000_u128; // 2ˆ5
const a2: u128 = 7896296018268069516100000000000000_u128; // eˆ(x2)
const x3: u128 = 1600000000000000000000_u128; // / 2ˆ4
const a3: u128 = 888611052050787263676000000_u128; // 00; // eˆ(x3)
const x4: u128 = 800000000000000000000_u128; // 2ˆ3
const a4: u128 = 298095798704172827474000_u128; // eˆ(x4)
const x5: u128 = 400000000000000000000_u128; // 2ˆ2
const a5: u128 = 5459815003314423907810_u128; // eˆ(x5)
const x6: u128 = 200000000000000000000_u128; // 2ˆ1
const a6: u128 = 738905609893065022723_u128; // eˆ(x6)
const x7: u128 = 100000000000000000000_u128; // 2ˆ0
const a7: u128 = 271828182845904523536_u128; // eˆ(x7)
const x8: u128 = 50000000000000000000_u128; // 2ˆ-1
const a8: u128 = 164872127070012814685_u128; // eˆ(x8)
const x9: u128 = 25000000000000000000_u128; // 2ˆ-2
const a9: u128 = 128402541668774148407_u128; // eˆ(x9)
const x10: u128 = 12500000000000000000_u128; // 2ˆ-3
const a10: u128 = 113314845306682631683_u128; // eˆ(x10)
const x11: u128 = 6250000000000000000_u128; // 2ˆ-4
const a11: u128 = 106449445891785942956_u128; // eˆ(x11)


// NOTE: this function currently only handles positive exponents, since it deals in uints. 
// TODO: 
// - once an int type is added, consider handling negative exponents too, although
//   it may not be necessary for our purposes.

fn exp(x: Wad) -> Wad {
    let mut x: u128 = x.val;

    assert(x <= MAX_NATURAL_EXPONENT, 'exp: x is out of bounds');

    let mut firstAN: u128 = 0;

    // First, we use the fact that e^(x+y) = e^x * e^y to decompose x into a sum of powers of two, which we call x_n,
    // where x_n == 2^(7 - n), and e^x_n = a_n has been precomputed. We choose the first x_n, x0, to equal 2^7
    // because all larger powers are larger than MAX_NATURAL_EXPONENT, and therefore not present in the
    // decomposition.
    // At the end of this process we will have the product of all e^x_n = a_n that apply, and the remainder of this
    // decomposition, which will be lower than the smallest x_n.
    // exp(x) = k_0 * a_0 * k_1 * a_1 * ... + k_n * a_n * exp(remainder), where each k_n equals either 0 or 1.
    // We mutate x by subtracting x_n, making it the remainder of the decomposition.

    // The first two a_n (e^(2^7) and e^(2^6)) are too large if stored as 18 decimal numbers, and could cause
    // intermediate overflows. Instead we store them as plain integers, with 0 decimals.
    // Additionally, x0 + x1 is larger than MAX_NATURAL_EXPONENT, which means they will not both be present in the
    // decomposition.

    // For each x_n, we test if that term is present in the decomposition (if x is larger than it), and if so deduct
    // it and compute the accumulated product.
    if (x >= x0) {
        x -= x0;
        firstAN = a0;
    } else if (x >= x1) {
        x -= x1;
        firstAN = a1;
    } else {
        firstAN = 1; // One with no decimal places
    }

    // We now transform x into a 20 decimal fixed point number, to have enhanced precision when computing the
    // smaller terms.
    x *= 100;

    // `product` is the accumulated product of all a_n (except a0 and a1), which starts at 20 decimal fixed point
    // one. Recall that fixed point multiplication requires dividing by ONE_20.
    let ONE_20_u256: u256 = ONE_20.into();

    let mut product: u256 = ONE_20_u256;

    if (x >= x2) {
        x -= x2;
        product = (product * a2.into()) / ONE_20_u256;
    }
    if (x >= x3) {
        x -= x3;
        product = (product * a3.into()) / ONE_20_u256;
    }
    if (x >= x4) {
        x -= x4;
        product = (product * a4.into()) / ONE_20_u256;
    }
    if (x >= x5) {
        x -= x5;
        product = (product * a5.into()) / ONE_20_u256;
    }
    if (x >= x6) {
        x -= x6;
        product = (product * a6.into()) / ONE_20_u256;
    }
    if (x >= x7) {
        x -= x7;
        product = (product * a7.into()) / ONE_20_u256;
    }
    if (x >= x8) {
        x -= x8;
        product = (product * a8.into()) / ONE_20_u256;
    }
    if (x >= x9) {
        x -= x9;
        product = (product * a9.into()) / ONE_20_u256;
    }

    // x10 and x11 are unnecessary here since we have high enough precision already.

    // Now we need to compute e^x, where x is small (in particular, it is smaller than x9). We use the Taylor series
    // expansion for e^x: 1 + x + (x^2 / 2!) + (x^3 / 3!) + ... + (x^n / n!).

    let mut series_sum: u256 = ONE_20_u256; // The initial one in the sum, with 20 decimal places.
    let x_u256: u256 = x.into();
    let mut term: u256 = x_u256; // Each term in the sum, where the nth term is (x^n / n!).

    // Each term (x^n / n!) equals the previous one times x, divided by n. Since x is a fixed point number,
    // multiplying by it requires dividing by ONE_20, but dividing by the non-fixed point n values does not.

    term = ((term * x_u256) / ONE_20_u256) / 2.into();
    series_sum += term;

    term = ((term * x_u256) / ONE_20_u256) / 3.into();
    series_sum += term;

    term = ((term * x_u256) / ONE_20_u256) / 4.into();
    series_sum += term;

    term = ((term * x_u256) / ONE_20_u256) / 5.into();
    series_sum += term;

    term = ((term * x_u256) / ONE_20_u256) / 6.into();
    series_sum += term;

    term = ((term * x_u256) / ONE_20_u256) / 7.into();
    series_sum += term;

    term = ((term * x_u256) / ONE_20_u256) / 8.into();
    series_sum += term;

    term = ((term * x_u256) / ONE_20_u256) / 9.into();
    series_sum += term;

    term = ((term * x_u256) / ONE_20_u256) / 10.into();
    series_sum += term;

    term = ((term * x_u256) / ONE_20_u256) / 11.into();
    series_sum += term;

    term = ((term * x_u256) / ONE_20_u256) / 12.into();
    series_sum += term;

    // 12 Taylor terms are sufficient for 18 decimal precision.

    // We now have the first a_n (with no decimals), and the product of all other a_n present, and the Taylor
    // approximation of the exponentiation of the remainder (both with 20 decimals). All that remains is to multiply
    // all three (one 20 decimal fixed point multiplication, dividing by ONE_20, and one integer multiplication),
    // and then drop two digits to return an 18 decimal value.

    let result: u256 = (((product * series_sum) / ONE_20_u256) * firstAN.into()) / 100.into();

    Wad { val: result.try_into().unwrap() }
}
