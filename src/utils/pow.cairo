use traits::Into;

// TODO: Change to lookup table once `dw` is supported
fn pow10(exp: u8) -> u128 {
    if exp == 0 {
        1_u128
    } else {
        10 * pow10(exp - 1)
    }
}
