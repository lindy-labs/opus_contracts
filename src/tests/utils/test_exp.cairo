mod test_exp {
    use core::num::traits::Zero;
    use opus::tests::common::assert_equalish;
    use opus::utils::exp::exp;
    use wadray::{WAD_ONE, WAD_PERCENT, Wad};


    // Acceptable error for e^x where x <= 20. Corresponds to 0.000000000001 (10^-12) precision
    const ACCEPTABLE_ERROR: u128 = 1000000;

    #[test]
    fn test_exp_basic() {
        // Basic tests
        assert(exp(Zero::zero()) == WAD_ONE.into(), 'Incorrect e^0 result');
        assert(exp(WAD_ONE.into()) == 2718281828459045235_u128.into(), 'Incorrect e^1 result');

        let res = exp((WAD_PERCENT * 2).into());
        assert_equalish(
            res, 1020201340026755810_u128.into(), ACCEPTABLE_ERROR.into(), 'exp-test: error exceeds bounds',
        );

        let res = exp((WAD_ONE * 10).into());
        assert_equalish(
            res, 22026465794806716516957_u128.into(), ACCEPTABLE_ERROR.into(), 'exp-test: error exceeds bounds',
        );

        let res = exp((WAD_ONE * 20).into());
        assert_equalish(
            res, 485165195409790277969106830_u128.into(), ACCEPTABLE_ERROR.into(), 'exp-test: error exceeds bounds',
        );

        // Highest possible value the function will accept
        exp(42600000000000000000_u128.into());
    }

    #[test]
    fn test_exp_add() {
        // Exponent law: e^x * e^y = e^(x + y)
        let a: Wad = exp(WAD_ONE.into());
        let a: Wad = a * a;

        let b: Wad = exp((2 * WAD_ONE).into());

        //e^1 * e^1 = e^2
        assert_equalish(a, b, ACCEPTABLE_ERROR.into(), 'exp-test: error exceeds bounds');
    }

    #[test]
    fn test_exp_sub() {
        //Exponent law: e^x / e^y = e^(x - y)
        let a: Wad = exp((8 * WAD_ONE).into());
        let b: Wad = exp((3 * WAD_ONE).into());
        let c: Wad = exp((5 * WAD_ONE).into());

        assert_equalish(a / b, c, ACCEPTABLE_ERROR.into(), 'exp-test: error exceeds bounds');
    }


    #[test]
    #[should_panic(expected: 'exp: x is out of bounds')]
    fn test_exp_fail() {
        let _ = exp(42600000000000000001_u128.into());
    }
}
