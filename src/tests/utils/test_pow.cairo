#[cfg(test)]
mod tests {
    use aura::utils::pow::pow10;

    #[test]
    #[available_gas(2000000)]
    fn test_pow10() {
        assert(pow10(0) == 1, 'Incorrect pow #1');
        assert(pow10(1) == 10, 'Incorrect pow #2');
        assert(pow10(2) == 100, 'Incorrect pow #3');
        assert(pow10(10) == 10000000000, 'Incorrect pow #4');
        assert(pow10(18) == 1000000000000000000, 'Incorrect pow #5');
        assert(pow10(27) == 1000000000000000000000000000, 'Incorrect pow #6');
    }
}
