mod test_wadray_signed {
    use debug::PrintTrait;
    use math::Oneable;

    use opus::utils::wadray_signed;
    use opus::utils::wadray_signed::{
        I128TryIntoU128, SignedRay, SignedRayOneable, SignedRayZeroable, SignedWad,
        SignedWadOneable, SignedWadZeroable, U128TryIntoI128,
    };
    use opus::utils::wadray;
    use opus::utils::wadray::{Ray, Wad};


    #[test]
    fn test_add_sub() {
        let a = SignedWad { val: 100 };
        let b = SignedWad { val: -100 };
        let c = SignedWad { val: -40 };

        assert(a + b == SignedWadZeroable::zero(), 'a + b != 0');
        assert(a - b == SignedWad { val: 200 }, 'a - b != 200');
        assert(b - a == SignedWad { val: -200 }, 'b - a != -200');
        assert(a + c == SignedWad { val: 60 }, 'a + c != 60');
        assert(a - c == SignedWad { val: 140 }, 'a - c != 140');

        let a = SignedRay { val: 100 };
        let b = SignedRay { val: -100 };
        let c = SignedRay { val: -40 };

        assert(a + b == SignedRayZeroable::zero(), 'a + b != 0');
        assert(a - b == SignedRay { val: 200 }, 'a - b != 200');
        assert(b - a == SignedRay { val: -200 }, 'b - a != -200');
        assert(a + c == SignedRay { val: 60 }, 'a + c != 60');
        assert(a - c == SignedRay { val: 140 }, 'a - c != 140');
    }

    #[test]
    fn test_mul_div() {
        let a = SignedWad { val: wadray_signed::WAD_ONE }; // 1.0 ray
        let b = SignedWad { val: -(2 * wadray_signed::WAD_ONE) }; // -2.0 ray
        let c = SignedWad { val: 5 * wadray_signed::WAD_ONE }; // 5.0 ray
        let d = SignedWad { val: -wadray_signed::WAD_ONE }; // -1.0 ray

        // Test multiplication
        assert((a * b) == SignedWad { val: -(2 * wadray_signed::WAD_ONE) }, 'a * b != -2.0');
        assert((a * c) == SignedWad { val: 5 * wadray_signed::WAD_ONE }, 'a * c != 5.0');
        assert((b * c) == SignedWad { val: -(10 * wadray_signed::WAD_ONE) }, 'b * c != -10.0');

        // Test division
        assert((c / a) == SignedWad { val: 5 * wadray_signed::WAD_ONE }, 'c / a != 5.0');
        assert((a / d) == SignedWad { val: -(1 * wadray_signed::WAD_ONE) }, 'a / d != -1.0');
        assert((b / d) == SignedWad { val: 2 * wadray_signed::WAD_ONE }, 'b / d != 2.0');

        let a = SignedRay { val: wadray_signed::RAY_ONE }; // 1.0 ray
        let b = SignedRay { val: -(2 * wadray_signed::RAY_ONE) }; // -2.0 ray
        let c = SignedRay { val: 5 * wadray_signed::RAY_ONE }; // 5.0 ray
        let d = SignedRay { val: -wadray_signed::RAY_ONE }; // -1.0 ray

        // Test multiplication
        assert((a * b) == SignedRay { val: -(2 * wadray_signed::RAY_ONE) }, 'a * b != -2.0');
        assert((a * c) == SignedRay { val: 5 * wadray_signed::RAY_ONE }, 'a * c != 5.0');
        assert((b * c) == SignedRay { val: -(10 * wadray_signed::RAY_ONE) }, 'b * c != -10.0');

        // Test division
        assert((c / a) == SignedRay { val: 5 * wadray_signed::RAY_ONE }, 'c / a != 5.0');
        assert((a / d) == SignedRay { val: -(1 * wadray_signed::RAY_ONE) }, 'a / d != -1.0');
        assert((b / d) == SignedRay { val: 2 * wadray_signed::RAY_ONE }, 'b / d != 2.0');
    }

    #[test]
    fn test_comparison() {
        let a = SignedWad { val: 100 };
        let b = SignedWad { val: -100 };
        let c = SignedWad { val: -40 };
        let d = SignedWad { val: 40 };
        let zero = SignedWad { val: 0 };

        // Test greater than operator
        assert(a > b, 'a > b');
        assert(a > c, 'a > c');
        assert(!(b > a), 'b > a');
        assert(!(c > a), 'c > a');
        assert(!(zero > a), '0 > a');
        assert(a > zero, 'a > 0');

        // Test less than operator
        assert(b < a, 'b < a');
        assert(c < a, 'c < a');
        assert(!(a < b), 'a < b');
        assert(!(a < c), 'a < c');
        assert(zero < a, '0 < a');
        assert(!(a < zero), 'a < 0');

        // Test greater than or equal to operator
        assert(a >= b, 'a >= b');
        assert(a >= d, 'a >= d');
        assert(!(b >= a), 'b >= a');
        assert(c >= c, 'c >= c');
        assert(zero >= zero, '0 >= 0');
        assert(a >= zero, 'a >= 0');
        assert(!(zero >= a), '0 >= a');

        // Test less than or equal to operator
        assert(b <= a, 'b <= a');
        assert(d <= a, 'd <= a');
        assert(!(a <= b), 'a <= b');
        assert(c <= c, 'c <= c');
        assert(zero <= zero, '0 <= 0');
        assert(zero <= a, '0 <= a');
        assert(!(a <= zero), 'a <= 0');

        let a = SignedRay { val: 100 };
        let b = SignedRay { val: -100 };
        let c = SignedRay { val: -40 };
        let d = SignedRay { val: 40 };
        let zero = SignedRay { val: 0 };

        // Test greater than operator
        assert(a > b, 'a > b');
        assert(a > c, 'a > c');
        assert(!(b > a), 'b > a');
        assert(!(c > a), 'c > a');
        assert(!(zero > a), '0 > a');
        assert(a > zero, 'a > 0');

        // Test less than operator
        assert(b < a, 'b < a');
        assert(c < a, 'c < a');
        assert(!(a < b), 'a < b');
        assert(!(a < c), 'a < c');
        assert(zero < a, '0 < a');
        assert(!(a < zero), 'a < 0');

        // Test greater than or equal to operator
        assert(a >= b, 'a >= b');
        assert(a >= d, 'a >= d');
        assert(!(b >= a), 'b >= a');
        assert(c >= c, 'c >= c');
        assert(zero >= zero, '0 >= 0');
        assert(a >= zero, 'a >= 0');
        assert(!(zero >= a), '0 >= a');

        // Test less than or equal to operator
        assert(b <= a, 'b <= a');
        assert(d <= a, 'd <= a');
        assert(!(a <= b), 'a <= b');
        assert(c <= c, 'c <= c');
        assert(zero <= zero, '0 <= 0');
        assert(zero <= a, '0 <= a');
        assert(!(a <= zero), 'a <= 0');
    }

    #[test]
    fn test_into_conversions() {
        // Test U128IntoSignedWad
        let a: i128 = 100;
        let a_signed: SignedWad = a.into();
        assert(a_signed.val == a, 'U128IntoSignedWad val fail');

        // Test WadIntoSignedWad
        let b = Wad { val: 200 };
        let b_signed: SignedWad = b.try_into().unwrap();
        assert(b_signed.val.try_into().unwrap() == b.val, 'WadIntoSignedWad val fail');

        // Test SignedWadTryIntoWad
        let d = SignedWad { val: 400 };
        let d_wad: Option<Wad> = d.try_into();
        assert(d_wad.is_some(), 'SignedWadTryIntoWad pos fail');
        assert(d_wad.unwrap().val.try_into().unwrap() == d.val, 'SignedWadTryIntoWad val fail');

        let e = SignedWad { val: -500 };
        let e_wad: Option<Wad> = e.try_into();
        assert(e_wad.is_none(), 'SignedWadTryIntoWad neg fail');

        // Test I128IntoSignedRay
        let a: i128 = 100;
        let a_signed: SignedRay = a.into();
        assert(a_signed.val == a, 'U128IntoSignedRay val fail');

        // Test RayIntoSignedRay
        let b = Ray { val: 200 };
        let b_signed: SignedRay = b.into();
        assert(b_signed.val.try_into().unwrap() == b.val, 'RayIntoSignedRay val fail');

        // Test WadIntoSignedRay
        let c = Wad { val: 300 * wadray::WAD_ONE };
        let c_signed: SignedRay = c.into();
        assert(
            c_signed.val.try_into().unwrap() == c.val * wadray::DIFF, 'WadIntoSignedRay val fail'
        );

        // Test SignedRayTryIntoRay
        let d = SignedRay { val: 400 };
        let d_ray: Option<Ray> = d.try_into();
        assert(d_ray.is_some(), 'SignedRayTryIntoRay pos fail');
        assert(d_ray.unwrap().val.try_into().unwrap() == d.val, 'SignedRayTryIntoRay val fail');

        let e = SignedRay { val: -500 };
        let e_ray: Option<Ray> = e.try_into();
        assert(e_ray.is_none(), 'SignedRayTryIntoRay neg fail');
    }

    #[test]
    fn test_zeroable_oneable() {
        // Test SignedWadZeroable
        let zero = SignedWadZeroable::zero();
        assert(zero.val == 0, 'Zeroable zero fail');
        assert(zero.is_zero(), 'Zeroable is_zero fail');
        assert(!zero.is_non_zero(), 'Zeroable is_non_zero fail');

        let non_zero = SignedWad { val: 100 };
        assert(!non_zero.is_zero(), 'Zeroable non_zero fail');
        assert(non_zero.is_non_zero(), 'Zeroable non_zero fail');

        // Test SignedWadOneable
        let one = SignedWadOneable::one();
        assert(one.val == wadray_signed::WAD_ONE, 'Oneable one fail');
        assert(one.is_one(), 'Oneable is_one fail');
        assert(!one.is_non_one(), 'Oneable is_non_one fail');

        let non_one = SignedWad { val: 200 };
        assert(!non_one.is_one(), 'Oneable non_one fail');
        assert(non_one.is_non_one(), 'Oneable non_one fail');

        // Test SignedRayZeroable
        let zero = SignedRayZeroable::zero();
        assert(zero.val == 0, 'Zeroable zero fail');
        assert(zero.is_zero(), 'Zeroable is_zero fail');
        assert(!zero.is_non_zero(), 'Zeroable is_non_zero fail');

        let non_zero = SignedRay { val: 100 };
        assert(!non_zero.is_zero(), 'Zeroable non_zero fail');
        assert(non_zero.is_non_zero(), 'Zeroable non_zero fail');

        // Test SignedRayOneable
        let one = SignedRayOneable::one();
        assert(one.val == wadray_signed::RAY_ONE, 'Oneable one fail');
        assert(one.is_one(), 'Oneable is_one fail');
        assert(!one.is_non_one(), 'Oneable is_non_one fail');

        let non_one = SignedRay { val: 200 };
        assert(!non_one.is_one(), 'Oneable non_one fail');
        assert(non_one.is_non_one(), 'Oneable non_one fail');
    }
}
