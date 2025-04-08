mod test_math {
    use core::num::traits::{Bounded, Zero};
    use opus::tests::common::assert_equalish;
    use opus::utils::math::{convert_ekubo_oracle_price_to_wad, median_of_three, pow, sqrt};
    use wadray::{Ray, RAY_ONE, Wad};

    #[test]
    fn test_sqrt() {
        let ERROR_MARGIN: Ray = 1_u128.into();

        assert(sqrt(0_u128.into()) == Zero::zero(), 'wrong sqrt #1');

        // Ground truth tests

        // 1000
        assert_equalish(
            sqrt(1000000000000000000000000000000_u128.into()),
            31622776601683793319988935444_u128.into(),
            ERROR_MARGIN,
            'wrong sqrt #2'
        );

        // 6969
        assert_equalish(
            sqrt(6969000000000000000000000000000_u128.into()),
            83480536653761396384637711221_u128.into(),
            ERROR_MARGIN,
            'wrong sqrt #3'
        );

        // pi
        assert_equalish(
            sqrt(3141592653589793238462643383_u128.into()),
            1772453850905516027298167483_u128.into(),
            ERROR_MARGIN,
            'wrong sqrt #4'
        );

        // e
        assert_equalish(
            sqrt(2718281828459045235360287471_u128.into()),
            1648721270700128146848650787_u128.into(),
            ERROR_MARGIN,
            'wrong sqrt #5'
        );

        // Testing the property x = sqrt(x)^2

        let ERROR_MARGIN = 1000_u128.into();

        assert_equalish((4 * RAY_ONE).into(), pow(sqrt((4 * RAY_ONE).into()), 2), ERROR_MARGIN, 'wrong sqrt #6');

        assert_equalish((1000 * RAY_ONE).into(), pow(sqrt((1000 * RAY_ONE).into()), 2), ERROR_MARGIN, 'wrong sqrt #7');

        // tau
        assert_equalish(
            6283185307179586476925286766_u128.into(),
            pow(sqrt(6283185307179586476925286766_u128.into()), 2),
            ERROR_MARGIN,
            'wrong sqrt #8'
        );

        // testing the maximum possible value `sqrt` could accept doesn't cause it to fail
        sqrt(Bounded::MAX);
    }

    #[test]
    fn test_pow() {
        // u128 tests
        assert(pow(5_u128, 3) == 125_u128, 'wrong pow #1');
        assert(pow(5_u128, 0) == 1_u128, 'wrong pow #2');
        assert(pow(5_u128, 1) == 5_u128, 'wrong pow #3');
        assert(pow(5_u128, 2) == 25_u128, 'wrong pow #4');

        // Ray tests
        let ERROR_MARGIN = 1000_u128.into();

        assert_equalish(
            pow::<Ray>(3141592653589793238462643383_u128.into(), 2),
            9869604401089358618834490999_u128.into(),
            ERROR_MARGIN,
            'wrong pow #5'
        );

        assert_equalish(
            pow::<Ray>(1414213562373095048801688724_u128.into(), 4), (4 * RAY_ONE).into(), ERROR_MARGIN, 'wrong pow #6'
        );
    }

    #[test]
    fn test_convert_ekubo_oracle_price_to_wad() {
        let error_margin: Wad = 200_u128.into();

        // First segment: base asset decimals (18) >= quote asset decimals

        // 18 decimals
        let x128_val: u256 = 340351451218700252552422283729072753607;
        let actual: Wad = convert_ekubo_oracle_price_to_wad(x128_val, 18, 18);
        let expected: Wad = 1000203020504373800_u128.into();
        assert_equalish(actual, expected, error_margin, 'wrong x128 -> wad #1');

        let x128_val: u256 = 339351451218700252552422283729072753607;
        let actual: Wad = convert_ekubo_oracle_price_to_wad(x128_val, 18, 18);
        let expected: Wad = 997264284627318000_u128.into();
        assert_equalish(actual, expected, error_margin, 'wrong x128 -> wad #2');

        // 6 decimals
        let x128_val: u256 = 340245254854570020996364378;
        let actual: Wad = convert_ekubo_oracle_price_to_wad(x128_val, 18, 6);
        let expected: Wad = 999890937439091300_u128.into();
        assert_equalish(actual, expected, error_margin, 'wrong x128 -> wad #3');

        let x128_val: u256 = 341245254854570020996364378;
        let actual: Wad = convert_ekubo_oracle_price_to_wad(x128_val, 18, 6);
        let expected: Wad = 1002829673316147100_u128.into();
        assert_equalish(actual, expected, error_margin, 'wrong x128 -> wad #4');

        // Second segment: base asset decimals < quote asset decimals (18)

        // 6 decimals
        let x128_val: u256 = 88397018286004152788406389410990271944458724276;
        let actual = convert_ekubo_oracle_price_to_wad(x128_val, 6, 18);
        let expected: Wad = 259775489061830_u128.into(); // USDC/ETH price: 0.00025...
        assert_equalish(actual, expected, error_margin, 'wrong x128 -> wad #5');

        // 8 decimals
        let x128_val: u256 = 91518349125612368443571711893252661971104731310540;
        let actual = convert_ekubo_oracle_price_to_wad(x128_val, 8, 18);
        let expected: Wad = 26894825598434793657_u128.into(); // WBTC/ETH price: 26.89...
        assert_equalish(actual, expected, error_margin, 'wrong x128 -> wad #6');

        // 18 decimals
        let x128_val: u256 = 50675139689807561015903026885413648;
        let actual = convert_ekubo_oracle_price_to_wad(x128_val, 18, 18);
        let expected: Wad = 148920851081247_u128.into(); // STRK/ETH price: 0.00014...
        assert_equalish(actual, expected, error_margin, 'wrong x128 -> wad #7');
    }

    #[test]
    fn test_median_of_three() {
        let values: Span<u128> = array![1, 2, 3].span();
        assert_eq!(median_of_three(values), 2, "wrong median #1");

        let values: Span<u128> = array![2, 2, 3].span();
        assert_eq!(median_of_three(values), 2, "wrong median #1");

        let values: Span<u128> = array![2, 2, 2].span();
        assert_eq!(median_of_three(values), 2, "wrong median #1");
    }
}
