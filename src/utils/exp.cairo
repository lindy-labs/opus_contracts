use wadray::{WAD_ONE, Wad};

// PORTED FROM:
// https://github.com/balancer/balancer-v2-monorepo/blob/master/pkg/solidity-utils/contracts/math/LogExpMath.sol

//
// Constants
//

// Higher precision numbers are used internally
const ONE_20: u128 = 100000000000000000000;

// The domain of natural exponentiation is bound by the word size and number of decimals used.
//
// Because internally the result will be stored using 20 decimals, the largest possible result is
// (2^128 - 1) / 10^20, which makes the largest possible exponent ln((2^128 - 1) / 10^20) ~= 42.6711.
const MAX_NATURAL_EXPONENT: u128 = 42600000000000000000;

// 20 decimal constants
const x0: u128 = 3200000000000000000000; // 2ˆ5
const a0: u128 = 7896296018268069516100000000000000; // eˆ(x0)
const x1: u128 = 1600000000000000000000; // / 2ˆ4
const a1: u128 = 888611052050787263676000000; // 00; // eˆ(x1)
const x2: u128 = 800000000000000000000; // 2ˆ3
const a2: u128 = 298095798704172827474000; // eˆ(x2)
const x3: u128 = 400000000000000000000; // 2ˆ2
const a3: u128 = 5459815003314423907810; // eˆ(x3)
const x4: u128 = 200000000000000000000; // 2ˆ1
const a4: u128 = 738905609893065022723; // eˆ(x4)
const x5: u128 = 100000000000000000000; // 2ˆ0
const a5: u128 = 271828182845904523536; // eˆ(x5)
const x6: u128 = 50000000000000000000; // 2ˆ-1
const a6: u128 = 164872127070012814685; // eˆ(x6)
const x7: u128 = 25000000000000000000; // 2ˆ-2
const a7: u128 = 128402541668774148407; // eˆ(x7)
const x8: u128 = 12500000000000000000; // 2ˆ-3
const a8: u128 = 113314845306682631683; // eˆ(x8)
const x9: u128 = 6250000000000000000; // 2ˆ-4
const a9: u128 = 106449445891785942956; // eˆ(x9)


// NOTE: this function currently only handles positive exponents, since it deals in uints.
// TODO:
// - once an int type is added, consider handling negative exponents too, although
//   it may not be necessary for our purposes.

pub fn exp(x: Wad) -> Wad {
    let mut x: u128 = x.into();

    assert(x <= MAX_NATURAL_EXPONENT, 'exp: x is out of bounds');

    // First, we use the fact that e^(x+y) = e^x * e^y to decompose x into a sum of powers of two, which we call x_n,
    // where x_n == 2^(5 - n), and e^x_n = a_n has been precomputed. We choose the first x_n, x0, to equal 2^5
    // because all larger powers are larger than MAX_NATURAL_EXPONENT, and therefore not present in the
    // decomposition.
    // At the end of this process we will have the product of all e^x_n = a_n that apply, and the remainder of this
    // decomposition, which will be lower than the smallest x_n.
    // exp(x) = k_0 * a_0 * k_1 * a_1 * ... + k_n * a_n * exp(remainder), where each k_n equals either 0 or 1.
    // We mutate x by subtracting x_n, making it the remainder of the decomposition.

    let firstAN: u256 = 1; // One with no decimal places

    // We now transform x into a 20 decimal fixed point number, to have enhanced precision when computing the
    // smaller terms.
    x *= 100;

    // `product` is the accumulated product of all a_n, which starts at 20 decimal fixed point
    // one. Recall that fixed point multiplication requires dividing by ONE_20.
    let ONE_20: u256 = ONE_20.into();

    let mut product: u256 = ONE_20;

    if (x >= x0) {
        x -= x0;
        product = (product * a0.into()) / ONE_20;
    }
    if (x >= x1) {
        x -= x1;
        product = (product * a1.into()) / ONE_20;
    }
    if (x >= x2) {
        x -= x2;
        product = (product * a2.into()) / ONE_20;
    }
    if (x >= x3) {
        x -= x3;
        product = (product * a3.into()) / ONE_20;
    }
    if (x >= x4) {
        x -= x4;
        product = (product * a4.into()) / ONE_20;
    }
    if (x >= x5) {
        x -= x5;
        product = (product * a5.into()) / ONE_20;
    }
    if (x >= x6) {
        x -= x6;
        product = (product * a6.into()) / ONE_20;
    }
    if (x >= x7) {
        x -= x7;
        product = (product * a7.into()) / ONE_20;
    }

    // x8 and x9 are unnecessary here since we have high enough precision already.

    // Now we need to compute e^x, where x is small (in particular, it is smaller than x7). We use the Taylor series
    // expansion for e^x: 1 + x + (x^2 / 2!) + (x^3 / 3!) + ... + (x^n / n!).

    let mut series_sum: u256 = ONE_20; // The initial one in the sum, with 20 decimal places.
    let x: u256 = x.into();
    let mut term: u256 = x; // Each term in the sum, where the nth term is (x^n / n!).
    series_sum += term;

    // Each term (x^n / n!) equals the previous one times x, divided by n. Since x is a fixed point number,
    // multiplying by it requires dividing by ONE_20, but dividing by the non-fixed point n values does not.

    term = term * x / 200000000000000000000_u256;
    series_sum += term;

    term = term * x / 300000000000000000000_u256;
    series_sum += term;

    term = term * x / 400000000000000000000_u256;
    series_sum += term;

    term = term * x / 500000000000000000000_u256;
    series_sum += term;

    term = term * x / 600000000000000000000_u256;
    series_sum += term;

    term = term * x / 700000000000000000000_u256;
    series_sum += term;

    term = term * x / 800000000000000000000_u256;
    series_sum += term;

    term = term * x / 900000000000000000000_u256;
    series_sum += term;

    term = term * x / 1000000000000000000000_u256;
    series_sum += term;

    term = term * x / 1100000000000000000000_u256;
    series_sum += term;

    term = term * x / 1200000000000000000000_u256;
    series_sum += term;

    // 12 Taylor terms are sufficient for 18 decimal precision.

    // We now have the first a_n (with no decimals), and the product of all other a_n present, and the Taylor
    // approximation of the exponentiation of the remainder (both with 20 decimals). All that remains is to multiply
    // all three (one 20 decimal fixed point multiplication, dividing by ONE_20, and one integer multiplication),
    // and then drop two digits to return an 18 decimal value.

    let result: u256 = (((product * series_sum) / ONE_20) * firstAN) / 100.into();
    result.try_into().unwrap()
}

// Computes 1/exp(x) = exp(-x)
pub fn neg_exp(x: Wad) -> Wad {
    WAD_ONE.into() / exp(x)
}
