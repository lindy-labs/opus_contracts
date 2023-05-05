use traits::{Into, TryInto};

fn pow10(exp: u8) -> u128 {
    pow10_internal(exp.into())
}

fn pow10_internal(exp: u128) -> u128 {
    if exp == 0 {
        1
    } else {
        10 * pow10_internal(exp - 1)
    }
}

#[cfg(test)]
mod tests {
    use aura::utils::pow::pow10;

    #[test]
    #[available_gas(2000000)]
    fn test_pow10() {
        assert(pow10(0) == 1, 'Incorrect pow #1');
        assert(pow10(1) == 10, 'Incorrect pow #2');
        assert(pow10(2) == 100, 'Incorrect pow #3');
        assert(pow10(3) == 1000, 'Incorrect pow #4');
        assert(pow10(4) == 10000, 'Incorrect pow #5');
        assert(pow10(5) == 100000, 'Incorrect pow #6');
        assert(pow10(6) == 1000000, 'Incorrect pow #7');
        assert(pow10(7) == 10000000, 'Incorrect pow #8');
        assert(pow10(8) == 100000000, 'Incorrect pow #9');
        assert(pow10(9) == 1000000000, 'Incorrect pow #10');
        assert(pow10(10) == 10000000000, 'Incorrect pow #11');
    }
}
