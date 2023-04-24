use aura::utils::gas_checks::check_gas;

// TODO: workaround until `dw` is available
fn pow10(exp: u8) -> u128 {
    // TODO: Remove once automatically handled by compiler
    check_gas();

    if exp == 0 {
        1
    } else {
        10 * pow10(exp - 1)
    }
}
