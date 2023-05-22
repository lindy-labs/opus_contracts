#[cfg(test)]
mod tests {
    use option::OptionTrait;
    use traits::Into;
    use traits::TryInto;
    use zeroable::Zeroable;

    use aura::utils::wadray;
    use aura::utils::wadray::{
        DIFF, fixed_point_to_wad, MAX_CONVERTIBLE_WAD, Ray, RAY_ONE, rdiv_wr, rmul_rw, rmul_wr, Wad,
        WAD_ONE, WAD_DECIMALS, WAD_SCALE, wdiv_rw, wmul_rw, wmul_wr
    };


    #[test]
    fn test_add() {
        // 0 + 0 = 0
        assert(Wad { val: 0 } + Wad { val: 0 } == Wad { val: 0 }, 'Incorrect addition #1');

        // 1 + 1 = 2
        assert(Wad { val: 1 } + Wad { val: 1 } == Wad { val: 2 }, 'Incorrect addition #2');

        // 123456789101112 + 121110987654321 = 244567776755433
        assert(
            Wad {
                val: 123456789101112
                } + Wad {
                val: 121110987654321
                } == Wad {
                val: 244567776755433
            },
            'Incorrect addition #3'
        );

        // 0 + 0 = 0
        assert(Ray { val: 0 } + Ray { val: 0 } == Ray { val: 0 }, 'Incorrect addition #4');

        // 1 + 1 = 2
        assert(Ray { val: 1 } + Ray { val: 1 } == Ray { val: 2 }, 'Incorrect addition #5');

        // 123456789101112 + 121110987654321 = 244567776755433
        assert(
            Ray {
                val: 123456789101112
                } + Ray {
                val: 121110987654321
                } == Ray {
                val: 244567776755433
            },
            'Incorrect addition #6'
        );
    }

    #[test]
    fn test_add_eq() {
        let mut a1 = Wad { val: 5 };
        let a2 = Wad { val: 5 };
        let b = Wad { val: 3 };

        a1 += b;
        assert(a1 == a2 + b, 'Incorrect AddEq #1');
    }


    #[test]
    fn test_sub() {
        // 0 - 0 = 0
        assert(Wad { val: 0 } - Wad { val: 0 } == Wad { val: 0 }, 'Incorrect subtraction #1');

        // 2 - 1 = 1
        assert(Wad { val: 2 } - Wad { val: 1 } == Wad { val: 1 }, 'Incorrect subtraction #2');

        // 244567776755433 - 121110987654321 = 123456789101112
        assert(
            Wad {
                val: 244567776755433
                } - Wad {
                val: 121110987654321
                } == Wad {
                val: 123456789101112
            },
            'Incorrect subtraction #3'
        );

        // 0 - 0 = 0
        assert(Ray { val: 0 } - Ray { val: 0 } == Ray { val: 0 }, 'Incorrect subtraction #4');

        // 2 - 1 = 1
        assert(Ray { val: 2 } - Ray { val: 1 } == Ray { val: 1 }, 'Incorrect subtraction #5');

        // 244567776755433 - 121110987654321 = 123456789101112
        assert(
            Ray {
                val: 244567776755433
                } - Ray {
                val: 121110987654321
                } == Ray {
                val: 123456789101112
            },
            'Incorrect subtraction #6'
        );
    }

    #[test]
    fn test_sub_eq() {
        let mut a1 = Wad { val: 5 };
        let a2 = Wad { val: 5 };
        let b = Wad { val: 3 };

        a1 -= b;
        assert(a1 == a2 - b, 'Incorrect SubEq #1');
    }


    #[test]
    fn test_mul() {
        // 0 * 69 = 0
        assert(Wad { val: 0 } * Wad { val: 69 } == Wad { val: 0 }, 'Incorrect Multiplication # 1');

        // 1 * 1 = 0 (truncated)
        assert(
            Wad { val: 1 } * Wad { val: 1 } == Wad { val: 0 }, 'Incorrect multiplication #2'
        ); // Result should be truncated

        // 1 (wad) * 1 (wad) = 1 (wad)
        assert(
            Wad { val: WAD_ONE } * Wad { val: WAD_ONE } == Wad { val: WAD_ONE },
            'Incorrect multiplication #3'
        );

        // 121110987654321531059 * 1234567891011125475893 = 149519736606670187008926
        assert(
            Wad {
                val: 121110987654321531059
                } * Wad {
                val: 1234567891011125475893
                } == Wad {
                val: 149519736606670187008926
            },
            'Incorrect multiplication #4'
        );

        // 0 * 69 = 0
        assert(Ray { val: 0 } * Ray { val: 69 } == Ray { val: 0 }, 'Incorrect Multiplication #5');

        // 1 * 1 = 0 (truncated)
        assert(
            Ray { val: 1 } * Ray { val: 1 } == Ray { val: 0 }, 'Incorrect multiplication #6'
        ); // Result should be truncated

        // 1 (ray) * 1 (ray) = 1 (ray)
        assert(
            Ray { val: RAY_ONE } * Ray { val: RAY_ONE } == Ray { val: RAY_ONE },
            'Incorrect multiplication #7'
        );

        // 121110987654321531059 * 1234567891011125475893 = 149519736606670 (truncated)
        assert(
            Ray {
                val: 121110987654321531059
                } * Ray {
                val: 1234567891011125475893
                } == Ray {
                val: 149519736606670
            },
            'Incorrect multiplication #8'
        );

        // wmul(ray, wad) -> ray
        assert(
            wmul_rw(Ray { val: RAY_ONE }, Wad { val: WAD_ONE }) == Ray { val: RAY_ONE },
            'Incorrect multiplication #9'
        );

        // wmul(wad, ray) -> ray
        assert(
            wmul_wr(Wad { val: WAD_ONE }, Ray { val: RAY_ONE }) == Ray { val: RAY_ONE },
            'Incorrect multiplication #10'
        );

        // rmul(ray, wad) -> wad
        assert(
            rmul_rw(Ray { val: RAY_ONE }, Wad { val: WAD_ONE }) == Wad { val: WAD_ONE },
            'Incorrect multiplication #11'
        );

        // rmul(wad, ray) -> wad
        assert(
            rmul_wr(Wad { val: WAD_ONE }, Ray { val: RAY_ONE }) == Wad { val: WAD_ONE },
            'Incorrect multiplication #12'
        );
    }

    #[test]
    fn test_mul_eq() {
        let mut a1 = Wad { val: 5 };
        let a2 = Wad { val: 5 };
        let b = Wad { val: 3 };

        a1 *= b;
        assert(a1 == a2 * b, 'Incorrect MulEq #1');
    }


    #[test]
    fn test_div() {
        // 2 / (1 / 2) = 4 (wad)
        assert(
            Wad { val: 2 * WAD_ONE } / Wad { val: WAD_ONE / 2 } == Wad { val: 4 * WAD_ONE },
            'Incorrect division #1'
        );

        // 2 / (1 / 2) = 4 (ray)
        assert(
            Ray { val: 2 * RAY_ONE } / Ray { val: RAY_ONE / 2 } == Ray { val: 4 * RAY_ONE },
            'Incorrect division #2'
        );

        // wdiv(ray, wad) -> ray
        assert(
            wdiv_rw(Ray { val: RAY_ONE }, Wad { val: WAD_ONE }) == Ray { val: RAY_ONE },
            'Incorrect division #3'
        );

        // rdiv(wad, ray) -> wad
        assert(
            rdiv_wr(Wad { val: WAD_ONE }, Ray { val: RAY_ONE }) == Wad { val: WAD_ONE },
            'Incorrect division #4'
        );
    }

    #[test]
    fn test_div_eq() {
        let mut a1 = Wad { val: 15 };
        let a2 = Wad { val: 15 };
        let b = Wad { val: 3 };

        a1 /= b;
        assert(a1 == a2 / b, 'Incorrect DivEq #1');
    }


    #[test]
    #[should_panic(expected: ('u256 is 0', ))]
    fn test_div_wad_fail() {
        let a: Wad = Wad { val: WAD_ONE } / Wad { val: 0 };
    }

    #[test]
    #[should_panic(expected: ('u256 is 0', ))]
    fn test_div_ray_fail() {
        let a: Ray = Ray { val: RAY_ONE } / Ray { val: 0 };
    }

    #[test]
    fn test_conversions() {
        // Test conversion from Wad to Ray
        let a: Ray = Wad { val: WAD_ONE }.try_into().unwrap();
        assert(a.val == RAY_ONE, 'Incorrect wad->ray conversion');

        let a: Ray = Wad { val: MAX_CONVERTIBLE_WAD }.try_into().unwrap();
        assert(a.val == MAX_CONVERTIBLE_WAD * DIFF, 'Incorrect wad->ray conversion');

        let a: Option::<Ray> = Wad { val: MAX_CONVERTIBLE_WAD + 1 }.try_into();
        assert(a.is_none(), 'Incorrect wad->ray conversion');

        // Test conversion from Ray to Wad
        let a: Wad = Ray { val: RAY_ONE }.into();
        assert(a.val == WAD_ONE, 'Incorrect ray->wad conversion');
    }

    #[test]
    fn test_u128_into_wadray() {
        // Test U128IntoWad
        let wad_value: u128 = 42;
        let wad_result: Wad = wad_value.into();
        assert(wad_result.val == wad_value, 'Incorrect u128->Wad conversion');

        // Test U128IntoRay
        let ray_value: u128 = 84;
        let ray_result: Ray = ray_value.into();
        assert(ray_result.val == ray_value, 'Incorrect u128->Ray conversion');
    }

    #[test]
    #[should_panic(expected: ('Option::unwrap failed.', ))]
    fn test_conversions_fail2() {
        let a: Ray = Wad { val: MAX_CONVERTIBLE_WAD + 1 }.try_into().unwrap();
    }

    // comparison tests are split into 2 fns to overcome a test runner bug
    #[test]
    fn test_comparisons1() {
        // Test Wad type comparison operators: <, >, <=, >=
        assert(Wad { val: WAD_ONE } < Wad { val: WAD_ONE + 1 }, 'Incorrect < comparison #1');
        assert(Wad { val: WAD_ONE + 1 } > Wad { val: WAD_ONE }, 'Incorrect > comparison #2');
        assert(Wad { val: WAD_ONE } <= Wad { val: WAD_ONE }, 'Incorrect <= comparison #3');
        assert(Wad { val: WAD_ONE + 1 } >= Wad { val: WAD_ONE + 1 }, 'Incorrect >= comparison #4');

        // Test Ray type comparison operators: <, >, <=, >=
        assert(Ray { val: RAY_ONE } < Ray { val: RAY_ONE + 1 }, 'Incorrect < comparison #5');
        assert(Ray { val: RAY_ONE + 1 } > Ray { val: RAY_ONE }, 'Incorrect > comparison #6');
        assert(Ray { val: RAY_ONE } <= Ray { val: RAY_ONE }, 'Incorrect <= comparison #7');
        assert(Ray { val: RAY_ONE + 1 } >= Ray { val: RAY_ONE + 1 }, 'Incorrect >= comparison #8');

        // Test Ray type opposite comparisons: !(<), !(>), !(<=), !(>=)
        assert(!(Ray { val: RAY_ONE } < Ray { val: RAY_ONE }), 'Incorrect < comparison #9');
        assert(!(Ray { val: RAY_ONE } > Ray { val: RAY_ONE }), 'Incorrect > comparison #10');
        assert(!(Ray { val: RAY_ONE + 1 } <= Ray { val: RAY_ONE }), 'Incorrect <= comparison #11');
        assert(!(Ray { val: RAY_ONE } >= Ray { val: RAY_ONE + 1 }), 'Incorrect >= comparison #12');

        // Test Wad type opposite comparisons: !(<), !(>), !(<=), !(>=)
        assert(!(Wad { val: WAD_ONE } < Wad { val: WAD_ONE }), 'Incorrect < comparison #13');
        assert(!(Wad { val: WAD_ONE } > Wad { val: WAD_ONE }), 'Incorrect > comparison #14');
        assert(!(Wad { val: WAD_ONE + 1 } <= Wad { val: WAD_ONE }), 'Incorrect <= comparison #15');
        assert(!(Wad { val: WAD_ONE } >= Wad { val: WAD_ONE + 1 }), 'Incorrect >= comparison #16');
    }

    #[test]
    fn test_comparisons2() {
        // Test Wad type != operator
        assert(Wad { val: WAD_ONE } != Wad { val: WAD_ONE + 1 }, 'Incorrect != comparison #17');
        assert(!(Wad { val: WAD_ONE } != Wad { val: WAD_ONE }), 'Incorrect != comparison #18');

        // Test Ray type != operator
        assert(Ray { val: RAY_ONE } != Ray { val: RAY_ONE + 1 }, 'Incorrect != comparison #19');
        assert(!(Ray { val: RAY_ONE } != Ray { val: RAY_ONE }), 'Incorrect != comparison #20');
    }

    #[test]
    fn test_zeroable() {
        // Test zero
        let wad_zero = Wad { val: 0 };
        assert(wad_zero.val == 0, 'Value should be 0 #1');

        // Test is_zero
        let wad_one = Wad { val: 1 };
        assert(wad_zero.is_zero(), 'Value should be 0 #2');
        assert(!wad_one.is_zero(), 'Value should not be 0 #3');

        // Test is_non_zero
        assert(!wad_zero.is_non_zero(), 'Value should be 0 #4');
        assert(wad_one.is_non_zero(), 'Value should not be 0 #5');

        let ray_zero = Ray { val: 0 };
        assert(ray_zero.val == 0, 'Value should be 0 #6');

        // Test is_zero
        let ray_one = Ray { val: 1 };
        assert(ray_zero.is_zero(), 'Value should be 0 #7');
        assert(!ray_one.is_zero(), 'Value should not be 0 #8');

        // Test is_non_zero
        assert(!ray_zero.is_non_zero(), 'Value should be 0 #9');
        assert(ray_one.is_non_zero(), 'Value should not be 0 #10');
    }

    #[test]
    #[available_gas(2000000)]
    fn test_fixed_point_to_wad_zero() {
        // Test zero amount with varying decimals
        assert(fixed_point_to_wad(0, 0) == 0_u128.into(), 'Incorrect fp>wad conversion #1');
        assert(fixed_point_to_wad(0, 6) == 0_u128.into(), 'Incorrect fp>wad conversion #2');
        assert(fixed_point_to_wad(0, 18) == 0_u128.into(), 'Incorrect fp>wad conversion #3');
    }

    #[test]
    #[available_gas(2000000)]
    fn test_fixed_point_to_wad_non_zero() {
        // Test non-zero amount with varying decimals
        assert(fixed_point_to_wad(1, 0) == WAD_SCALE.into(), 'Incorrect fp>wad conversion #4');
        assert(
            fixed_point_to_wad(1, 6) == 1000000000000_u128.into(), 'Incorrect fp>wad conversion #5'
        );
        assert(fixed_point_to_wad(1, 18) == 1_u128.into(), 'Incorrect fp>wad conversion #6');
    }

    #[test]
    #[should_panic(expected: ('More than 18 decimals', ))]
    fn test_fixed_point_to_wad_fail() {
        let x: Wad = fixed_point_to_wad(1, WAD_DECIMALS + 1);
    }
}
